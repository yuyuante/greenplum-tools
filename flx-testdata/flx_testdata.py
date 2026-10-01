"""Copy dated *_FLX test rows between Greenplum databases and restore them later.

Examples:
  python flx_testdata.py plan --start 2024-06-16 --end 2024-07-19
  python flx_testdata.py apply --start 2024-06-16 --end 2024-07-19
  python flx_testdata.py restore --manifest flx_runs/<run-id>.json
"""

import argparse
import calendar
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


def window_predicate(key, start, end, offset=0):
    col, form = key
    first = shift_date(start, offset)
    last = shift_date(end, offset)
    field = sql.Identifier(col)
    if form == "typed":
        return sql.SQL("{} >= %s AND {} < %s").format(field, field), (first, last + dt.timedelta(days=1))
    if form == "compact":
        return sql.SQL("{} BETWEEN %s AND %s").format(field), (first.strftime("%Y%m%d"), last.strftime("%Y%m%d"))
    return sql.SQL("{} BETWEEN %s AND %s").format(field), (first.isoformat(), last.isoformat())


def shift_date(value, years):
    year = value.year + years
    if not 1 <= year <= 9999:
        raise ValueError("shifted year out of range")
    return value.replace(year=year, day=min(value.day, calendar.monthrange(year, value.month)[1]))


def count(conn, table, key, start, end, offset=0):
    predicate, params = window_predicate(key, start, end, offset)
    with conn.cursor() as cur:
        cur.execute(sql.SQL("SELECT count(*) FROM {} WHERE ").format(qtable(table)) + predicate, params)
        return cur.fetchone()[0]


def fingerprint(conn, table, key, start, end, offset=0):
    predicate, params = window_predicate(key, start, end, offset)
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


def shift_expr(column, years):
    name, typ, _ = column
    field = sql.Identifier(name)
    form = kind(column)
    if form == "typed":
        return sql.SQL("({} + interval '{} years')::{}").format(field, sql.SQL(str(years)), sql.SQL(typ))
    if form in ("compact", "iso"):
        # Preserve blank/invalid sentinel values; shift only full, valid calendar dates.
        if form == "compact":
            pattern, mask = r"^[0-9]{8}$", "YYYYMMDD"
        else:
            pattern, mask = r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", "YYYY-MM-DD"
        return sql.SQL("CASE WHEN {} ~ {} AND to_char(to_date({}, {}), {}) = {} "
                       "THEN to_char(to_date({}, {}) + interval '{} years', {}) ELSE {} END").format(
            field, sql.Literal(pattern), field, sql.Literal(mask), sql.Literal(mask), field,
            field, sql.Literal(mask), sql.SQL(str(years)), sql.Literal(mask), field)
    return field


def save_manifest(path, data):
    RUN_DIR.mkdir(exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def inventory(src, dst):
    source, target = catalog(src), catalog(dst)
    rows = []
    for table, cols in sorted(source.items()):
        if table not in target:
            rows.append((table, None, "來源表在目的庫不存在"))
        elif cols != target[table]:
            rows.append((table, None, "兩庫欄位定義不同"))
        else:
            key, reason = choose_key(table, cols)
            rows.append((table, (key, cols) if key else None, reason))
    for table in sorted(target.keys() - source.keys()):
        rows.append((table, None, "目的表在來源庫不存在"))
    return rows


def plan(src, dst, args):
    selected, skipped = [], []
    for table, spec, reason in inventory(src, dst):
        if args.table and ".".join(table) not in args.table:
            continue
        if not spec:
            skipped.append({"table": ".".join(table), "reason": reason})
            continue
        key, cols = spec
        source_count = count(src, table, key, args.start, args.end)
        target_count = count(dst, table, key, args.start, args.end, args.years)
        selected.append({"table": ".".join(table), "key": list(key),
                         "source_count": source_count, "target_count": target_count,
                         "columns": cols})
        print("{}: source={} target={} key={}".format(".".join(table), source_count, target_count, key[0]), flush=True)
    return selected, skipped


def apply(src, dst, args, selected, skipped):
    for old_path in RUN_DIR.glob("*.json") if RUN_DIR.exists() else ():
        old = json.loads(old_path.read_text(encoding="utf-8"))
        overlaps = old.get("start", "9999-12-31") <= args.end.isoformat() and args.start.isoformat() <= old.get("end", "0001-01-01")
        if old.get("destination") == args.destination and overlaps and old.get("status") in ("running", "applied", "restoring"):
            raise RuntimeError("同一目的庫與日期區間已有未還原批次：" + str(old_path))
    run_id = dt.datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6]
    path = RUN_DIR / (run_id + ".json")
    manifest = {"run_id": run_id, "source": args.source, "destination": args.destination,
                "start": args.start.isoformat(), "end": args.end.isoformat(),
                "years": args.years, "status": "running", "tables": [], "skipped": skipped}
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
            predicate, params = window_predicate(key, args.start, args.end)
            select_sql = sql.SQL("COPY (SELECT {} FROM {} WHERE {}) TO STDOUT WITH CSV").format(
                sql.SQL(", ").join(shift_expr(c, args.years) for c in columns), qtable(table),
                sql.SQL(src.cursor().mogrify(predicate.as_string(src), params).decode(src.encoding)))
            if entry["source_count"]:
                with src.cursor() as cur:
                    cur.copy_expert(select_sql.as_string(src), spool)
            spool.seek(0)
            target_predicate, target_params = window_predicate(key, args.start, args.end, args.years)
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
                entry["fingerprint"] = fingerprint(dst, table, key, args.start, args.end, args.years)
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


def restore(dst, path, allow_changes=False):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] not in ("applied", "running", "restoring"):
        raise ValueError("此批次狀態不能還原")
    start, end = dt.date.fromisoformat(manifest["start"]), dt.date.fromisoformat(manifest["end"])
    years = manifest["years"]
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
        current = fingerprint(dst, table, tuple(entry["key"]), start, end, years)
        backup_fingerprint = fingerprint(dst, backup, tuple(entry["key"]), start, end, years)
        if current == backup_fingerprint:
            entry["state"] = "restored"
            save_manifest(path, manifest)
            continue
        if current != entry["fingerprint"] and not allow_changes:
            raise RuntimeError("目的資料在匯入後已有變動，停止還原：" + entry["table"])
        predicate, params = window_predicate(tuple(entry["key"]), start, end, years)
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


def seal(dst, path):
    """Record row fingerprints for runs created before fingerprint protection."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] != "applied" or any(x["state"] not in ("applied", "backup_only") for x in manifest["tables"]):
        raise RuntimeError("Only a completed apply run can be sealed")
    start, end = dt.date.fromisoformat(manifest["start"]), dt.date.fromisoformat(manifest["end"])
    for entry in manifest["tables"]:
        table = tuple(entry["table"].split("."))
        key = tuple(entry["key"])
        expected = entry["source_count"] if entry["state"] == "applied" else entry["target_count"]
        if count(dst, table, key, start, end, manifest["years"]) != expected:
            raise RuntimeError("Current row count differs from manifest: " + entry["table"])
        with dst.cursor() as cur:
            cur.execute(sql.SQL("SELECT count(*) FROM {}").format(qtable(tuple(entry["backup"].split(".")))))
            if cur.fetchone()[0] != entry["target_count"]:
                raise RuntimeError("Backup row count differs from manifest: " + entry["backup"])
        current = fingerprint(dst, table, key, start, end, manifest["years"])
        if entry.get("fingerprint") and current != entry["fingerprint"]:
            raise RuntimeError("Current rows differ from sealed fingerprint: " + entry["table"])
        entry["fingerprint"] = current
        save_manifest(path, manifest)
        print("SEALED", entry["table"], flush=True)


def verify(dst, path):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest["status"] != "applied" or any(x["state"] not in ("applied", "backup_only") for x in manifest["tables"]):
        raise RuntimeError("批次尚未完整匯入，不能驗證成功")
    start, end = dt.date.fromisoformat(manifest["start"]), dt.date.fromisoformat(manifest["end"])
    for entry in manifest["tables"]:
        table = tuple(entry["table"].split("."))
        actual = count(dst, table, tuple(entry["key"]), start, end, manifest["years"])
        expected = entry["source_count"] if entry["state"] == "applied" else entry["target_count"]
        if actual != expected:
            raise RuntimeError("筆數不符：{}，預期 {}，實際 {}".format(entry["table"], expected, actual))
        if not entry.get("fingerprint"):
            raise RuntimeError("Run is not sealed: " + entry["table"])
        if entry["state"] in ("applied", "backup_only"):
            if fingerprint(dst, table, tuple(entry["key"]), start, end, manifest["years"]) != entry["fingerprint"]:
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
    parser.add_argument("--start", type=dt.date.fromisoformat)
    parser.add_argument("--end", type=dt.date.fromisoformat)
    parser.add_argument("--source", default="GPstage")
    parser.add_argument("--destination", default="GP178")
    parser.add_argument("--years", type=int, default=2)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--allow-changes", action="store_true", help="Allow restore to discard changes made after apply")
    parser.add_argument("--table", action="append", help="只處理指定 schema.table；可重複指定")
    args = parser.parse_args()
    if args.action in ("seal", "verify", "restore"):
        if not args.manifest:
            parser.error("verify/restore 需要 --manifest")
        old = json.loads(args.manifest.read_text(encoding="utf-8"))
        if args.destination != old["destination"]:
            parser.error("--destination 與批次紀錄的目的庫不同")
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
    if not args.start or not args.end or args.start > args.end or args.years == 0:
        parser.error("須提供有效的 --start、--end 及非零 --years")
    with connect(args.source) as src, connect(args.destination) as dst:
        source_dsn = src.get_dsn_parameters()
        target_dsn = dst.get_dsn_parameters()
        identity = ("host", "port", "dbname")
        if all(source_dsn.get(k) == target_dsn.get(k) for k in identity):
            parser.error("source and destination refer to the same database")
        if args.action == "apply":
            lock_destination(dst)
        selected, skipped = plan(src, dst, args)
        print("selected={} skipped={} rows={}".format(len(selected), len(skipped), sum(x["source_count"] for x in selected)), flush=True)
        print("skipped:", json.dumps(skipped, ensure_ascii=False), flush=True)
        if args.action == "apply":
            apply(src, dst, args, selected, skipped)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(type(exc).__name__ + ": " + str(exc), file=sys.stderr)
        sys.exit(1)
