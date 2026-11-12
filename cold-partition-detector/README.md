# 冷資料表與零讀取分區偵測工具 (Cold Partition Detector)

本工具用於檢核 Greenplum 資料庫中「統計週期內零讀取」或「低於指定讀取門檻」的冷資料表與冷分區，協助 DBA 評估超冷資料離線儲存與釋放空間。

由於 Greenplum 採 MPP 分散式架構，查詢會分散由各 Segment 執行，本工具整合了 `gp_dist_random('pg_stat_user_tables')` 彙總全叢集節點的讀取次數（Sequential Scan + Index Scan），並自動關聯 `pg_partitions` 標註母表名稱、分區邊界及計算含單份 Mirror 預估之實體容量。

> **統計週期與下線決策注意事項**：
> 本工具讀取之統計計數係取自 `pg_stat_user_tables`。若資料庫曾執行 `pg_stat_reset` 重設統計，或系統剛重啟不久，計數為 0 僅代表「該統計區間內未被查詢」，不代表歷史上從未被存取。在進行資料歸檔或下線決策前，請確認統計收集已累積足夠長且具代表性之業務週期。

---

## 程式檔案說明

目錄下提供兩種版本的 Stored Function：

| 檔案名稱 | 說明 | 回傳格式 | 適用情境 |
| :--- | :--- | :--- | :--- |
| [`db_owner.fun_proc_chk_cold_partitions.sql`](db_owner.fun_proc_chk_cold_partitions.sql) | **正式專案規範版**<br>遵循標準 SP 結構規範，內建完整 Debug 與例外控制機制。 | `TEXT`<br>（輸出暫存表 `tmp_chk_cold_partitions`，回傳 `'T1'`） | 排程作業、正式程式庫納管、自動化檢核 |
| [`db_owner.fun_get_cold_partitions.sql`](db_owner.fun_get_cold_partitions.sql) | **DBA 輕量即用版**<br>不依賴特殊 Debug 函式，簡潔純 SQL 實作。 | `RETURNS TABLE(...)` | DBA 日常維運、psql 或 DBeaver 直接 `SELECT` 即查即看 |

---

## 使用方式

### 1. 正式專案規範版 (`fun_proc_chk_cold_partitions`)

在同一個資料庫連線中執行函式後，直接讀取暫存表 `tmp_chk_cold_partitions`：

```sql
-- 檢核 db_owner 底下統計期間內零讀取（0 次）的所有表與分區
SELECT db_owner.fun_proc_chk_cold_partitions('db_owner', '', 0);

-- 檢視產出之暫存表（僅篩選分區物件）
SELECT 
    parent_table_name,
    table_name,
    is_partition,
    partition_name,
    partition_boundary,
    size_pretty,
    size_mirror_pretty, -- 估算值：假設具備 1 份同步 Mirror
    total_reads,
    last_analyze
FROM tmp_chk_cold_partitions
WHERE is_partition = true
ORDER BY size_bytes DESC;
```

#### 參數說明
| 參數 | 型態 | 說明 | 範例 |
| :--- | :--- | :--- | :--- |
| `p_schema_name` | `TEXT` | 目標 Schema 名稱；傳入空字串 `''` 則查全庫所有非系統 Schema | `'db_owner'` |
| `p_parent_table` | `TEXT` | 指定母表名稱；傳入空字串 `''` 則查全體資料表與分區 | `'hmmtsf'` 或 `''` |
| `p_max_reads` | `BIGINT` | 判定為冷資料的總讀取次數上限（Seq Scan + Index Scan） | `0`（統計期內未被查詢）或 `5` |

---

### 2. DBA 輕量即用版 (`fun_get_cold_partitions`)

可直接作為 Table Function 進行過濾、排序與分頁：

```sql
-- 查出 db_owner 底下統計期間內零讀取（0 次）的前 20 大冷分區
SELECT 
    parent_table_name,
    partition_name,
    partition_boundary,
    size_pretty,
    size_mirror_pretty,
    total_reads,
    last_analyze
FROM db_owner.fun_get_cold_partitions('db_owner', '', 0)
WHERE is_partition = true
ORDER BY size_bytes DESC
LIMIT 20;

-- 指定查詢 hmmtsf 母表底下，讀取次數小於等於 2 次的冷分區
SELECT 
    partition_name,
    partition_boundary,
    size_pretty,
    total_reads
FROM db_owner.fun_get_cold_partitions('db_owner', 'hmmtsf', 2)
WHERE is_partition = true
ORDER BY partition_boundary ASC;
```

---

## 部署與依賴注意事項

1. **資料庫環境**：相容於 **Greenplum Database 6.x**（PostgreSQL 9.4.26 核心）。
2. **目錄權限**：執行帳號需具備讀取系統目錄 `pg_stat_user_tables`、`gp_dist_random('pg_stat_user_tables')` 及 `pg_partitions` 的權限。
3. **正式版依賴物件清單**：
   `db_owner.fun_proc_chk_cold_partitions.sql` 依據專案 SP 結構規範實作，若需部署正式版，目標資料庫需已建立下列物件：
   - **輔助除錯函式**：
     - `db_owner.func_init_dateandtime_out()`
     - `db_owner.func_fname_sname_out(TEXT)`
     - `db_owner.func_gen_debug_me(...)`
     - `db_owner.func_py_insert_debug(TEXT)`
   - **系統參數表**：
     - `db_owner.SVEL_PARAM`（欄位含 `param_event_id`、`param_name`、`param_value`；委派設定格式為 `param_name = 'SP:fun_proc_chk_cold_partitions'`）
   - **除錯紀錄日誌表**：
     - `db_owner.debug_log_s`（正常執行完成記錄）
     - `db_owner.debug_log_f`（例外失敗記錄）
4. **輕量版獨立性**：
   若測試環境或非正式庫尚未配置上述除錯日誌表格與函式，可直接部署並使用 [`db_owner.fun_get_cold_partitions.sql`](db_owner.fun_get_cold_partitions.sql)，其為純 SQL 實作，無任何額外外部相依。
