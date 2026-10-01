"""Copy dated *_FLX test rows between Greenplum databases and restore them later.

--start/--end are the dates to test. The tool finds the latest source window of the
same length, starting on the same weekday, in which every table has rows, and shifts
it onto the requested dates.

Examples:
  python flx_testdata.py plan --start 2026-06-16 --end 2026-07-19 --sp db_owner.fun_proc_xxx
  python flx_testdata.py apply --start 2026-06-16 --end 2026-07-19 --sp db_owner.fun_proc_xxx
  python flx_testdata.py restore --manifest flx_runs/<run-id>.json
"""

import argparse
import bisect
import datetime as dt
import json
import re
import sys
import tempfile
import uuid
from pathlib import Path

import psycopg2
from psycopg2 import sql


ROOT = Path(__file__).resolve().parents[2]
RUN_DIR = Path(__file__).resolve().parent / "flx_runs"
DATE_NAME = re.compile(r"(^|_)(yymmdd|date|day|time|ocfdate)(\d*|_[a-z0-9]+)?$", re.I)
KEY_PRIORITY = ("_yymmdd", "_ocfdate", "_ocf_date", "_trade_date", "data_date", "date_reg", "_settle_date")
ENV_LINE = re.compile(r'^\s*\$env:(PGHOST|PGPORT|PGDATABASE|PGUSER|PGPASSWORD)\s*=\s*["\'](.*)["\']\s*$', re.I)
# 這些字之後的「名稱 (」是資料表欄位清單或物件宣告，不是函式呼叫
# 不含 on：JOIN ... ON s.fn(...) 是呼叫；CREATE INDEX ... ON s.t (欄位) 另由 is_ddl_name 判斷
DDL_WORDS = ("into", "table", "exists", "references", "only", "copy", "view", "function", "aggregate")
# dollar quote 的起訖標記：$$ 或 $tag$
DOLLAR_TAG = re.compile(r"\$(?:[a-z_][a-z0-9_]*)?\$")
DOLLAR_TAG_AT = re.compile(r"(?=(\$(?:[a-z_][a-z0-9_]*)?\$))")
# 函式／view 原始碼中的 [schema.]名稱 引用，第 3 組為其後的左括號（函式呼叫）
IDENT_REF = re.compile(r"(?:\b([a-z_][a-z0-9_]*)\s*\.\s*)?\b([a-z_][a-z0-9_]*)\b(\s*\()?")


def connect(alias):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", alias):
        raise ValueError("資料庫別名格式錯誤")
    env_file = ROOT / "env" / (alias + ".txt")
    values = {}
    for line in env_file.read_text(encoding="utf-8-sig").splitlines():
        match = ENV_LINE.match(line)
        if match:
            values[match.group(1).upper()] = match.group(2)
    if set(values) != {"PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"}:
        raise ValueError("連線設定缺少必要欄位：" + str(env_file))
    return psycopg2.connect(host=values["PGHOST"], port=values["PGPORT"],
                            dbname=values["PGDATABASE"], user=values["PGUSER"],
                            password=values["PGPASSWORD"], connect_timeout=15)


def catalog(conn):
    query = """
      SELECT n.nspname, c.relname, a.attname, a.atttypid::regtype::text,
             a.atttypmod, a.attnum
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
      WHERE c.relkind = 'r' AND c.relname LIKE '%\\_flx' ESCAPE '\\'
        AND n.nspname IN ('db_owner','cr_admin','db_owner_temp')
        AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY n.nspname, c.relname, a.attnum
    """
    result = {}
    with conn.cursor() as cur:
        cur.execute(query)
        for schema, table, name, typ, mod, _ in cur:
            result.setdefault((schema, table), []).append((name, typ, mod))
    return result


def kind(column):
    name, typ, mod = column
    n = name.lower()
    if typ in ("date", "timestamp without time zone", "timestamp with time zone"):
        return "typed"
    if typ in ("character", "character varying", "text") and DATE_NAME.search(n):
        if mod == 12:  # varchar/char(8)
            return "compact"
        if mod == 14:  # varchar/char(10)
            return "iso"
    return None


def choose_key(table, columns):
    candidates = [(c[0], kind(c)) for c in columns if kind(c)]
    if not candidates:
        return None, "沒有可判讀的日期欄位"
    table_stem = table[1][:-4]
    preferred = {"htppfmosf_msvu": "htppfmosf_yymmdd",
                 "htppomosf_msvu": "htppomosf_yymmdd"}.get(table_stem, table_stem + "_yymmdd")
    for name in (preferred, "trade_date", "date_reg"):
        matches = [x for x in candidates if x[0].lower() == name]
        if len(matches) == 1:
            return matches[0], None
    for suffix in KEY_PRIORITY:
        matches = [x for x in candidates if x[0].lower().endswith(suffix)]
        if len(matches) == 1:
            return matches[0], None
    # A single date column is safe even if its name does not use the common suffix.
    if len(candidates) == 1:
        return candidates[0], None
    return None, "日期基準欄位不明確"


def qtable(key):
    return sql.Identifier(*key)


def window_predicate(key, first, last):
    col, form = key
    field = sql.Identifier(col)
    if form == "typed":
        return sql.SQL("{} >= %s AND {} < %s").format(field, field), (first, last + dt.timedelta(days=1))
    if form == "compact":
        return sql.SQL("{} BETWEEN %s AND %s").format(field), (first.strftime("%Y%m%d"), last.strftime("%Y%m%d"))
    return sql.SQL("{} BETWEEN %s AND %s").format(field), (first.isoformat(), last.isoformat())


def count(conn, table, key, start, end):
    predicate, params = window_predicate(key, start, end)
    with conn.cursor() as cur:
        cur.execute(sql.SQL("SELECT count(*) FROM {} WHERE ").format(qtable(table)) + predicate, params)
        return cur.fetchone()[0]


def safe_date(field, form):
    """字元型日期轉 date 的 SQL 運算式；不合法值（如 20250631、00000000）回傳 NULL 而不報錯。
    GP6 的 to_date 遇到不存在的日期會直接報錯，故先以正規表示式限定年月，
    再由當月 1 日加天數，轉回字串與原值相同才算合法。"""
    if form == "compact":
        pattern, mask, month, day = r"^[0-9]{4}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])$", "YYYYMMDD", (1, 6), 7
    else:
        pattern, mask, month, day = r"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$", "YYYY-MM-DD", (1, 8), 9
    first = sql.SQL("to_date(substr({}, {}, {}) || '01', {})").format(
        field, sql.Literal(month[0]), sql.Literal(month[1]), sql.Literal(mask))
    value = sql.SQL("({} + (substr({}, {}, 2)::int - 1))").format(first, field, sql.Literal(day))
    return sql.SQL("CASE WHEN {} ~ {} AND substr({}, 1, 4) <> '0000' THEN "
                   "CASE WHEN to_char({}, {}) = {} THEN {} END END").format(
        field, sql.Literal(pattern), field, value, sql.Literal(mask), field, value)


def invalid_count(conn, table, key, start, end):
    """區間內字元型日期基準欄位的不合法值筆數（例如 20250631）。"""
    col, form = key
    if form == "typed":
        return 0
    predicate, params = window_predicate(key, start, end)
    query = sql.SQL("SELECT count(*) FROM {} WHERE ").format(qtable(table)) + predicate + sql.SQL(
        " AND {} IS NULL").format(safe_date(sql.Identifier(col), form))
    with conn.cursor() as cur:
        cur.execute(query, params)
        return cur.fetchone()[0]


def table_dates(conn, table, key):
    """來源表日期基準欄位的所有相異日期（已排序），字元型只取合法日期。"""
    col, form = key
    field = sql.Identifier(col)
    with conn.cursor() as cur:
        if form == "typed":
            # 9999 年視為「永久有效」代表值，不列入可平移的來源日期（與 shift_expr 一致）
            cur.execute(sql.SQL("SELECT DISTINCT {}::date FROM {} WHERE {} < '9999-01-01'").format(
                field, qtable(table), field))
            return sorted(row[0] for row in cur)
        pattern, mask = (r"^[0-9]{8}$", "%Y%m%d") if form == "compact" else (r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", "%Y-%m-%d")
        cur.execute(sql.SQL("SELECT DISTINCT {} FROM {} WHERE {} ~ %s").format(field, qtable(table), field), (pattern,))
        dates = []
        for (value,) in cur:
            try:
                date = dt.datetime.strptime(value, mask).date()
            except ValueError:
                continue
            if date.year < 9999:
                dates.append(date)
        return sorted(dates)


def find_window(dates_by_table, start, end):
    """找出各表皆至少有 1 筆的最近來源區段；起日與 start 同星期，長度與 start～end 相同。"""
    length = end - start
    first = min(d[0] for d in dates_by_table.values())
    last = max(d[-1] for d in dates_by_table.values())
    weeks = (last - start).days // 7
    while True:
        source_start = start + dt.timedelta(weeks=weeks)
        source_end = source_start + length
        if source_end < first:
            return None
        if all(_has_date(d, source_start, source_end) for d in dates_by_table.values()):
            return source_start, source_end
        weeks -= 1


def _has_date(dates, first, last):
    i = bisect.bisect_left(dates, first)
    return i < len(dates) and dates[i] <= last


def fingerprint(conn, table, key, start, end):
    predicate, params = window_predicate(key, start, end)
    query = sql.SQL("SELECT count(*), "
                    "coalesce(sum(('x'||substr(h,1,16))::bit(64)::bigint),0), "
                    "coalesce(sum(('x'||substr(h,17,16))::bit(64)::bigint),0) "
                    "FROM (SELECT md5(row_to_json(t)::text) h FROM {} t WHERE {}) z").format(
                        qtable(table), predicate)
    with conn.cursor() as cur:
        cur.execute(query, params)
        return ":".join(str(v) for v in cur.fetchone())


def lock_destination(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT pg_try_advisory_lock(7142, 178)")
        if not cur.fetchone()[0]:
            raise RuntimeError("another FLX batch is using this destination")


def shift_expr(column, days):
    name, typ, _ = column
    field = sql.Identifier(name)
    form = kind(column)
    if form == "typed":
        return sql.SQL("({} + interval '{} days')::{}").format(field, sql.SQL(str(days)), sql.SQL(typ))
    if form in ("compact", "iso"):
        # Preserve blank/invalid sentinel values; shift only full, valid calendar dates.
        mask = "YYYYMMDD" if form == "compact" else "YYYY-MM-DD"
        parsed = safe_date(field, form)
        # 9999 年的值（如 99991231）視為「永久有效」的代表值，不平移，也避免平移後超出欄位長度
        return sql.SQL("CASE WHEN {} IS NOT NULL AND substr({}, 1, 4) <> '9999' "
                       "THEN to_char({} + interval '{} days', {}) ELSE {} END").format(
            parsed, field, parsed, sql.SQL(str(days)), sql.Literal(mask), field)
    return field


def save_manifest(path, data):
    RUN_DIR.mkdir(exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def user_objects(conn):
    """目的庫使用者 schema 的函式與 view 清單，供往下追蹤引用。"""
    excluded = "n.nspname NOT LIKE 'pg\\_%' AND n.nspname NOT IN ('information_schema', 'gp_toolkit')"
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT n.nspname, p.proname FROM pg_proc p "
                    "JOIN pg_namespace n ON n.oid = p.pronamespace WHERE " + excluded)
        functions = {(s, f) for s, f in cur}
        cur.execute("SELECT n.nspname, c.relname FROM pg_class c "
                    "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind = 'v' AND " + excluded)
        views = {(s, v) for s, v in cur}
    return functions, views


def object_source(conn, kind, obj):
    with conn.cursor() as cur:
        if kind == "function":
            cur.execute("SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
                        "WHERE n.nspname = %s AND p.proname = %s", obj)
        else:
            cur.execute("SELECT pg_get_viewdef(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                        "WHERE n.nspname = %s AND c.relname = %s", obj)
        return "\n".join(row[0] or "" for row in cur)


def previous_word(text, position):
    end = position
    while end > 0 and text[end - 1].isspace():
        end -= 1
    begin = end
    while begin > 0 and (text[begin - 1].isalpha() or text[begin - 1] == "_"):
        begin -= 1
    return text[begin:end]


def is_ddl_name(text, position):
    """position 處的「名稱 (」是否為 DDL 的物件名稱或欄位清單，而非函式呼叫。"""
    word = previous_word(text, position)
    if word in DDL_WORDS:
        return True
    # CREATE [UNIQUE] INDEX ... ON s.t (欄位)：同一陳述式內有 index 才算；JOIN ... ON s.fn(...) 仍視為呼叫
    return word == "on" and re.search(r"\bindex\b", text[text.rfind(";", 0, position) + 1:position]) is not None


def strip_comments(text):
    """一次走訪原始碼，去除字串外的 -- 與 /* */ 註解（區塊註解可巢狀）。
    一般字串（'' 跳脫）、E 字串（反斜線跳脫）、$tag$ 字串原樣保留，其中的動態 SQL 仍會比對；
    "引號識別字" 保留內容、去掉雙引號。時間與原始碼長度成正比。"""
    # 預先記下每個 dollar 標記出現的位置，找結尾標記時用二分搜尋，避免大量未配對標記造成重複掃描
    tag_positions = {}
    # 以前瞻比對取得可重疊的位置，避免 $q$x$$q$ 中的 $$ 先被比對而漏記結尾的 $q$
    for m in DOLLAR_TAG_AT.finditer(text):
        tag_positions.setdefault(m.group(1), []).append(m.start())
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("--", i):
            newline = text.find("\n", i)
            i = n if newline < 0 else newline
            out.append(" ")
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif text.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(" ")
        elif c == "'":
            # 前一字元為獨立的 e 時是 E 字串，反斜線為跳脫字元
            escape = i > 0 and text[i - 1] == "e" and (i < 2 or not (text[i - 2].isalnum() or text[i - 2] in "_$"))
            j = i + 1
            while j < n:
                if escape and text[j] == "\\":
                    j += 2
                elif text.startswith("''", j):
                    j += 2
                elif text[j] == "'":
                    break
                else:
                    j += 1
            out.append(text[i:j + 1])
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n:
                if text.startswith('""', j):
                    j += 2
                elif text[j] == '"':
                    break
                else:
                    j += 1
            # 前後補空白，避免 into"t_flx" 去掉引號後黏成 intot_flx
            out.append(" " + text[i + 1:j] + " ")
            i = j + 1
        else:
            m = DOLLAR_TAG.match(text, i) if c == "$" else None
            # 識別字可含 $，前一字元為識別字字元時不是 dollar quote 開頭
            if m and not (i > 0 and (text[i - 1].isalnum() or text[i - 1] in "_$")):
                positions = tag_positions[m.group()]
                k = bisect.bisect_left(positions, m.end())
                if k < len(positions):
                    close = positions[k] + len(m.group())
                    out.append(text[i:close])
                    i = close
                    continue
            out.append(c)
            i += 1
    return "".join(out)


def sp_tables(conn, names, source, target, preferred):
    """從 --sp 函式往下追蹤呼叫的函式與引用的 view，找出所有 _flx 表。
    回傳 ({來源表: 引用路徑}, 略過的引用, 錯誤)；以動態字串拼出的物件名稱無法追蹤。
    preferred 為 --table 指定的表，用於消除未加 schema 時的同名歧義。"""
    functions, views = user_objects(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT nspname FROM pg_namespace")
        schemas = {row[0] for row in cur}
        cur.execute("SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace")
        relations = {(s, r) for s, r in cur}
    queue = []
    for name in names:
        obj = tuple(name.lower().split("."))
        if len(obj) != 2:
            raise ValueError("--sp 須為 schema.函式名稱：" + name)
        if obj not in functions:
            raise RuntimeError("目的庫找不到函式：" + name)
        queue.append(("function", obj, [name.lower()]))
    found, skipped, errors, seen = {}, [], [], set()

    def note(items, value):
        if value not in items:
            items.append(value)

    while queue:
        kind, obj, path = queue.pop(0)
        if (kind, obj) in seen:
            continue
        seen.add((kind, obj))
        via = " → ".join(path)
        # 被註解掉的程式不會執行，不追蹤
        text = strip_comments(object_source(conn, kind, obj).lower())
        for match in IDENT_REF.finditer(text):
            schema, ident, call = match.groups("")
            # 前綴是實際存在的 schema 時只比對完整名稱，不跨 schema 改配同名物件；
            # 未加 schema 或前綴是別名時，才依名稱對應
            if schema in schemas:
                name = (schema, ident)
                tables = [name] if name in source else []
                in_target = name in target
                if name in functions:
                    targets = [("function", name)]
                elif name in views:
                    targets = [("view", name)]
                else:
                    targets = []
                    # 排除 INSERT INTO／CREATE TABLE 等「表名 (欄位)」寫法
                    if (call and not schema.startswith("pg_") and schema not in ("information_schema", "gp_toolkit")
                            and not tables
                            and name not in relations and not is_ddl_name(text, match.start())):
                        # 呼叫的函式不存在：無法往下追蹤，該函式用到的表會缺漏
                        note(errors, "{}.{}：{} 呼叫，但目的庫沒有此函式，無法往下追蹤".format(schema, ident, via))
            else:
                tables = [t for t in source if t[1] == ident] if ident.endswith("_flx") else []
                if len(tables) > 1:
                    chosen = [t for t in tables if t in preferred]
                    if len(chosen) != 1:
                        note(errors, "{}：{} 引用，未指定 schema 且對應多個來源表（{}），請以 --table 指定其中一張".format(
                            ident, via, "、".join(".".join(t) for t in sorted(tables))))
                        continue
                    tables = chosen
                in_target = any(t[1] == ident for t in target)
                if call:
                    targets = [("function", f) for f in functions if f[1] == ident]
                else:
                    targets = [("view", v) for v in views if v[1] == ident]
            if tables:
                found.setdefault(tables[0], via)
                continue
            for item in targets:
                if item not in seen:
                    queue.append(item + (path + [".".join(item[1])],))
            if targets or not ident.endswith("_flx"):
                continue
            if in_target:
                # 實體表只存在目的庫：缺來源資料，不可略過
                note(errors, "{}：{} 引用，目的庫有此資料表但來源庫沒有".format(ident, via))
            elif any(r[1] == ident and (r[0] == schema or schema not in schemas) for r in relations):
                note(skipped, {"table": ident, "reason": via + " 引用，物件存在但不在處理範圍（schema 非 db_owner／cr_admin／db_owner_temp，或非一般資料表）"})
            else:
                note(skipped, {"table": ident, "reason": via + " 引用，兩庫都沒有此資料表（可能為暫存表）"})
    return found, skipped, errors


def plan(src, dst, args):
    source, target = catalog(src), catalog(dst)
    extra = []
    for name in args.table or ():
        table = tuple(name.lower().split("."))
        if table not in source:
            raise RuntimeError("來源庫沒有此資料表：" + name)
        extra.append(table)
    tables, skipped, errors = sp_tables(dst, args.sp, source, target, extra) if args.sp else ({}, [], [])
    for table in extra:
        tables.setdefault(table, "--table")
    if not tables and not errors:
        raise RuntimeError("沒有找到任何要處理的 _flx 資料表")
    # 每張欲使用的表都必須能處理，否則停止，避免測試資料缺表
    specs = {}
    for table in sorted(tables):
        cols = source[table]
        key, reason = choose_key(table, cols)
        if table not in target:
            errors.append(".".join(table) + "：目的庫不存在")
        elif cols != target[table]:
            errors.append(".".join(table) + "：兩庫欄位定義不同")
        elif not key:
            errors.append(".".join(table) + "：" + reason)
        else:
            specs[table] = (key, cols)
    if errors:
        raise RuntimeError("下列項目無法處理：\n  " + "\n  ".join(errors))
    dates = {table: table_dates(src, table, key) for table, (key, _) in specs.items()}
    empty = [".".join(t) for t, d in dates.items() if not d]
    if empty:
        raise RuntimeError("來源庫沒有資料：" + ", ".join(empty))
    window = find_window(dates, args.start, args.end)
    if not window:
        raise RuntimeError("找不到所有資料表皆有資料的來源區段；各表來源日期範圍：\n  " + "\n  ".join(
            "{}：{} ～ {}".format(".".join(t), d[0], d[-1]) for t, d in sorted(dates.items())))
    source_start, source_end = window
    days = (args.start - source_start).days
    # 不合法的字元型日期不會平移，匯入後落在目的區間外，會使 apply 中途因筆數不符而停止
    invalid = ["{}：{} 筆".format(".".join(t), n) for t, n in
               ((t, invalid_count(src, t, key, source_start, source_end)) for t, (key, _) in sorted(specs.items())) if n]
    if invalid:
        raise RuntimeError("來源區段 {} ～ {} 內有不合法的日期值，無法平移：\n  {}".format(
            source_start, source_end, "\n  ".join(invalid)))
    selected = []
    for table, (key, cols) in sorted(specs.items()):
        source_count = count(src, table, key, source_start, source_end)
        target_count = count(dst, table, key, args.start, args.end)
        selected.append({"table": ".".join(table), "key": list(key),
                         "source_count": source_count, "target_count": target_count,
                         "source_days": _count_dates(dates[table], source_start, source_end),
                         "via": tables[table], "columns": cols})
    window = {"source_start": source_start, "source_end": source_end, "days": days}
    print_summary(args, selected, skipped, window)
    return selected, skipped, window


def _count_dates(dates, first, last):
    return bisect.bisect_right(dates, last) - bisect.bisect_left(dates, first)


def print_summary(args, selected, skipped, window):
    """匯入前列出要移轉的資料資訊。"""
    weekday = "一二三四五六日"
    length = (args.end - args.start).days + 1
    lines = [
        "來源 {} → 目的 {}".format(args.source, args.destination),
        "欲測試日期：{} ～ {}（週{}～週{}，{} 天）".format(
            args.start, args.end, weekday[args.start.weekday()], weekday[args.end.weekday()], length),
        "來源區段：{} ～ {}，平移 {} 天（{} 週）".format(
            window["source_start"], window["source_end"], window["days"], window["days"] // 7),
        "資料表 {} 張：".format(len(selected)),
    ]
    for x in selected:
        lines.append("  {}  日期欄位={}  來源={} 筆／{} 天  目的現有={} 筆（將備份後取代）".format(
            x["table"], x["key"][0], x["source_count"], x["source_days"], x["target_count"]))
        lines.append("      引用路徑：" + x["via"])
    lines.append("合計：來源 {} 筆，目的現有 {} 筆".format(
        sum(x["source_count"] for x in selected), sum(x["target_count"] for x in selected)))
    if skipped:
        lines.append("略過的引用 {} 個：".format(len(skipped)))
        lines += ["  {}：{}".format(x["table"], x["reason"]) for x in skipped]
    print("\n".join(lines), flush=True)


def apply(src, dst, args, selected, skipped, window):
    for old_path in RUN_DIR.glob("*.json") if RUN_DIR.exists() else ():
        old = json.loads(old_path.read_text(encoding="utf-8"))
        overlaps = old.get("start", "9999-12-31") <= args.end.isoformat() and args.start.isoformat() <= old.get("end", "0001-01-01")
        if old.get("destination") == args.destination and overlaps and old.get("status") in ("running", "applied", "restoring"):
            raise RuntimeError("同一目的庫與日期區間已有未還原批次：" + str(old_path))
    run_id = dt.datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6]
    path = RUN_DIR / (run_id + ".json")
    manifest = {"run_id": run_id, "source": args.source, "destination": args.destination,
                "start": args.start.isoformat(), "end": args.end.isoformat(),
                "source_start": window["source_start"].isoformat(), "source_end": window["source_end"].isoformat(),
                "days": window["days"], "status": "running", "tables": [], "skipped": skipped}
    save_manifest(path, manifest)
    print("manifest:", path, flush=True)
    for index, entry in enumerate(selected, 1):
        if entry["source_count"] == 0 and entry["target_count"] == 0:
            continue
        table = tuple(entry["table"].split("."))
        key = tuple(entry["key"])
        columns = entry["columns"]
        backup = ("db_owner_temp", "flxb_{}_{}".format(run_id.lower(), index))
        entry = {k: v for k, v in entry.items() if k != "columns"}
        entry.update(backup=".".join(backup), state="pending")
        manifest["tables"].append(entry)
        save_manifest(path, manifest)
        with tempfile.TemporaryFile(mode="w+b") as spool:
            predicate, params = window_predicate(key, window["source_start"], window["source_end"])
            select_sql = sql.SQL("COPY (SELECT {} FROM {} WHERE {}) TO STDOUT WITH CSV").format(
                sql.SQL(", ").join(shift_expr(c, window["days"]) for c in columns), qtable(table),
                sql.SQL(src.cursor().mogrify(predicate.as_string(src), params).decode(src.encoding)))
            if entry["source_count"]:
                with src.cursor() as cur:
                    cur.copy_expert(select_sql.as_string(src), spool)
            spool.seek(0)
            target_predicate, target_params = window_predicate(key, args.start, args.end)
            try:
                with dst.cursor() as cur:
                    cur.execute(sql.SQL("CREATE TABLE {} AS SELECT * FROM {} WHERE {} DISTRIBUTED RANDOMLY").format(
                        qtable(backup), qtable(table),
                        sql.SQL(cur.mogrify(target_predicate.as_string(dst), target_params).decode(dst.encoding))))
                    cur.execute(sql.SQL("SELECT count(*) FROM {}").format(qtable(backup)))
                    if cur.fetchone()[0] != entry["target_count"]:
                        raise RuntimeError("備份筆數與盤點不符：" + entry["table"])
                    actual = 0
                    if entry["source_count"]:
                        cur.execute(sql.SQL("DELETE FROM {} WHERE ").format(qtable(table)) + target_predicate, target_params)
                        copy_sql = sql.SQL("COPY {} ({}) FROM STDIN WITH CSV").format(
                            qtable(table), sql.SQL(", ").join(sql.Identifier(c[0]) for c in columns))
                        cur.copy_expert(copy_sql.as_string(dst), spool)
                        cur.execute(sql.SQL("SELECT count(*) FROM {} WHERE ").format(qtable(table)) + target_predicate, target_params)
                        actual = cur.fetchone()[0]
                        if actual != entry["source_count"]:
                            raise RuntimeError("匯入筆數不符：{}，預期 {}，實際 {}".format(entry["table"], entry["source_count"], actual))
                entry["fingerprint"] = fingerprint(dst, table, key, args.start, args.end)
                entry["state"] = "prepared"
                save_manifest(path, manifest)
                dst.commit()
                entry["state"] = "applied" if entry["source_count"] else "backup_only"
                save_manifest(path, manifest)
                print("APPLIED {}: backup={} imported={}".format(entry["table"], entry["target_count"], actual), flush=True)
            except Exception:
                dst.rollback()
                raise
    manifest["status"] = "applied"
    save_manifest(path, manifest)
    return path


def target_window(manifest):
    # 舊版執行紀錄的 start/end 為來源日期並以 years 平移，與新版不相容
    if "years" in manifest:
        raise RuntimeError("舊版執行紀錄只支援對已還原批次補刪備份表")
    return dt.date.fromisoformat(manifest["start"]), dt.date.fromisoformat(manifest["end"])


def check_backup_names(manifest, path):
    """備份表名稱須為本批 apply 建立的 db_owner_temp.flxb_<run_id>_<序號>，且執行紀錄檔名須等於 run_id，
    避免執行紀錄被改動時，以其他表還原或刪到其他表。"""
    if Path(path).stem != manifest["run_id"]:
        raise RuntimeError("執行紀錄檔名與 run_id 不符，拒絕處理：" + str(path))
    pattern = r"db_owner_temp\.flxb_{}_\d+".format(re.escape(manifest["run_id"].lower()))
    bad = [x["backup"] for x in manifest["tables"] if not re.fullmatch(pattern, x["backup"])]
    if bad:
        raise RuntimeError("備份表名稱不符本批命名規則，拒絕處理：" + ", ".join(bad))


def drop_backups(dst, path, manifest):
    """還原完成後刪除備份表；重跑 restore 可補刪先前未刪成功的備份表。"""
    check_backup_names(manifest, path)
    for entry in manifest["tables"]:
        if entry.get("backup_dropped"):
            continue
        if entry["state"] != "restored":
            raise RuntimeError("尚未還原，不可刪除備份表：" + entry["table"])
        with dst.cursor() as cur:
            cur.execute(sql.SQL("DROP TABLE IF EXISTS {}").format(qtable(tuple(entry["backup"].split(".")))))
        dst.commit()
        entry["backup_dropped"] = True
        save_manifest(path, manifest)
        print("DROPPED", entry["backup"], flush=True)


def restore(dst, path, allow_changes=False):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] == "restored":
        drop_backups(dst, path, manifest)
        return
    if manifest["status"] not in ("applied", "running", "restoring"):
        raise ValueError("此批次狀態不能還原")
    start, end = target_window(manifest)
    check_backup_names(manifest, path)
    manifest["status"] = "restoring"
    save_manifest(path, manifest)


    for entry in reversed(manifest["tables"]):
        if entry["state"] not in ("applied", "backup_only", "prepared", "pending"):
            continue
        table, backup = tuple(entry["table"].split(".")), tuple(entry["backup"].split("."))
        with dst.cursor() as cur:
            cur.execute("SELECT to_regclass(%s)", (entry["backup"],))
            if cur.fetchone()[0] is None:
                if entry["state"] in ("pending", "prepared"):
                    entry["state"] = "restored"
                    save_manifest(path, manifest)
                    continue
                raise RuntimeError("找不到備份表：" + entry["backup"])
        if not entry.get("fingerprint"):
            raise RuntimeError("缺少匯入後內容摘要，需人工檢查：" + entry["table"])
        current = fingerprint(dst, table, tuple(entry["key"]), start, end)
        backup_fingerprint = fingerprint(dst, backup, tuple(entry["key"]), start, end)
        if current == backup_fingerprint:
            entry["state"] = "restored"
            save_manifest(path, manifest)
            continue
        if current != entry["fingerprint"] and not allow_changes:
            raise RuntimeError("目的資料在匯入後已有變動，停止還原：" + entry["table"])
        predicate, params = window_predicate(tuple(entry["key"]), start, end)
        try:
            with dst.cursor() as cur:
                cur.execute(sql.SQL("DELETE FROM {} WHERE ").format(qtable(table)) + predicate, params)
                cur.execute(sql.SQL("INSERT INTO {} SELECT * FROM {}").format(qtable(table), qtable(backup)))
                cur.execute(sql.SQL("SELECT count(*) FROM {} WHERE ").format(qtable(table)) + predicate, params)
                if cur.fetchone()[0] != entry["target_count"]:
                    raise RuntimeError("還原筆數不符：" + entry["table"])
            dst.commit()
            entry["state"] = "restored"
            save_manifest(path, manifest)
            print("RESTORED", entry["table"], flush=True)
        except Exception:
            dst.rollback()
            raise
    manifest["status"] = "restored"
    save_manifest(path, manifest)
    drop_backups(dst, path, manifest)


def seal(dst, path):
    """Record row fingerprints for runs created before fingerprint protection."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] != "applied" or any(x["state"] not in ("applied", "backup_only") for x in manifest["tables"]):
        raise RuntimeError("Only a completed apply run can be sealed")
    start, end = target_window(manifest)
    for entry in manifest["tables"]:
        table = tuple(entry["table"].split("."))
        key = tuple(entry["key"])
        expected = entry["source_count"] if entry["state"] == "applied" else entry["target_count"]
        if count(dst, table, key, start, end) != expected:
            raise RuntimeError("Current row count differs from manifest: " + entry["table"])
        with dst.cursor() as cur:
            cur.execute(sql.SQL("SELECT count(*) FROM {}").format(qtable(tuple(entry["backup"].split(".")))))
            if cur.fetchone()[0] != entry["target_count"]:
                raise RuntimeError("Backup row count differs from manifest: " + entry["backup"])
        current = fingerprint(dst, table, key, start, end)
        if entry.get("fingerprint") and current != entry["fingerprint"]:
            raise RuntimeError("Current rows differ from sealed fingerprint: " + entry["table"])
        entry["fingerprint"] = current
        save_manifest(path, manifest)
        print("SEALED", entry["table"], flush=True)


def verify(dst, path):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] != "applied" or any(x["state"] not in ("applied", "backup_only") for x in manifest["tables"]):
        raise RuntimeError("批次尚未完整匯入，不能驗證成功")
    start, end = target_window(manifest)
    for entry in manifest["tables"]:
        table = tuple(entry["table"].split("."))
        actual = count(dst, table, tuple(entry["key"]), start, end)
        expected = entry["source_count"] if entry["state"] == "applied" else entry["target_count"]
        if actual != expected:
            raise RuntimeError("筆數不符：{}，預期 {}，實際 {}".format(entry["table"], expected, actual))
        if not entry.get("fingerprint"):
            raise RuntimeError("Run is not sealed: " + entry["table"])
        if entry["state"] in ("applied", "backup_only"):
            if fingerprint(dst, table, tuple(entry["key"]), start, end) != entry["fingerprint"]:
                raise RuntimeError("內容摘要不符：" + entry["table"])
        with dst.cursor() as cur:
            cur.execute(sql.SQL("SELECT count(*) FROM {}").format(qtable(tuple(entry["backup"].split(".")))))
            backup_count = cur.fetchone()[0]
        if backup_count != entry["target_count"]:
            raise RuntimeError("備份筆數不符：" + entry["backup"])
    print("VERIFIED tables={} imported_rows={} backed_up_rows={}".format(
        len(manifest["tables"]), sum(x["source_count"] for x in manifest["tables"]),
        sum(x["target_count"] for x in manifest["tables"])), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "apply", "seal", "verify", "restore"))
    parser.add_argument("--start", type=dt.date.fromisoformat, help="欲測試的資料起日")
    parser.add_argument("--end", type=dt.date.fromisoformat, help="欲測試的資料迄日")
    parser.add_argument("--source", default="GPstage")
    parser.add_argument("--destination", default="GP178")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--allow-changes", action="store_true", help="Allow restore to discard changes made after apply")
    parser.add_argument("--sp", action="append", help="欲測試的 schema.函式，自動找出引用的 _flx 表；可重複指定")
    parser.add_argument("--table", action="append", help="補充 schema.table；可重複指定")
    parser.add_argument("--yes", action="store_true", help="apply 不詢問確認，直接匯入")
    args = parser.parse_args()
    if args.action in ("seal", "verify", "restore"):
        if not args.manifest:
            parser.error("verify/restore 需要 --manifest")
        old = json.loads(args.manifest.read_text(encoding="utf-8"))
        if args.destination != old["destination"]:
            parser.error("--destination 與批次紀錄的目的庫不同")
        if args.action == "restore":
            # 連線與取得資料庫鎖之前先檢查，名稱不符時不碰資料庫
            check_backup_names(old, args.manifest)
        with connect(args.destination) as dst:
            if args.action == "seal":
                seal(dst, args.manifest)
                return
            if args.action == "restore":
                lock_destination(dst)
                restore(dst, args.manifest, args.allow_changes)
            else:
                verify(dst, args.manifest)
        return
    if not args.start or not args.end or args.start > args.end:
        parser.error("須提供有效的 --start、--end")
    if not args.sp and not args.table:
        parser.error("須以 --sp 或 --table 指定資料表")
    with connect(args.source) as src, connect(args.destination) as dst:
        source_dsn = src.get_dsn_parameters()
        target_dsn = dst.get_dsn_parameters()
        identity = ("host", "port", "dbname")
        if all(source_dsn.get(k) == target_dsn.get(k) for k in identity):
            parser.error("source and destination refer to the same database")
        if args.action == "apply":
            lock_destination(dst)
        selected, skipped, window = plan(src, dst, args)
        if args.action == "apply":
            # 結束盤點交易再等待確認，避免長時間 idle in transaction；advisory lock 屬工作階段層級，仍保留
            src.commit()
            dst.commit()
            if not args.yes and not confirm():
                print("已取消，未異動任何資料", flush=True)
                return
            apply(src, dst, args, selected, skipped, window)


def confirm():
    try:
        return input("確認依上列資訊備份並匯入？(y/N) ").strip().lower() == "y"
    except EOFError:
        # 非互動執行時無法詢問，視為取消；請改加 --yes
        print("\n無法取得確認（非互動執行請加 --yes）", flush=True)
        return False


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(type(exc).__name__ + ": " + str(exc), file=sys.stderr)
        sys.exit(1)
