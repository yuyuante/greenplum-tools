-- =============================================================================
-- 檔案名稱 : db_owner.fun_proc_chk_cold_partitions.sql
-- 物件名稱 : db_owner.fun_proc_chk_cold_partitions
-- 適用平台 : Greenplum Database 6.26.3 / PostgreSQL 9.4.26
-- 程式說明 : 檢核冷資料表與零讀取分區清單（正式專案標準規範版）
--            彙總 Greenplum Master 與全體 Segments 之掃描次數（gp_dist_random），
--            篩選出統計週期內完全無人查詢或低於門檻之冷表與冷分區，產出暫存表 tmp_chk_cold_partitions。
--            注意：讀取次數為統計收集期內累計值（若曾執行 pg_stat_reset 或重啟需考量統計區間）。
-- =============================================================================

CREATE OR REPLACE FUNCTION db_owner.fun_proc_chk_cold_partitions(
    p_schema_name   TEXT,      -- 目標 Schema（如 'db_owner'；傳空字串則查全部非系統 Schema）
    p_parent_table  TEXT,      -- 指定母表名稱（如 'hmmtsf'；傳空字串則查全體資料表與分區）
    p_max_reads     BIGINT     -- 讀取次數上限（0 代表統計期間完全沒被查過，亦可傳入 5 以下之容許低頻值）
)
RETURNS TEXT
LANGUAGE 'plpgsql'
AS $$
-- ============================================================
-- 區塊標籤，供 EXCEPTION 區塊配對使用
-- ============================================================
<<LMAIN>>
DECLARE
    -- --------------------------------------------------------
    -- Debug 固定宣告變數（所有 Function 必須包含，勿刪除）
    -- --------------------------------------------------------
    v_debug_date        TEXT;        -- 執行日期
    v_debug_start_time  TEXT;        -- 執行開始時間
    v_debug_func_schema TEXT;        -- 所在 Schema
    v_debug_func_name   TEXT;        -- Function 名稱
    v_debug_msg_id      TEXT;        -- 目前執行段落代碼
    v_debug_msg_desc    TEXT;        -- 目前執行段落描述
    v_t1                TEXT;        -- 例外：message_text
    v_t2                TEXT;        -- 例外：pg_exception_detail
    v_t3                TEXT;        -- 例外：pg_exception_context
    v_debug_me          TEXT := NULL; -- 累積 debug 訊息字串

    -- --------------------------------------------------------
    -- 委派執行變數
    -- --------------------------------------------------------
    v_sqlcmd            TEXT := '';   -- 委派執行命令
    v_result            TEXT;         -- 委派執行回傳值

    -- --------------------------------------------------------
    -- 業務邏輯變數
    -- --------------------------------------------------------
    v_rowcount          BIGINT := 0;

BEGIN
/****************************************************************
** 安全等級 : 一般
** 程序代碼 : db_owner.fun_proc_chk_cold_partitions
** 程式名稱 : 檢核冷資料表與零讀取分區清單
** 撰寫日期 : 2026/11/10
** 說明     : 彙總 Greenplum Master 與所有 Segments 之掃描次數，
**            篩選出完全無人查詢（或低於指定門檻）之冷表與冷分區，
**            產出結果存入暫存表 tmp_chk_cold_partitions 供決策參照。
*****************************************************************/
/*
參數說明：
  p_schema_name  : 目標 Schema 名稱（如 'db_owner'），傳入空字串時查詢全部 User Schema。
  p_parent_table : 指定父表/母表名稱（如 'hmmtsf'），傳入空字串時查詢全庫所有表。
  p_max_reads    : 判定為冷資料之總讀取次數上限（Seq Scan + Index Scan），預設傳 0。

呼叫範例：
  SELECT db_owner.fun_proc_chk_cold_partitions('db_owner', '', 0);
  SELECT * FROM pg_temp.tmp_chk_cold_partitions ORDER BY size_bytes DESC;
*/

    -- ========================================================
    -- 【01000】初始化 Debug 資訊（固定段落）
    -- ========================================================
    SELECT * FROM db_owner.func_init_dateandtime_out()
        INTO v_debug_date, v_debug_start_time;

    v_debug_func_schema := current_schema();
    GET DIAGNOSTICS v_debug_func_name = PG_CONTEXT;
    SELECT * FROM db_owner.func_fname_sname_out(v_debug_func_name)
        INTO v_debug_func_schema, v_debug_func_name;

    -- 參數防呆與標準化（NULL 容錯轉換，負數門檻主動防禦拋錯）
    p_schema_name  := TRIM(COALESCE(p_schema_name, ''));
    p_parent_table := TRIM(COALESCE(p_parent_table, ''));
    p_max_reads    := COALESCE(p_max_reads, 0);
    IF p_max_reads < 0 THEN
        RAISE EXCEPTION 'p_max_reads 讀取門檻不得為負數: %', p_max_reads;
    END IF;

    v_debug_msg_id   := 'PARAM';
    v_debug_msg_desc := 'SELECT ' || v_debug_func_schema || '.' || v_debug_func_name
                        || '(''' || COALESCE(p_schema_name, '') || ''','''
                        || COALESCE(p_parent_table, '') || ''','
                        || COALESCE(p_max_reads::TEXT, '0') || ')';
    SELECT db_owner.func_gen_debug_me(
        v_debug_me, v_debug_date, v_debug_start_time,
        v_debug_func_schema, v_debug_func_name,
        '00001', v_debug_msg_desc
    ) INTO v_debug_me;

    -- ========================================================
    -- 【00002】查詢委派 Schema（SVEL_PARAM 設定）
    -- ========================================================
    SELECT quote_ident(TRIM(param_value)) || '.' || quote_ident(v_debug_func_name)
      INTO v_sqlcmd
      FROM db_owner.SVEL_PARAM
     WHERE param_event_id = ''
       AND param_name = 'SP:' || v_debug_func_name
       AND UPPER(param_value) NOT IN ('', 'DB_OWNER')
       AND UPPER(param_value) <> UPPER(v_debug_func_schema)
     LIMIT 1;
    v_sqlcmd := COALESCE(v_sqlcmd, '');

    IF v_sqlcmd <> '' THEN
        v_debug_msg_id   := '00002';
        v_debug_msg_desc := '委派至 ' || v_sqlcmd;
        SELECT db_owner.func_gen_debug_me(
            v_debug_me, v_debug_date, v_debug_start_time,
            v_debug_func_schema, v_debug_func_name,
            v_debug_msg_id, v_debug_msg_desc
        ) INTO v_debug_me;

        EXECUTE 'SELECT ' || v_sqlcmd || '($1, $2, $3)'
          USING p_schema_name, p_parent_table, p_max_reads
          INTO v_result;
        RETURN v_result;
    END IF;

    -- ========================================================
    -- 【00100】建立輸出暫存表 tmp_chk_cold_partitions
    -- ========================================================
    DROP TABLE IF EXISTS pg_temp.tmp_chk_cold_partitions;

    CREATE TEMP TABLE pg_temp.tmp_chk_cold_partitions (
        schema_name         VARCHAR(64),
        parent_table_name   VARCHAR(64),
        table_name          VARCHAR(64),
        is_partition        BOOLEAN,
        partition_name      VARCHAR(64),
        partition_boundary  TEXT,
        total_reads         BIGINT,
        seq_scan            BIGINT,
        idx_scan            BIGINT,
        live_tuples         BIGINT,
        size_pretty         TEXT,
        size_bytes          BIGINT,
        size_mirror_pretty  TEXT,
        last_analyze        TIMESTAMPTZ,
        last_vacuum         TIMESTAMPTZ
    ) ON COMMIT PRESERVE ROWS;

    ----------------------------------------------------------------------------------------------------
    SELECT db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00100', '建立輸出暫存表 tmp_chk_cold_partitions') INTO v_debug_me;
    ----------------------------------------------------------------------------------------------------

    -- ========================================================
    -- 【00200】彙總全叢集 Master 與 Segments 讀取計數並寫入暫存表
    -- ========================================================
    INSERT INTO pg_temp.tmp_chk_cold_partitions
    WITH cluster_stats AS (
        -- 彙總 Master 與所有 Segments 的讀取統計
        SELECT
            schemaname,
            relname,
            SUM(seq_scan)   AS sum_seq_scan,
            SUM(idx_scan)   AS sum_idx_scan,
            SUM(n_live_tup) AS sum_live_tuples,
            MAX(last_analyze) AS max_last_analyze,
            MAX(last_vacuum)  AS max_last_vacuum
        FROM (
            SELECT schemaname, relname, seq_scan, idx_scan, n_live_tup, last_analyze, last_vacuum
              FROM pg_stat_user_tables
            UNION ALL
            SELECT schemaname, relname, seq_scan, idx_scan, n_live_tup, last_analyze, last_vacuum
              FROM gp_dist_random('pg_stat_user_tables')
        ) all_nodes
        WHERE (p_schema_name = '' OR schemaname = p_schema_name)
        GROUP BY schemaname, relname
    ),
    partition_meta AS (
        -- 關聯 Greenplum 分區字典
        SELECT
            schemaname,
            tablename           AS parent_name,
            partitiontablename  AS part_relname,
            partitionname       AS part_logical_name,
            partitionboundary   AS boundary_expr
        FROM pg_partitions
        WHERE (p_schema_name = '' OR schemaname = p_schema_name)
    ),
    cluster_sizes AS (
        -- 透過 gp_dist_random 彙總全叢集各 Segment 實體物理磁碟容量（包含 TOAST 與索引）
        SELECT
            n.nspname AS schemaname,
            c.relname,
            SUM(pg_total_relation_size(c.oid))::BIGINT AS sum_total_size
        FROM gp_dist_random('pg_class') c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r'
          AND (p_schema_name = '' OR n.nspname = p_schema_name)
        GROUP BY n.nspname, c.relname
    ),
    filtered_relations AS (
        -- 預先過濾候選冷物件並結合全叢集實體容量
        SELECT
            s.schemaname,
            COALESCE(p.parent_name, s.relname) AS parent_table_name,
            s.relname                          AS table_name,
            (p.part_relname IS NOT NULL)       AS is_partition,
            COALESCE(p.part_logical_name, '-') AS partition_name,
            COALESCE(p.boundary_expr, 'N/A')   AS partition_boundary,
            (COALESCE(s.sum_seq_scan, 0) + COALESCE(s.sum_idx_scan, 0)) AS total_reads,
            COALESCE(s.sum_seq_scan, 0)        AS seq_scan,
            COALESCE(s.sum_idx_scan, 0)        AS idx_scan,
            COALESCE(s.sum_live_tuples, 0)     AS live_tuples,
            COALESCE(z.sum_total_size, 0)::BIGINT AS size_bytes,
            s.max_last_analyze,
            s.max_last_vacuum
        FROM cluster_stats s
        JOIN pg_class c
          ON c.relname = s.relname
        JOIN pg_namespace n
          ON n.oid = c.relnamespace AND n.nspname = s.schemaname
        LEFT JOIN partition_meta p
          ON p.schemaname = s.schemaname AND p.part_relname = s.relname
        LEFT JOIN cluster_sizes z
          ON z.schemaname = s.schemaname AND z.relname = s.relname
        WHERE c.relkind = 'r'
          AND (COALESCE(s.sum_seq_scan, 0) + COALESCE(s.sum_idx_scan, 0)) <= COALESCE(p_max_reads, 0)
          AND (p_parent_table = '' OR COALESCE(p.parent_name, s.relname) = p_parent_table)
    )
    SELECT
        schemaname::VARCHAR(64),
        parent_table_name::VARCHAR(64),
        table_name::VARCHAR(64),
        is_partition,
        partition_name::VARCHAR(64),
        partition_boundary,
        total_reads,
        seq_scan,
        idx_scan,
        live_tuples,
        pg_size_pretty(size_bytes)     AS size_pretty,
        size_bytes,
        pg_size_pretty(size_bytes * 2) AS size_mirror_pretty, -- 估算值：假設具備 1 份同步 Mirror
        max_last_analyze,
        max_last_vacuum
    FROM filtered_relations;

    GET DIAGNOSTICS v_rowcount = ROW_COUNT;

    ----------------------------------------------------------------------------------------------------
    SELECT db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00200', '篩選冷資料完成，共擷取筆數: ' || v_rowcount) INTO v_debug_me;
    ----------------------------------------------------------------------------------------------------

    -- ========================================================
    -- 【99999】程式結尾：寫入 debug LOG 並回傳 Temp Table 代號
    -- ========================================================
    v_debug_msg_id   := 'END';
    v_debug_msg_desc := '冷分區清單已產生至 tmp_chk_cold_partitions';
    SELECT db_owner.func_gen_debug_me(
        v_debug_me, v_debug_date, v_debug_start_time,
        v_debug_func_schema, v_debug_func_name,
        v_debug_msg_id, v_debug_msg_desc
    ) INTO v_debug_me;

    PERFORM db_owner.func_py_insert_debug(
        'insert into db_owner.debug_log_s ' || v_debug_me || ')'
    );

    RETURN 'T1';

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        v_t1 = MESSAGE_TEXT,
        v_t2 = PG_EXCEPTION_DETAIL,
        v_t3 = PG_EXCEPTION_CONTEXT;

    -- 保護日誌記錄動作，避免除錯機制本身異常遮蔽主例外
    BEGIN
        v_debug_msg_id   := 'ERR';
        v_debug_msg_desc := SUBSTR(v_t1 || ' | ' || COALESCE(v_t2, '') || ' | ' || COALESCE(v_t3, ''), 1, 500);
        SELECT db_owner.func_gen_debug_me(
            v_debug_me, v_debug_date, v_debug_start_time,
            v_debug_func_schema, v_debug_func_name,
            v_debug_msg_id, v_debug_msg_desc
        ) INTO v_debug_me;

        PERFORM db_owner.func_py_insert_debug(
            'insert into db_owner.debug_log_f ' || v_debug_me || ')'
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- 重新拋出原始例外，保留原始 SQLSTATE 與呼叫堆疊
    RAISE;

END LMAIN;
$$;
