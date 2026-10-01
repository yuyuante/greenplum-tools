# `_FLX` 測試資料製作與還原

執行環境：在本目錄執行 `python flx_testdata.py`，需安裝 `psycopg2`。資料庫連線別名取自 `C:\Users\peteryu\code\env\<別名>.txt`；密碼不寫入執行紀錄。

## 參數與指令

- `--start`、`--end`：**來源資料**的起迄日期，含首尾兩日，格式 `YYYY-MM-DD`。
- `--source`、`--destination`：來源與目的資料庫連線別名，預設 `GPstage`、`GP178`。
- `--years`：所有可判定的日期及日期時間欄位平移年數，預設 `2`。時間欄位若只存當日時間，不平移。
- `--table schema.table`：僅處理指定表，可重複提供。省略時檢查兩端共同的所有 `_flx` 表。
- `--manifest`：`apply` 產生的執行紀錄，用於 `verify`、`restore`。

```powershell
python flx_testdata.py plan --start 2024-06-16 --end 2024-07-19 --source GPstage --destination GP178 --years 2
python flx_testdata.py apply --start 2024-06-16 --end 2024-07-19 --source GPstage --destination GP178 --years 2
python flx_testdata.py verify --manifest flx_runs/20261001_105501_b0ec17.json --destination GP178
```

本例目的日期為 2026-06-16 至 2026-07-19。`plan` 只檢查資料與顯示數量；`apply` 在每張表匯入前，先將目的日期區間的原資料備份到 `db_owner_temp.flxb_*`。匯入完成後會保留備份。目的資料相同日期區間已有資料時會以來源資料取代。執行紀錄存於 `flx_runs`，內含各表數量、備份表及資料指紋；不可刪除，否則難以還原。相同目的資料庫內有尚未還原的重疊日期執行時，程式會拒絕再次匯入。

測試結束後，以執行紀錄還原目的端原資料：

```powershell
python flx_testdata.py restore --manifest flx_runs/20261001_105501_b0ec17.json --destination GP178
```

若測試過程改動了匯入區間的資料，還原指令會因資料指紋不同而停止。確認可捨棄這些測試後變更時，加上 `--allow-changes` 再執行。還原按表提交；途中停止時，重新執行會從執行紀錄中尚未還原的表繼續。備份表會繼續保留，供後續稽核或人工清理。對 `backup_only` 的表，還原也會套用原備份。

## 本次執行狀態

- 執行紀錄：`flx_runs/20261001_105501_b0ec17.json`，狀態 `applied`，待測試後還原。
- 選出 163 張來源與目的欄位一致、日期基準可判定的表；實際有資料的 31 張表已處理。來源匯入 2,043,971 筆；目的端原資料備份 71,935 筆。
- 35 張表略過：日期基準欄位不明確 20 張、沒有可判讀的日期欄位 8 張、目的端不存在 7 張。完整清單見執行紀錄的 `skipped`。
- `db_owner.svel_2side_flx`、`db_owner.m_oab_flx`、`db_owner.m_fab_flx` 在來源資料庫沒有資料。本批資料因此**無法直接用來驗證 C7-142 客製化商品成交配對與損益**，該案例需另製成交資料。

## 使用限制

工具只處理兩端表結構完全相同、且能選出單一日期基準欄位的 `_flx` 表；欄位不明確時會略過，避免搬錯資料。字元型日期欄位僅辨識 8 碼 `YYYYMMDD` 或 10 碼 `YYYY-MM-DD`，不合法值保留原值。日曆平移遇到 2 月 29 日而目的年沒有該日時，改為 2 月 28 日。

執行期間請避免其他工作同時修改目的日期區間。程式使用資料庫鎖阻止另一個相同工具同時執行，但無法阻止其他 SQL 工作；`verify` 與還原時的資料指紋檢查用於發現這類變動。
