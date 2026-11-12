# PR #3 補測與審查紀錄（2026-10-21）

範圍：已合併的 `22cf737`、`61d678b`；GP178 `svelgp` 已部署的 `db_owner.proc_gen_dep`；FLX 目前批次 `20261020_171505_2a6c24`。本紀錄只包含本次實際執行的測試與人工靜態審查。

## 已執行

| 測試 | 結果 | 證據／限制 |
|---|---|---|
| `RUN_GP178_TESTS=1 python -m unittest discover -s tests -p test_pr3.py -v` | 9/9 PASS | GP178 以交易執行，每個案例後 rollback；涵蓋既有函式的種子結果、錯誤類型、不存在物件、早期停止，以及倉庫 SQL 在同名永久表存在時的暫存表 DROP 防護。另含產品編號日期與世紀邊界的 Python 單元案例。 |
| `python -m py_compile flx-testdata/flx_testdata.py` | PASS | 語法檢查。 |
| `python flx-testdata/flx_testdata.py --help` | PASS | CLI 可載入。 |
| `python flx_testdata.py verify --manifest flx_runs/20261020_171505_2a6c24.json --destination GP178` | PASS | `VERIFIED tables=2 imported_rows=712 backed_up_rows=0`。唯讀驗證，沒有重跑 apply/restore。 |

前四個函式行為案例測的是 GP178 已部署版本；同名永久表防護案例會在交易內將倉庫 SQL 部署到獨立 schema。`pg_proc.prosrc` 與倉庫 SQL 本體並非逐位元相同，既有版本的行為結果不能證明倉庫檔案部署後的行為。交易 rollback 是否能涵蓋輔助函式的全部副作用尚待查證。尚未覆蓋精確相依邊、表、檢視、物化檢視、觸發器分支、並行、大量資料與權限情境；這不是專案規範定義的完整 TestSuite。

## 人工審查發現

1. **同名永久表防護已部分修正。** `object-dependency-finder/DB_OWNER.fun_proc_gen_dep.sql` 的四個 DROP 已限定 `pg_temp`；交易內部署倉庫 SQL 的回歸案例確認同名永久表仍存在。但測試目前未核對永久表內容，而且其餘未限定 schema 的讀寫操作仍可能受 `search_path` 順序影響，須進一步修正與驗證。
2. **測試覆蓋不足：** 現有回歸案例只測物件類型 `f`，且以筆數及層級為主，未核對完整相依關係內容。需要用固定夾具覆蓋 `t/v/m/tg`、循環依賴、月份過濾及不同方向的實際依賴邊；另測錯誤後暫存表狀態、並行與效能門檻。
3. **產品編號匯入端尚缺端到端測試：** `product_id_expected` 的單元案例與目前批次 `verify` 已過，但本次沒有重建一筆含有效、空白、無效產品編號的來源夾具並走完 `apply → verify → restore`。因此對新批次的完整恢復路徑不作保證；目前已套用的 712 筆批次也未改動。

## 正式審查狀態

專案規範要求完整 TestSuite 全數通過後才進入正式三方 code review。本次仍缺上述完整覆蓋。使用者已授權送審，Claude 已完成唯讀的**測試清單審查**，結果記錄在工作區 `pr3_test_plan_claude.md`；指出測試目標版本、精確結果斷言、FLX SQL 實際運算式及暫存表解析等缺口。這不是正式的 Claude、Antigravity、Codex 三方 code review；本次尚未進入提交／推送流程。

業務字典不適用：本次只對工具補測與審查，未更動業務輸出欄位、定義、計算口徑、篩選規則或實體來源。
