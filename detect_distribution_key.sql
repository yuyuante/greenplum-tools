-- ============================================================================
-- Greenplum Optimal Distribution Key Detector
-- Description: Analyzes table columns' cardinality, null fractions, and most
--              common values to suggest the best distribution key.
-- Compatibility: Greenplum 5.x, 6.x, 7.x+
-- Usage: SELECT * FROM public.gp_detect_distribution_key('schema', 'table');
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gp_detect_distribution_key(
    p_schema_name text,
    p_table_name text
)
RETURNS TABLE (
    column_name text,
    data_type text,
    n_distinct real,
    null_fraction real,
    max_value_freq real,
    recommendation_score integer,
    suitability_rating text,
    analysis_detail text
) AS $$
DECLARE
    v_table_oid oid;
    v_total_rows bigint;
    v_current_policy text;
    v_segment_count integer;
    v_current_cv real;
    v_skew_sql text;
    v_stats_exist boolean;
BEGIN
    -- 1. 驗證資料表是否存在並獲取 OID
    BEGIN
        v_table_oid := (quote_ident(p_schema_name) || '.' || quote_ident(p_table_name))::regclass;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION '資料表 %.% 不存在或無存取權限。', p_schema_name, p_table_name;
    END;

    -- 2. 獲取目前資料表的總筆數
    EXECUTE format('SELECT count(*) FROM %I.%I', p_schema_name, p_table_name) INTO v_total_rows;
    
    -- 3. 獲取目前的分佈策略
    v_current_policy := pg_get_table_distributedby(v_table_oid);

    -- 4. 取得系統 Segment 總數
    SELECT count(*) INTO v_segment_count 
    FROM gp_segment_configuration 
    WHERE role = 'p' AND content >= 0;

    -- 5. 計算當前資料表的變異係數 (CV)
    IF v_total_rows > 0 AND v_segment_count > 0 THEN
        v_skew_sql := format('
            SELECT 
                stddev(cnt) / nullif(avg(cnt), 0)
            FROM (
                SELECT gp_segment_id, count(*) as cnt 
                FROM %I.%I 
                GROUP BY gp_segment_id
            ) sub', p_schema_name, p_table_name);
        EXECUTE v_skew_sql INTO v_current_cv;
    ELSE
        v_current_cv := 0.0;
    END IF;

    -- 6. 檢查是否有該表的統計資料 (pg_stats)
    SELECT EXISTS (
        SELECT 1 FROM pg_stats 
        WHERE schemaname = p_schema_name AND tablename = p_table_name
    ) INTO v_stats_exist;

    -- 若無統計資料，發出警告提示使用者進行 ANALYZE
    IF NOT v_stats_exist AND v_total_rows > 0 THEN
        RAISE WARNING '警告: 資料表 %.% 尚未進行 ANALYZE，評估結果可能不精確。建議先執行: ANALYZE %.%', 
            p_schema_name, p_table_name, p_schema_name, p_table_name;
    END IF;

    -- 7. 第一行：輸出資料表目前的分佈摘要資訊
    column_name := '== CURRENT_TABLE_STATUS ==';
    data_type := format('Row Count: %s', v_total_rows::text);
    n_distinct := v_segment_count::real; -- 以此欄位借放 Segment 總數
    null_fraction := v_current_cv;       -- 以此欄位借放目前的 CV 係數
    max_value_freq := 0.0;
    recommendation_score := CASE 
        WHEN v_current_cv <= 0.1 THEN 100
        WHEN v_current_cv <= 0.3 THEN 80
        WHEN v_current_cv <= 0.5 THEN 50
        ELSE 10
    END;
    suitability_rating := CASE 
        WHEN v_current_cv <= 0.1 THEN 'EXCELLENT'
        WHEN v_current_cv <= 0.3 THEN 'GOOD'
        WHEN v_current_cv <= 0.5 THEN 'WARN'
        ELSE 'CRITICAL_SKEW'
    END;
    analysis_detail := format('目前策略: %s | 傾斜 CV 係數: %s | Segment 數: %s', 
                              v_current_policy, 
                              coalesce(round(v_current_cv::numeric, 4)::text, 'N/A'), 
                              v_segment_count);
    RETURN NEXT;

    -- 8. 遍歷合適的欄位進行分佈指標分析
    RETURN QUERY
    WITH column_candidates AS (
        -- 篩選出支援 Hash 運算的常見欄位型態，排除大欄位、JSON 及地理欄位
        SELECT 
            a.attname::text AS col_name,
            format_type(a.atttypid, a.atttypmod) AS col_type
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.oid = v_table_oid
          AND a.attnum > 0 
          AND NOT a.attisdropped
          -- 排除大型欄位與不適合做雜湊分佈的型態
          AND format_type(a.atttypid, a.atttypmod) NOT IN (
              'bytea', 'text', 'json', 'jsonb', 'xml', 'tsvector', 'cidr', 'inet', 'macaddr'
          )
          AND format_type(a.atttypid, a.atttypmod) NOT LIKE 'geometry%'
          AND format_type(a.atttypid, a.atttypmod) NOT LIKE '%[]%'
    ),
    stats_summary AS (
        -- 結合 pg_stats 系統統計資料
        SELECT 
            c.col_name,
            c.col_type,
            coalesce(s.n_distinct, -0.1) AS s_n_distinct,
            coalesce(s.null_frac, 0.0) AS s_null_frac,
            coalesce(s.most_common_freqs[1], 0.0) AS s_max_freq
        FROM column_candidates c
        LEFT JOIN pg_stats s ON s.schemaname = p_schema_name 
                            AND s.tablename = p_table_name 
                            AND s.attname = c.col_name
    ),
    scored_candidates AS (
        SELECT 
            col_name,
            col_type,
            s_n_distinct,
            s_null_frac,
            s_max_freq,
            -- 評估分數演算法 (滿分 100)
            (
                50 -- 基礎分
                -- A. 唯一值基數評分 (滿分 30)
                + CASE 
                    WHEN s_n_distinct < 0 THEN 30 -- 唯一值按比例增加 (例如 -1 表示全部 unique)
                    WHEN s_n_distinct >= 100000 THEN 30
                    WHEN s_n_distinct >= 10000 THEN 25
                    WHEN s_n_distinct >= 1000 THEN 15
                    WHEN s_n_distinct >= v_segment_count * 10 THEN 5
                    WHEN s_n_distinct < v_segment_count THEN -40 -- 唯一值少於 Segment 數，極差
                    ELSE 0
                  END
                -- B. 空值扣分 (最重扣 50)
                - (s_null_frac * 60)::integer
                -- C. 最大高頻值扣分 (最重扣 50)
                - (s_max_freq * 80)::integer
                -- D. 資料型態適配性加減分 (加減 10)
                + CASE 
                    WHEN col_type IN ('bigint', 'integer', 'int8', 'int4', 'uuid') THEN 10 -- 數值/UUID 最適合 JOIN
                    WHEN col_type IN ('date', 'timestamp without time zone', 'timestamp with time zone') THEN 5
                    WHEN col_type LIKE 'character%' AND col_type NOT LIKE '%varying%' THEN 2
                    WHEN col_type LIKE 'varchar%' THEN 0
                    ELSE -10
                  END
            ) AS raw_score
        FROM stats_summary
    )
    SELECT 
        col_name,
        col_type,
        s_n_distinct,
        s_null_frac,
        s_max_freq,
        -- 確保分數介於 0 到 100 之間
        CASE 
            WHEN raw_score > 100 THEN 100
            WHEN raw_score < 0 THEN 0
            ELSE raw_score
        END::integer AS final_score,
        -- 適配等級定義
        CASE 
            WHEN (raw_score) >= 85 AND s_n_distinct >= v_segment_count THEN 'STRONGLY_RECOMMENDED'
            WHEN (raw_score) >= 70 AND s_n_distinct >= v_segment_count THEN 'RECOMMENDED'
            WHEN (raw_score) >= 50 AND s_n_distinct >= v_segment_count THEN 'ACCEPTABLE'
            ELSE 'POOR'
        END::text AS suitability,
        -- 詳細分析說明
        CASE 
            -- 唯一值少於 Segment 的致命錯誤
            WHEN s_n_distinct > 0 AND s_n_distinct < v_segment_count THEN 
                format('極差! 唯一值個數 (%s) 少於系統 Segment 數 (%s)，會造成部分 Segment 閒置。', s_n_distinct, v_segment_count)
            -- 空值過高的情況
            WHEN s_null_frac > 0.3 THEN 
                format('不建議! 空值率高達 %s%%，會導致大量 NULL 集中在同一 Segment。', round((s_null_frac*100)::numeric, 2))
            -- 重複值比例過高 (Heavy Hitter)
            WHEN s_max_freq > 0.15 THEN 
                format('有傾斜風險! 單一高頻值佔比達 %s%%，建議搭配其他欄位組合或改隨機分佈。', round((s_max_freq*100)::numeric, 2))
            -- 完美候選者
            WHEN s_n_distinct < 0 OR s_n_distinct >= 50000 THEN 
                format('優異! 基數大(接近唯一值)且無明顯高頻值，是最佳的分佈鍵與 JOIN 鍵。', s_n_distinct)
            ELSE 
                format('基數估計值: %s | 空值率: %s%% | 最大值頻率: %s%%。', 
                       CASE WHEN s_n_distinct < 0 THEN '按比例(' || s_n_distinct || ')' ELSE s_n_distinct::text END,
                       round((s_null_frac*100)::numeric, 2),
                       round((s_max_freq*100)::numeric, 2))
        END::text AS advice
    FROM scored_candidates
    ORDER BY final_score DESC;
END;
$$ LANGUAGE plpgsql;
