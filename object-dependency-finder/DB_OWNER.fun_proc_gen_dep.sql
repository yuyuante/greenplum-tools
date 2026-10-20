-- select security_db.func_drop_func_with_any_arg('db_owner', 'proc_gen_dep');
CREATE OR REPLACE FUNCTION db_owner.proc_gen_dep(
    v_object_type character varying,        -- 't' 表格、'f' 函式、'v' 檢視、'm' 物化檢視、'tg' 觸發器
    v_schema_name character varying,        -- 查詢的 schema
    v_object_name character varying,        -- 查詢的物件名稱
    v_max_dep_level integer DEFAULT 1,      -- 相依關係查詢層數；2025/07/02 調整預設值為 1
    v_month integer DEFAULT 12,             -- 查詢過去的月份數
    v_flow_direction integer DEFAULT 1,     -- 1 上游、2 下游；2025/08/07 新增
    v_flag text DEFAULT 'XXX'::text
)
RETURNS text
LANGUAGE plpgsql
AS $function$

<<LMAIN>>
declare
    v_object_exists       boolean                ;
    current_dep_level     integer       default 0;
    r                     record                 ;
    ----------debug parameter----------
    v_debug_date          text;   -- OMNIWARESOFT: the date of execution
    v_debug_start_time    text;   -- OMNIWARESOFT: the time of the execution(procedure)
    v_debug_func_schema   text;
    v_debug_func_name     text;
    v_debug_msg_id        text;
    v_debug_msg_desc      text;
    v_t1                  text;
    v_t2                  text;
    v_t3                  text;
    v_debug_me            text := null;
    v_desc                text;
BEGIN
    /****************************************************************
    ** 安全等級 : 機密
    ** 程序代碼 : db_owner.proc_gen_dep
    ** 程序名稱 : 資料庫物件 Dependency 關係查詢
    ** 設 計 者 :
    ** 編碼日期 : 2025/03/20
    ** 使用範圍 : 資料庫
    ** 說    明 : 查詢資料庫物件的上游或下游相依關係
    ** 異動日期 : 2025/05/09
    ** 異動說明 : 調整輸出欄位順序
    ** 異動日期 : 2025/06/11
    ** 異動說明 : 新增輸出欄位內容與函式細節暫存表
    ** 異動日期 : 2025/07/02
    ** 異動說明 : 調整 v_max_dep_level 預設值、新增程序起點，計算函式執行時間
    ** 異動日期 : 2025/08/07
    ** 異動說明 : 新增 v_flow_direction，支援查詢物件的上、下游相依關係
    *****************************************************************/
    /* 測試範例；查詢結果須在同一連線中讀取暫存表。
    SELECT db_owner.proc_gen_dep('t','apusr2','employees_audit','1','12','1','');          -- 表格上游
    SELECT db_owner.proc_gen_dep('t','apusr2','employees','2','12','2','');                -- 表格下游
    SELECT db_owner.proc_gen_dep('v','db_owner','vuinv','1','12','1','');                  -- 檢視上游
    SELECT db_owner.proc_gen_dep('v','db_owner','vuinv','1','12','2','');                  -- 檢視下游
    SELECT db_owner.proc_gen_dep('m','db_owner','mvrigv2','2','12','1','');                -- 物化檢視上游
    SELECT db_owner.proc_gen_dep('m','db_owner','mvrigv2','2','12','2','');                -- 物化檢視下游
    SELECT db_owner.proc_gen_dep('f','db_owner','proc_gen_newm_c7_65','2','12','1','');    -- 函式上游
    SELECT db_owner.proc_gen_dep('f','db_owner','proc_get_kind_list','1','12','2','');     -- 函式下游
    SELECT db_owner.proc_gen_dep('tg','apusr2','employee_insert_trigger','1','12','1',''); -- 觸發器上游
    SELECT db_owner.proc_gen_dep('tg','apusr2','employee_insert_trigger','1','12','2',''); -- 觸發器下游
    SELECT db_owner.proc_gen_dep('x','db_owner','mvrigv2','1','12','1','');                -- 不存在的物件類型
    SELECT db_owner.proc_gen_dep('t','apusr2','abcabcabc','1','12','2','');                -- 不存在的表格
    SELECT * FROM tmp_dep_result;
    SELECT * FROM tmp_dep_func_detail;
    */

    --------------------------debug---------------------------
    SELECT * FROM db_owner.func_init_dateandtime_out() INTO v_debug_date, v_debug_start_time;
    GET DIAGNOSTICS v_debug_func_name = PG_CONTEXT;
    SELECT * FROM db_owner.func_fname_sname_out(v_debug_func_name) INTO v_debug_func_schema, v_debug_func_name;
    v_debug_msg_id := 'PARAM';
    v_debug_msg_desc := 'SELECT ' || v_debug_func_schema || '.' || v_debug_func_name || '('''|| $1 ||''','''|| $2 ||''','''|| $3 ||''','''|| $4 ||''','''|| ''')';
    SELECT db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, v_debug_msg_id, v_debug_msg_desc) INTO v_debug_me;
    --------------------------debug---------------------------

    ----begin

    /* 1. 將schema和object名稱轉換為小寫 */
    v_object_type := lower(v_object_type);
    v_schema_name := lower(v_schema_name);
    v_object_name := lower(v_object_name);
    --------------------------flag---------------------------
    IF v_FLAG = '00010' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '將schema和object名稱轉換為小寫';
    raise notice '00010: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00010', v_desc) into v_debug_me;
    --------------------------debug---------------------------

    /* 2. 建立資料庫物件清單 */ --@@20250807 因新增v_flow_direction調整邏輯
    --資料庫物件表(table/view/matview/function/trigger)
    DROP TABLE IF EXISTS tmp_object_list;
    CREATE TEMP TABLE tmp_object_list (
        object_type   varchar(2)    --物件類型
        ,schema_name   varchar(100)  --schema名稱
        ,object_name   varchar(100)  --object名稱
        ,object_key    varchar(100)  --schema.object名稱
    ) distributed by (object_type, object_key);
    --寫入資料庫物件
    insert into tmp_object_list
        --table/view/matview
        SELECT distinct case c.relkind when 'r' then 't' else c.relkind end as object_type
        ,lower(n.nspname) as schema_name
        ,lower(c.relname) as object_name
        ,lower(n.nspname||'.'||c.relname) as object_key
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r', 'v', 'm')
        and not exists (select 1 from pg_inherits where inhrelid = c.oid) --去除partition table
    union all
        --trigger
        select distinct 'f'
        ,lower(n.nspname) as schema_name
        ,lower(p.proname) as object_name
        ,lower(n.nspname||'.'||p.proname) as object_key
    from pg_proc p
    join pg_namespace n on p.pronamespace= n.oid
    union all
        --trigger
        select 'tg' as object_type
        ,n.nspname as schema_name
        ,tg.tgname as object_name
        ,lower(n.nspname||'.'||tg.tgname) as object_key
    from pg_trigger tg
    join pg_class c on tg.tgrelid = c.oid
    join pg_namespace n on c.relnamespace = n.oid;
    --去除debug table與function
    delete from tmp_object_list
    where object_key in ('db_owner.func_fname_sname_out','db_owner.func_gen_debug_me','db_owner.func_init_dateandtime_out'
        ,'db_owner.func_py_insert_debug','db_owner.debug_log_f','db_owner.debug_log_s','security_db.p_raise_error_i');

    /* 3. 檢查輸入物件是否存在於資料庫 */
    --table/view/matview
    IF lower(v_object_type) IN ('t', 'v', 'm', 'f', 'tg') THEN

        select exists
            (
            select 1
            from tmp_object_list
            where object_type = v_object_type
            and schema_name = v_schema_name
            and object_name = v_object_name
        ) into v_object_exists;

    ELSE
        --無效的類型則拋出錯誤訊息
        raise exception 'Unsupported object type: %', v_object_type;

    END IF ;

    --若物件不存在, 則拋出錯誤訊息並中止執行
    IF NOT v_object_exists THEN
        raise exception 'Object %.% does not exists.', v_schema_name, v_object_name;
    end if ;
    --------------------------flag---------------------------
    IF v_FLAG = '00020' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '檢查輸入物件是否存在於資料庫';
    raise notice '00020: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00020', v_desc) into v_debug_me;
    --------------------------debug---------------------------

    /* 4. 建立temp表 */
    --相依關係表(loop迴圈使用)
    DROP TABLE IF EXISTS tmp_dep_loop;
    CREATE TEMP TABLE tmp_dep_loop (
        object_type         char(3)             not null       --被依賴物件類型
        ,schema_name            varchar(100)        not null       --被依賴物件schema名稱
        ,object_name         varchar(100)        not null      --被依賴物件名稱
        ,object_key          varchar(100)        not null       --物件key
        ,dep_object_type     char(3)             not null      --依賴物件類型
        ,dep_schema_name        varchar(100)        not null       --依賴物件schema名稱
        ,dep_object_name     varchar(100)        not null      --依賴物件名稱
        ,dep_level           integer             not null      --依賴關係層級
        ,processed          boolean             default false  --查詢處理狀態
    ) distributed by(schema_name, object_name);

    --相依關係結果表
    DROP TABLE IF EXISTS tmp_dep_result;
    CREATE TEMP TABLE tmp_dep_result (
        ser_no              integer             not null       --排序序號
        ,dep_object_type     char(3)             not null       --依賴物件類型
        ,dep_schema_name     varchar(100)        not null       --依賴物件schema名稱
        ,dep_object_name     varchar(100)        not null       --依賴物件名稱
        ,dep_level           integer             not null       --依賴關係層級
        ,object_type         char(3)             not null      --被依賴物件類型
        ,schema_name            varchar(100)        not null       --被依賴物件schema名稱
        ,object_name         varchar(100)        not null       --被依賴物件名稱
        ,last_update_dttm    timestamp               null       --最近更新時間      --@@20250611 ADD
        ,object_owner        text                    null       --程式負責人      --@@20250611 ADD
        ,func               text                    null       --功能代號(以;分隔) --@@20250611 ADD
    ) distributed by(dep_schema_name, dep_object_name);

    --功能細節對應表 --@@20250611 新增暫存表
    DROP TABLE IF EXISTS tmp_dep_func_detail;
    CREATE TEMP TABLE tmp_dep_func_detail (
        ser_no              integer             not null       --排序序號
        ,dep_object_type     char(3)             not null       --依賴物件類型
        ,dep_schema_name     varchar(100)        not null       --依賴物件schema名稱
        ,dep_object_name     varchar(100)        not null       --依賴物件名稱
        ,dep_level           integer             not null       --依賴關係層級
        ,object_type         char(3)             not null     --被依賴物件類型
        ,schema_name           varchar(100)        not null       --被依賴物件schema名稱
        ,object_name         varchar(100)        not null       --被依賴物件名稱
        ,last_update_dttm    timestamp               null       --最近更新時間
        ,object_owner        text                    null       --程式負責人
        ,func                  text                    null       --功能代號(以;分隔)
        ,func_name           text                      null       --功能名稱(以;分隔)
        ,cnt                 text                    null       --使用次數(以;分隔)
        ,month_cnt           text                    null       --各月使用次數(以;分隔)
        ,func_info           text                    null       --功能細節(以;分隔)
        --@@20250702 新增執行時間欄位
        ,min_exec_time       interval                null       --最小執行時間
        ,avg_exec_time       interval                null       --平均執行時間
        ,max_exec_time       interval                null       --最大執行時間
    ) distributed by(dep_schema_name, dep_object_name);
    --------------------------flag---------------------------
    IF v_FLAG = '00030' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '建立暫存表';
    raise notice '00030: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00030', v_desc) into v_debug_me;
    --------------------------debug---------------------------

    /* 5. 依據 v_flow_direction(欲查詢物件上下游依賴關係) 執行迴圈, 處理每個未處理的物件 */
    --@@20250807 新增v_flow_direction、 增加選擇查詢物件上下游關係功能
    CASE v_flow_direction

        --===================== 查詢物件的上游關係 =====================--
        WHEN 1 THEN

            /* 6. 寫入初始物件, dep_level為0 */
            insert into tmp_dep_loop(object_type, schema_name, object_name, object_key, dep_object_type, dep_schema_name, dep_object_name, dep_level, processed)
                values(v_object_type, v_schema_name, v_object_name, v_schema_name||'.'||v_object_name, '', '', '', 0, false);
            --------------------------flag---------------------------
            IF v_FLAG = '00040' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '寫入初始物件, dep_level為0';
            raise notice '00040: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00040', v_desc) into v_debug_me;
            --------------------------debug---------------------------

            WHILE EXISTS (select 1 from tmp_dep_loop where not processed) LOOP
                --取得未處理紀錄中最小的dep_level, 作為目前正在處理的層級
                select coalesce(min(dep_level), 0)
                    into current_dep_level
                from tmp_dep_loop
                where not processed;
                --若目前的dep_level超過max_dep_level, 則跳出迴圈
                IF current_dep_level >= v_max_dep_level THEN
                    raise notice ' dep_level % reached max_dep_level %, exiting loop.', current_dep_level, v_max_dep_level;
                    EXIT;
                END IF;
                --------------------------flag---------------------------
                IF v_FLAG = '00050' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '迴圈開始:處理每個未處理的物件';
                raise notice '00050: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00050', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --取一個未處理的紀錄, 並記錄其dep_level
                select object_type, schema_name, object_name, dep_level, object_key into r
                from tmp_dep_loop
                where not processed
                order by dep_level
                    limit 1 ;
                --------------------------flag---------------------------
                IF v_FLAG = '00060' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '取一個未處理的紀錄, 並記錄其dep_level';
                raise notice '00060: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00060', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --標記物件為已處理
                update tmp_dep_loop
                set processed = true
                where object_key = r.object_key;

                raise notice 'Start Processing Level % : %.%', r.dep_level, r.schema_name, r.object_name;
                --------------------------flag---------------------------
                IF v_FLAG = '00070' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '標記物件為已處理';
                raise notice '00070: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00070', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --查詢依賴物件, 層級為當前紀錄的level+1
                insert into tmp_dep_loop
                    (object_type, schema_name, object_name, object_key, dep_object_type, dep_schema_name, dep_object_name, dep_level, processed)
                    select distinct
                    d.object_type as object_type
                    ,d.schema_name as schema_name
                    ,d.object_name as object_name
                    ,d.schema_name||'.'||d.object_name as object_key
                    ,dep_object_type as dep_object_type
                    ,dep_schema_name as dep_schema_name
                    ,dep_object_name as dep_object_name
                    ,r.dep_level + 1 as dep_level
                    ,false as processed
                from
                    (
                    -- 查詢view依賴關係(來源:DDL) --
                    select distinct o.object_type as object_type
                    ,o.schema_name as schema_name
                    ,o.object_name as object_name
                    ,r.object_type as dep_object_type  --v:view
                    ,r.schema_name as dep_schema_name  --view的schema名稱
                    ,r.object_name as dep_object_name  --view名稱
                    FROM tmp_object_list o
                    where exists
                    (
                        select 1 from pg_views v
                        where v.schemaname = r.schema_name
                        and v.viewname = r.object_name
                        and lower(v.definition) ~ ('\m' || o.object_key || '\M')
                    )
                    -- 查詢materialized view依賴關係(來源:DDL) --
                    union all
                    select distinct o.object_type as object_type
                    ,o.schema_name as schema_name
                    ,o.object_name as object_name
                    ,r.object_type as dep_object_type  --m:matview
                    ,r.schema_name as dep_schema_name  --matview的schema名稱
                    ,r.object_name as dep_object_name  --matview名稱
                    from tmp_object_list o
                    where exists
                    (
                        select 1 from pg_matviews m
                        where m.schemaname = r.schema_name
                        and m.matviewname = r.object_name
                        and lower(m.definition) ~ ('\m' || o.object_key || '\M'))
                    -- 查詢function依賴關係(來源:DDL) --
                    union all
                    select distinct o.object_type as object_type
                    ,o.schema_name as schema_name
                    ,o.object_name as object_name
                    ,r.object_type as dep_object_type  --f:function
                    ,r.schema_name as dep_schema_name  --function的schema名稱
                    ,r.object_name as dep_object_name  --function名稱
                    from tmp_object_list o
                    where exists
                    (
                        select 1 from pg_proc p
                        join pg_namespace n on p.pronamespace = n.oid
                        where n.nspname = r.schema_name
                        and p.proname = r.object_name
                        and lower(p.prosrc) ~ ('\m' || o.object_key || '\M')
                    )
                    -- 查詢trigger依賴關係(來源:系統表) --
                    --被依賴的function
                    union all
                    select distinct 'f' as object_type       --function
                    ,n.nspname as schema_name          --function的schema名稱
                    ,p.proname as object_name          --function名稱
                    ,r.object_type as dep_object_type  --trigger
                    ,r.schema_name as dep_schema_name  --trigger的schema名稱
                    ,r.object_name as dep_object_name  --trigger名稱
                    from pg_trigger tg
                    join pg_proc p on tg.tgfoid = p.oid
                    join pg_namespace n on p.pronamespace = n.oid
                    where n.nspname = r.schema_name
                    and tg.tgname = r.object_name
                    --被依賴的table
                    UNION ALL
                    select distinct case c.relkind when 'r' then 't' end as object_type --table
                    ,n.nspname as schema_name          --table的schema名稱
                    ,c.relname as object_name          --table名稱
                    ,r.object_type as dep_object_type  --trigger
                    ,r.schema_name as dep_schema_name  --trigger的schema名稱
                    ,r.object_name as dep_object_name  --trigger名稱
                    from pg_trigger tg
                    join pg_class c on tg.tgrelid = c.oid
                    join pg_namespace n on c.relnamespace = n.oid
                    where n.nspname = r.schema_name
                    and tg.tgname = r.object_name
                )  d
                where (d.dep_schema_name||'.'||d.dep_object_name) <> (d.schema_name||'.'||d.object_name); --不寫入與依賴物件同名的物件

                --完成目前物件的依賴關係查詢
                raise notice 'Finished Processing Level % : %.%', r.dep_level, r.schema_name, r.object_name;
                raise notice '-----------------------------------------------------------------------------';

            END LOOP;
            --------------------------flag---------------------------
            IF v_FLAG = '00080' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '完成目前物件的依賴關係查詢, 迴圈結束';
            raise notice '00080: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00080', v_desc) into v_debug_me;
            --------------------------debug---------------------------

            -- 7. 將結果寫入 tmp_dep_result --@@20250509 調整輸出表欄位順序 --@@20250611 新增output欄位內容security_db.deploy_source)
            insert into tmp_dep_result
                select row_number() over(order by dep_level, dep_object_type, dep_schema_name,
                dep_object_name, t1.object_type, t1.schema_name, t1.object_name) as ser_no --排序序號
                ,dep_object_type                                    --依賴物件類型
                ,dep_schema_name                                    --依賴物件schema名稱
                ,dep_object_name                                    --依賴物件名稱
                ,dep_level                                          --依賴關係層級
                ,t1.object_type                                     --被依賴物件類型
                ,t1.schema_name                                     --被依賴物件schema名稱
                ,t1.object_name                                     --被依賴物件名稱
                ,last_update_dttm                                   --最近更新時間
                ,nullif(trim(object_owner_sp), '') as object_owner  --程式負責人
                ,nullif(trim(object_owner_ui), '') as func          --功能代號
            from tmp_dep_loop t1
            left join security_db.deploy_source t2
            on t1.schema_name = lower(t2.object_schema)
                and t1.object_name = lower(t2.object_name)
            order by ser_no, dep_level,dep_object_type, dep_schema_name, dep_object_name, object_type, schema_name, object_name;
            --------------------------flag---------------------------
            IF v_FLAG = '00090' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '將結果寫入tmp_dep_result';
            raise notice '00090: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00090', v_desc) into v_debug_me;
            --------------------------debug---------------------------

            --===================== 查詢物件的下游關係 =====================--
        WHEN 2 THEN

            -- 4. 寫入初始物件, dep_level為0
            insert into tmp_dep_loop(dep_object_type, dep_schema_name, dep_object_name, object_key, object_type, schema_name, object_name, dep_level, processed)
                values(v_object_type, v_schema_name, v_object_name, v_schema_name||'.'||v_object_name, '', '', '', 0, false);
            --------------------------flag---------------------------
            IF v_FLAG = '00040' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '寫入初始物件, dep_level為0';
            raise notice '00040: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00040', v_desc) into v_debug_me;
            --------------------------debug---------------------------

            WHILE EXISTS (select 1 from tmp_dep_loop where not processed) LOOP
                --取得未處理紀錄中最小的dep_level, 作為目前正在處理的層級
                select coalesce(min(dep_level), 0)
                    into current_dep_level
                from tmp_dep_loop
                where not processed;
                --若目前的dep_level超過max_dep_level, 則跳出迴圈
                IF current_dep_level >= v_max_dep_level THEN
                    raise notice ' dep_level % reached max_dep_level %, exiting loop.', current_dep_level, v_max_dep_level;
                    EXIT;
                END IF;
                --------------------------flag---------------------------
                IF v_FLAG = '00050' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '迴圈開始:處理每個未處理的物件';
                raise notice '00050: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00050', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --取一個未處理的紀錄, 並記錄其dep_level
                select dep_object_type, dep_schema_name, dep_object_name, dep_level, object_key into r
                from tmp_dep_loop
                where not processed
                order by dep_level
                    limit 1 ;
                --------------------------flag---------------------------
                IF v_FLAG = '00060' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '取一個未處理的紀錄, 並記錄其dep_level';
                raise notice '00060: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00060', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --標記物件為已處理
                update tmp_dep_loop
                set processed = true
                where object_key = r.object_key;

                raise notice 'Start Processing Level % : %.%', r.dep_level, r.dep_schema_name, r.dep_object_name;
                --------------------------flag---------------------------
                IF v_FLAG = '00070' then return 'xxx'; end if;
                --------------------------flag---------------------------
                v_DESC := '標記物件為已處理';
                raise notice '00070: %', v_DESC;
                select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00070', v_desc) into v_debug_me;
                --------------------------debug---------------------------

                --查詢依賴物件, 層級為當前紀錄的level+1
                insert into tmp_dep_loop
                    (object_type, schema_name, object_name, object_key, dep_object_type, dep_schema_name, dep_object_name, dep_level, processed)
                    select distinct
                    d.object_type as object_type
                    ,d.schema_name as schema_name
                    ,d.object_name as object_name
                    ,d.dep_schema_name||'.'||d.dep_object_name as object_key
                    ,dep_object_type as dep_object_type
                    ,dep_schema_name as dep_schema_name
                    ,dep_object_name as dep_object_name
                    ,r.dep_level + 1 as dep_level
                    ,false as processed
                from
                    (
                    -- 查詢view的依賴關係(來源:DDL) --
                    SELECT DISTINCT 'v' as dep_object_type   --v:view
                    ,schemaname as dep_schema_name     --view的schema名稱
                    ,viewname as dep_object_name       --view名稱
                    ,r.dep_object_type as object_type
                    ,r.dep_schema_name as schema_name
                    ,r.dep_object_name as object_name
                    FROM pg_views v
                    WHERE lower(v.definition) ~ ('\m' || r.object_key || '\M')

                    -- 查詢materialized view依賴關係(來源:DDL) --
                    union all
                    select distinct 'm' as dep_object_type
                    ,m.schemaname as dep_schema_name
                    ,m.matviewname as dep_object_name
                    ,r.dep_object_type as object_type
                    ,r.dep_schema_name as schema_name
                    ,r.dep_object_name as object_name
                    from pg_matviews m
                    where lower(m.definition) ~ ('\m' || r.object_key || '\M')
                    -- 查詢function依賴關係(來源:DDL) --
                    union all
                    select distinct 'f' as dep_object_type
                    ,n.nspname as dep_schema_name
                    ,p.proname as dep_function_name
                    ,r.dep_object_type as object_type
                    ,r.dep_schema_name as schema_name
                    ,r.dep_object_name as object_name
                    from pg_proc p
                    join pg_namespace n on p.pronamespace = n.oid
                    where lower(p.prosrc) ~ ('\m' || r.object_key || '\M')
                    -- 查詢trigger依賴關係(來源:系統表) --
                    --被依賴的function
                    union all
                    select distinct 'tg' as dep_object_type  --trigger
                    ,n.nspname as dep_schema_name      --trigger的schema名稱
                    ,tg.tgname as dep_object_name      --trigger名稱
                    ,r.dep_object_type as object_type  --f:function
                    ,r.dep_schema_name as schema_name  --function的schema名稱
                    ,r.dep_object_name as object_name  --function名稱
                    from pg_trigger tg
                    join pg_proc p on tg.tgfoid = p.oid
                    join pg_namespace n on p.pronamespace = n.oid
                    where n.nspname = r.dep_schema_name
                    and p.proname = r.dep_object_name
                    --被依賴的table
                    UNION ALL
                    select distinct 'tg' as dep_object_type   --tg:trigger
                    ,n.nspname as dep_schema_name       --trigger的schema名稱
                    ,tg.tgname as dep_object_name       --trigger名稱
                    ,r.dep_object_type as object_type   --t:table
                    ,r.dep_schema_name as schema_name   --table的schema名稱
                    ,r.dep_object_name as object_name
                    from pg_trigger tg
                    join pg_class c on tg.tgrelid = c.oid
                    join pg_namespace n on c.relnamespace = n.oid
                    where n.nspname = r.dep_schema_name
                    and c.relname = r.dep_object_name
                ) d
                where (d.dep_schema_name||'.'||d.dep_object_name) <> (d.schema_name||'.'||d.object_name); --不寫入與依賴物件同名的物件

                --完成目前物件的依賴關係查詢
                raise notice 'Finished Processing Level % : %.%', r.dep_level, r.dep_schema_name, r.dep_object_name;
                raise notice '-----------------------------------------------------------------------------';

            END LOOP;
            --------------------------flag---------------------------
            IF v_FLAG = '00080' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '完成目前物件的依賴關係查詢, 迴圈結束';
            raise notice '00080: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00080', v_desc) into v_debug_me;
            --------------------------debug---------------------------

            -- 7. 將結果寫入 tmp_dep_result --@@20250509 調整輸出表欄位順序 --@@20250611 新增output欄位內容security_db.deploy_source)
            insert into tmp_dep_result
                select row_number() over(order by dep_level, dep_object_type, dep_schema_name,
                dep_object_name, t1.object_type, t1.schema_name, t1.object_name) as ser_no --排序序號
                ,dep_object_type                                    --依賴物件類型
                ,dep_schema_name                                    --依賴物件schema名稱
                ,dep_object_name                                    --依賴物件名稱
                ,dep_level                                          --依賴關係層級
                ,t1.object_type                                     --被依賴物件類型
                ,t1.schema_name                                     --被依賴物件schema名稱
                ,t1.object_name                                     --被依賴物件名稱
                ,last_update_dttm                                   --最近更新時間
                ,nullif(trim(object_owner_sp), '') as object_owner  --程式負責人
                ,nullif(trim(object_owner_ui), '') as func          --功能代號
            from tmp_dep_loop t1
            left join security_db.deploy_source t2
            on t1.dep_schema_name = lower(t2.object_schema)
                and t1.dep_object_name = lower(t2.object_name)
            order by ser_no, dep_level, object_type, schema_name, object_name, dep_object_type, dep_schema_name, dep_object_name;
            --------------------------flag---------------------------
            IF v_FLAG = '00090' then return 'xxx'; end if;
            --------------------------flag---------------------------
            v_DESC := '將結果寫入tmp_dep_result';
            raise notice '00090: %', v_DESC;
            select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00090', v_desc) into v_debug_me;
            --------------------------debug---------------------------
    END CASE;

    -- 8. 執行 apusr2.proc_gen_offline_report_usage, 查詢各物件功能 --@@20250611 新增
    perform apusr2.proc_gen_offline_report_usage(v_month);
    --------------------------flag---------------------------
    IF v_FLAG = '00100' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '執行apusr2.proc_gen_offline_report_usage, 查詢各物件功能';
    raise notice '00100: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00100', v_desc) into v_debug_me;
    --------------------------debug---------------------------

    -- 9. 找出各物件對應功能, 將結果寫入暫存表 --@@20250611 新增
    insert into tmp_dep_func_detail(ser_no,dep_object_type,dep_schema_name,dep_object_name,dep_level
        ,object_type,schema_name,object_name,last_update_dttm,object_owner,func,func_name,cnt
        ,month_cnt,func_info)
        select * from
        (
        select ser_no
        ,dep_object_type
        ,dep_schema_name
        ,dep_object_name
        ,dep_level
        ,object_type
        ,schema_name
        ,object_name
        ,last_update_dttm
        ,object_owner
        ,replace(d.func, ';', ';'||E'\n') as func
        ,string_agg(coalesce(t1.func_name, 'N/A'), ';' || E'\n' order by t1.func_name) as func_name --功能名稱list(以;分隔)
        ,string_agg(coalesce(t1.cnt::text, '0'), ';' || E'\n' order by f.func) as cnt               --使用次數list(以;分隔)
        ,string_agg(coalesce(t1.month_cnt, '0'), ';' || E'\n' order by f.func) as month_cnt         --各月使用次數list(以;分隔)
        ,string_agg(coalesce(f.func, '') || '(' || coalesce(t1.func_name, 'N/A') ||                 --功能細節(以;分隔)
            ', cnt=' || coalesce(t1.cnt::text, '0') ||
            ', month=' || coalesce(t1.month_cnt, '0') ||
            ')'
            ,';' || E'\n'
            order by f.func) as func_info
        from tmp_dep_result d
        left join lateral(select regexp_split_to_table(d.func, ';') as func) f on true
        left join t1 on t1.func_id = f.func
        group by d.ser_no, d.dep_object_type, d.dep_schema_name, d.dep_object_name, d.dep_level, d.object_type
        ,d.schema_name, d.object_name, d.last_update_dttm, d.object_owner, d.func) a;
    --------------------------flag---------------------------
    IF v_FLAG = '00110' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '找出各物件對應功能, 將結果寫入tmp_dep_func_detail';
    raise notice '00110: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00110', v_desc) into v_debug_me;
    --------------------------debug---------------------------

    /* 10. 計算function物件最小/平均/最大執行時間 */  --@@20250702 新增 --@@20250807 因新增v_flow_direction調整邏輯
    CASE v_flow_direction

        --v_flow_direction=1
        WHEN 1 THEN
            with func_exec_time as
                (
                select object_type
                ,schema_name
                ,object_name
                ,min(exec_time) as min_exec_time
                ,avg(exec_time) as avg_exec_time
                ,max(exec_time) as max_exec_time
                from
                (
                    select d.object_type
                    ,d.schema_name
                    ,d.object_name
                    ,l.debug_date
                    ,max(l.debug_w_time) - to_timestamp(l.debug_date||l.debug_start_time, 'YYYYMMDDHH24MISS.US') as exec_time --計算執行時間
                    from tmp_dep_func_detail d
                    join db_owner.debug_log_s l
                    on d.schema_name = l.debug_func_schema
                    and d.object_name = l.debug_func_name
                    where object_type = 'f' --過濾非function的物件
                    group by object_type, schema_name, object_name, debug_date, debug_start_time
                ) t
                group by object_type, schema_name, object_name
            )
                --更新目標表寫入最小/平均/最大執行時間
                update tmp_dep_func_detail d
            set min_exec_time = f.min_exec_time
                ,avg_exec_time = f.avg_exec_time
                ,max_exec_time = f.max_exec_time
            from func_exec_time f
            where d.object_type = 'f'
                and d.schema_name = f.schema_name
                and d.object_name = f.object_name;

            --v_flow_direction=2
        WHEN 2 THEN
            with func_exec_time as
                (
                select dep_object_type
                ,dep_schema_name
                ,dep_object_name
                ,min(exec_time) as min_exec_time
                ,avg(exec_time) as avg_exec_time
                ,max(exec_time) as max_exec_time
                from
                (
                    select d.dep_object_type
                    ,d.dep_schema_name
                    ,d.dep_object_name
                    ,l.debug_date
                    ,max(l.debug_w_time) - to_timestamp(l.debug_date||l.debug_start_time, 'YYYYMMDDHH24MISS.US') as exec_time --計算執行時間
                    from tmp_dep_func_detail d
                    join db_owner.debug_log_s l
                    on d.dep_schema_name = l.debug_func_schema
                    and d.dep_object_name = l.debug_func_name
                    where dep_object_type = 'f' --過濾非function的物件
                    group by dep_object_type, dep_schema_name, dep_object_name, debug_date, debug_start_time
                ) t
                group by dep_object_type, dep_schema_name, dep_object_name
            )
                --更新目標表寫入最小/平均/最大執行時間
                update tmp_dep_func_detail d
            set min_exec_time = f.min_exec_time
                ,avg_exec_time = f.avg_exec_time
                ,max_exec_time = f.max_exec_time
            from func_exec_time f
            where d.dep_object_type = 'f'
                and d.dep_schema_name = f.dep_schema_name
                and d.dep_object_name = f.dep_object_name;

    END CASE;
    --------------------------flag---------------------------
    IF v_FLAG = '00120' then return 'xxx'; end if;
    --------------------------flag---------------------------
    v_DESC := '計算function物件最小/平均/最大執行時間';
    raise notice '00120: %', v_DESC;
    select db_owner.func_gen_debug_me(v_debug_me, v_debug_date, v_debug_start_time, v_debug_func_schema, v_debug_func_name, '00120', v_desc) into v_debug_me;
    --------------------------debug---------------------------
    raise notice 'output table: 1)tmp_dep_result 2)tmp_dep_func_detail';

    perform db_owner.func_py_insert_debug('insert into db_owner.debug_log_s '|| v_debug_me ||')');
    RETURN 'S';

EXCEPTION WHEN OTHERS THEN
    perform db_owner.func_py_insert_debug('insert into db_owner.debug_log_f '|| v_debug_me ||')');
    GET STACKED DIAGNOSTICS v_t1 = MESSAGE_TEXT,v_t2 = PG_EXCEPTION_DETAIL, v_t3 = PG_EXCEPTION_CONTEXT;
    v_t1 := v_t1 || '  ' || v_t2 || '  ' || v_t3;
    raise exception '%', v_t1;

end LMAIN;

$function$
EXECUTE ON ANY;
