-- =============================================================================
-- 檔案名稱 : test_cold_partition_detector.sql
-- 程式說明 : 冷資料表與零讀取分區偵測工具之單元測試與回歸測試套件 (TestSuite)
-- 適用平台 : Greenplum Database 6.x / PostgreSQL 9.4.26
-- 規範參照 : .claude/testsuite_spec.md
-- =============================================================================

-- 1. 建立測試結果彙整暫存表
DROP TABLE IF EXISTS pg_temp.tc_result;
CREATE TEMP TABLE pg_temp.tc_result (
    test_case       VARCHAR(20),
    test_desc       VARCHAR(200),
    input_data      VARCHAR(1000),
    expected_result VARCHAR(500),
    actual_result   VARCHAR(500),
    result          VARCHAR(10)
);

-- 2. 執行測試案例套件
DO $$
DECLARE
    v_ret_text      TEXT;
    v_err_msg       TEXT;
    v_row_count     BIGINT;
    v_part_name     TEXT;
    v_part_boundary TEXT;
BEGIN
    -- -------------------------------------------------------------------------
    -- TC-CPD-001: 正式版 - 正常參數執行驗證
    -- -------------------------------------------------------------------------
    BEGIN
        v_ret_text := db_owner.fun_proc_chk_cold_partitions('db_owner', '', 0);
        -- 嚴格斷言：驗證回傳代碼為 T1 且輸出暫存表確實建立且可讀取
        SELECT COUNT(*) INTO v_row_count FROM pg_temp.tmp_chk_cold_partitions;
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-001',
            '正式版 - 正常參數執行並回傳暫存表代碼',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=0',
            '回傳 T1 且成功建立 tmp_chk_cold_partitions 暫存表',
            '回傳: ' || COALESCE(v_ret_text, 'NULL') || ', 暫存表驗證存在(筆數=' || v_row_count || ')',
            CASE WHEN v_ret_text = 'T1' THEN 'PASS' ELSE 'FAIL' END
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-001',
            '正式版 - 正常參數執行並回傳暫存表代碼',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=0',
            '回傳 T1 且成功建立 tmp_chk_cold_partitions 暫存表',
            '例外拋出: ' || SQLERRM,
            'FAIL'
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-002: 正式版 - NULL 參數容錯防呆驗證
    -- -------------------------------------------------------------------------
    BEGIN
        v_ret_text := db_owner.fun_proc_chk_cold_partitions(NULL, NULL, NULL);
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-002',
            '正式版 - NULL 參數容錯防呆驗證',
            'p_schema_name=NULL, p_parent_table=NULL, p_max_reads=NULL',
            '自動正規化為預設值並正常回傳 T1',
            '回傳: ' || COALESCE(v_ret_text, 'NULL'),
            CASE WHEN v_ret_text = 'T1' THEN 'PASS' ELSE 'FAIL' END
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-002',
            '正式版 - NULL 參數容錯防呆驗證',
            'p_schema_name=NULL, p_parent_table=NULL, p_max_reads=NULL',
            '自動正規化為預設值並正常回傳 T1',
            '例外拋出: ' || SQLERRM,
            'FAIL'
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-003: 正式版 - 負數門檻拒絕回歸測試
    -- -------------------------------------------------------------------------
    BEGIN
        v_err_msg := '未拋出例外';
        PERFORM db_owner.fun_proc_chk_cold_partitions('db_owner', '', -1);
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-003',
            '正式版 - 負數讀取門檻拒絕回歸測試',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=-1',
            '主動拒絕並拋出 EXCEPTION (不得為負數)',
            v_err_msg,
            'FAIL'
        );
    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-003',
            '正式版 - 負數讀取門檻拒絕回歸測試',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=-1',
            '主動拒絕並拋出 EXCEPTION (不得為負數)',
            '成功攔截例外: ' || v_err_msg,
            CASE WHEN v_err_msg LIKE '%不得為負數%' THEN 'PASS' ELSE 'FAIL' END
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-004: 輕量版 - 正常參數執行驗證
    -- -------------------------------------------------------------------------
    BEGIN
        SELECT COUNT(*) INTO v_row_count
          FROM db_owner.fun_get_cold_partitions('db_owner', '', 0);
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-004',
            '輕量版 - 正常參數執行驗證',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=0',
            '正常查詢回傳結果集無例外',
            '查詢成功，回傳筆數: ' || v_row_count::TEXT,
            'PASS'
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-004',
            '輕量版 - 正常參數執行驗證',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=0',
            '正常查詢回傳結果集無例外',
            '例外拋出: ' || SQLERRM,
            'FAIL'
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-005: 輕量版 - NULL 參數容錯防呆驗證
    -- -------------------------------------------------------------------------
    BEGIN
        SELECT COUNT(*) INTO v_row_count
          FROM db_owner.fun_get_cold_partitions(NULL, NULL, NULL);
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-005',
            '輕量版 - NULL 參數容錯防呆驗證',
            'p_schema_name=NULL, p_parent_table=NULL, p_max_reads=NULL',
            '自動正規化為預設值並正常回傳',
            '查詢成功，回傳筆數: ' || v_row_count::TEXT,
            'PASS'
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-005',
            '輕量版 - NULL 參數容錯防呆驗證',
            'p_schema_name=NULL, p_parent_table=NULL, p_max_reads=NULL',
            '自動正規化為預設值並正常回傳',
            '例外拋出: ' || SQLERRM,
            'FAIL'
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-006: 輕量版 - 負數門檻拒絕回歸測試
    -- -------------------------------------------------------------------------
    BEGIN
        v_err_msg := '未拋出例外';
        PERFORM * FROM db_owner.fun_get_cold_partitions('db_owner', '', -5);
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-006',
            '輕量版 - 負數讀取門檻拒絕回歸測試',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=-5',
            '主動拒絕並拋出 EXCEPTION (不得為負數)',
            v_err_msg,
            'FAIL'
        );
    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-006',
            '輕量版 - 負數讀取門檻拒絕回歸測試',
            'p_schema_name=''db_owner'', p_parent_table='''', p_max_reads=-5',
            '主動拒絕並拋出 EXCEPTION (不得為負數)',
            '成功攔截例外: ' || v_err_msg,
            CASE WHEN v_err_msg LIKE '%不得為負數%' THEN 'PASS' ELSE 'FAIL' END
        );
    END;

    -- -------------------------------------------------------------------------
    -- TC-CPD-007: 跨 Segment MPP 統計與分區容量彙總驗證
    -- -------------------------------------------------------------------------
    BEGIN
        -- 呼叫正式版程序檢核讀取門檻 10 次之冷分區
        PERFORM db_owner.fun_proc_chk_cold_partitions('db_owner', 'test_parent_tbl', 10);
        
        -- 精確斷言：核對 total_reads 精確等於 5，且 partition_name='p1'，partition_boundary 包含 'START (1) END (2)'
        SELECT
            total_reads,
            partition_name,
            partition_boundary
        INTO
            v_row_count,
            v_part_name,
            v_part_boundary
        FROM pg_temp.tmp_chk_cold_partitions
        WHERE table_name = 'test_part_tbl_1' AND is_partition = true;

        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-007',
            '跨 Segment MPP 讀取統計與分區字典關聯彙整驗證',
            'p_schema_name=''db_owner'', p_parent_table=''test_parent_tbl'', p_max_reads=10',
            '精確彙總 2 Segments 讀取次數 (total_reads=5) 且分區標註為 p1, START (1) END (2)',
            '實際 total_reads: ' || COALESCE(v_row_count::TEXT, '0') || ', 分區名: ' || COALESCE(v_part_name, 'NULL') || ', 邊界: ' || COALESCE(v_part_boundary, 'NULL'),
            CASE WHEN v_row_count = 5 AND v_part_name = 'p1' AND v_part_boundary LIKE '%START (1) END (2)%' THEN 'PASS' ELSE 'FAIL' END
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.tc_result VALUES (
            'TC-CPD-007',
            '跨 Segment MPP 讀取統計與分區字典關聯彙整驗證',
            'p_schema_name=''db_owner'', p_parent_table=''test_parent_tbl'', p_max_reads=10',
            '精確彙總 2 Segments 讀取次數且分區標註完整',
            '例外拋出: ' || SQLERRM,
            'FAIL'
        );
    END;
END;
$$;

-- 3. 輸出測試結果明細
SELECT
    test_case,
    test_desc,
    input_data,
    expected_result,
    actual_result,
    result
FROM pg_temp.tc_result
ORDER BY test_case;

-- 4. 統計彙整
DO $$
DECLARE
    v_pass INT;
    v_fail INT;
BEGIN
    SELECT COUNT(*) INTO v_pass FROM pg_temp.tc_result WHERE result = 'PASS';
    SELECT COUNT(*) INTO v_fail FROM pg_temp.tc_result WHERE result = 'FAIL';
    RAISE NOTICE '==================================================';
    RAISE NOTICE 'TestSuite 執行結果: PASS = %, FAIL = %', v_pass, v_fail;
    IF v_fail = 0 THEN
        RAISE NOTICE '✅ 全部 % 個測試案例通過', v_pass;
    ELSE
        RAISE EXCEPTION '❌ TestSuite 執行失敗: 共 % 個測試案例未通過', v_fail;
    END IF;
    RAISE NOTICE '==================================================';
END;
$$;
