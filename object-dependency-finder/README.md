# 物件相依關係查詢

[`DB_OWNER.fun_proc_gen_dep.sql`](DB_OWNER.fun_proc_gen_dep.sql) 收錄 GP178 上 `db_owner.proc_gen_dep` 的完整函式定義。此函式查詢 Greenplum 物件的上游或下游相依關係。

## 使用方式

在已安裝此函式及其相依函式的 Greenplum 資料庫執行：

```sql
SELECT db_owner.proc_gen_dep('t', 'apusr2', 'employees', 2, 12, 2, '');
SELECT * FROM tmp_dep_result;
SELECT * FROM tmp_dep_func_detail;
```

須在同一個資料庫連線中讀取暫存表。函式回傳 `text` 狀態值，查詢結果寫入暫存表。

| 參數 | 用途 | 預設值 |
| --- | --- | --- |
| `v_object_type` | 物件類型：`t` 表格、`v` 檢視、`m` 物化檢視、`f` 函式、`tg` 觸發器 | 必填 |
| `v_schema_name` | 物件的 schema | 必填 |
| `v_object_name` | 物件名稱 | 必填 |
| `v_max_dep_level` | 相依關係搜尋層數 | `1` |
| `v_month` | 歷史月份範圍 | `12` |
| `v_flow_direction` | `1` 上游、`2` 下游 | `1` |
| `v_flag` | 函式內部除錯旗標 | `'XXX'` |

## 來源與部署

SQL 由 GP178 的 `pg_get_functiondef` 匯出，並依該函式的 `proexeclocation = 'a'` 保留 `EXECUTE ON ANY`。部署前需確認目標資料庫已有 `db_owner` schema 及函式內呼叫的輔助函式，例如 `db_owner.func_init_dateandtime_out`、`db_owner.func_fname_sname_out`、`db_owner.func_gen_debug_me` 和 `db_owner.func_py_insert_debug`。執行 SQL 會建立或取代目標資料庫的函式。
