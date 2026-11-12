-- =============================================================================
-- 檔案名稱 : db_owner.fun_get_cold_partitions.sql
-- 物件名稱 : db_owner.fun_get_cold_partitions
-- 適用平台 : Greenplum Database 6.26.3 / PostgreSQL 9.4.26
-- 程式說明 : 查詢冷資料表與零讀取分區清單（DBA 輕量即用版 - RETURNS TABLE）
--            不依賴特定 Debug 日誌機制，方便 DBA 在 psql 或 DBeaver 直接 SELECT 檢視結果。
--            注意：讀取次數為統計收集期內累計值（若曾執行 pg_stat_reset 或重啟需考量統計區間）。
-- =============================================================================

CREATE OR REPLACE FUNCTION db_owner.fun_get_cold_partitions(
    p_schema_name   TEXT DEFAULT 'db_owner',
    p_parent_table  TEXT DEFAULT '',
    p_max_reads     BIGINT DEFAULT 0
)
RETURNS TABLE (
    schema_name         VARCHAR,
    parent_table_name   VARCHAR,
    table_name          VARCHAR,
    is_partition        BOOLEAN,
    partition_name      VARCHAR,
    partition_boundary  TEXT,
    total_reads         BIGINT,
    seq_scan            BIGINT,
    idx_scan            BIGINT,
    live_tuples         BIGINT,
    size_pretty         TEXT,
    size_mirror_pretty  TEXT,
    size_bytes          BIGINT,
    last_analyze        TIMESTAMPTZ
)
LANGUAGE 'plpgsql'
STABLE
AS $$
#variable_conflict use_column
BEGIN
    -- 參數防呆與修剪
    p_schema_name  := TRIM(COALESCE(p_schema_name, ''));
    p_parent_table := TRIM(COALESCE(p_parent_table, ''));
    p_max_reads    := COALESCE(p_max_reads, 0);

    IF p_max_reads < 0 THEN
        RAISE EXCEPTION 'p_max_reads 門檻值不得為負數: %', p_max_reads;
    END IF;

    RETURN QUERY
    WITH cluster_stats AS (
        -- 結合 Master 與全體 Segments 統計數值
        SELECT
            schemaname,
            relname,
            SUM(seq_scan)     AS sum_seq_scan,
            SUM(idx_scan)     AS sum_idx_scan,
            SUM(n_live_tup)   AS sum_live_tuples,
            MAX(last_analyze) AS max_last_analyze
        FROM (
            SELECT schemaname, relname, seq_scan, idx_scan, n_live_tup, last_analyze
              FROM pg_stat_user_tables
            UNION ALL
            SELECT schemaname, relname, seq_scan, idx_scan, n_live_tup, last_analyze
              FROM gp_dist_random('pg_stat_user_tables')
        ) all_stats
        WHERE (p_schema_name = '' OR schemaname = p_schema_name)
        GROUP BY schemaname, relname
    ),
    partition_meta AS (
        -- 關聯 Greenplum 分區結構字典
        SELECT
            schemaname,
            tablename          AS parent_name,
            partitiontablename AS part_relname,
            partitionname      AS part_logical_name,
            partitionboundary  AS boundary_expr
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
            s.max_last_analyze
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
          AND (COALESCE(s.sum_seq_scan, 0) + COALESCE(s.sum_idx_scan, 0)) <= p_max_reads
          AND (p_parent_table = '' OR COALESCE(p.parent_name, s.relname) = p_parent_table)
    )
    SELECT
        filtered_relations.schemaname::VARCHAR,
        filtered_relations.parent_table_name::VARCHAR,
        filtered_relations.table_name::VARCHAR,
        filtered_relations.is_partition,
        filtered_relations.partition_name::VARCHAR,
        filtered_relations.partition_boundary,
        filtered_relations.total_reads::BIGINT,
        filtered_relations.seq_scan::BIGINT,
        filtered_relations.idx_scan::BIGINT,
        filtered_relations.live_tuples::BIGINT,
        pg_size_pretty(filtered_relations.size_bytes)::TEXT     AS size_pretty,
        pg_size_pretty(filtered_relations.size_bytes * 2)::TEXT AS size_mirror_pretty, -- 估算值：假設具備 1 份同步 Mirror
        filtered_relations.size_bytes::BIGINT,
        filtered_relations.max_last_analyze
    FROM filtered_relations
    ORDER BY filtered_relations.size_bytes DESC;
END;
$$;
