# Greenplum Tools

Greenplum 資料庫相關工具集，每項工具各自放在獨立子目錄，使用方式請見各子目錄的 `README.md`。

## 工具清單

| 子目錄 | 說明 |
|--------|------|
| [`distribution-key-detector`](distribution-key-detector/) | 偵測 Greenplum 資料表最佳分佈鍵（Distribution Key）的函式 `public.gp_detect_distribution_key` |
| [`flx-testdata`](flx-testdata/) | 將來源 Greenplum 的 `_flx` 表資料平移日期後匯入測試環境，並可依執行紀錄還原 |
