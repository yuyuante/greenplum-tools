# Greenplum Tools

Greenplum 資料庫相關工具集，每項工具各自放在獨立子目錄，使用方式請見各子目錄的 `README.md`。

## 工具清單

| 子目錄 | 說明 |
|--------|------|
| [`cold-partition-detector`](cold-partition-detector/) | 檢核 Greenplum 全叢集「零讀取／冷分區」與冷資料表的偵測函式 |
| [`distribution-key-detector`](distribution-key-detector/) | 偵測 Greenplum 資料表最佳分佈鍵（Distribution Key）的函式 `public.gp_detect_distribution_key` |
| [`flx-testdata`](flx-testdata/) | 將來源 Greenplum 的 `_flx` 表資料平移日期後匯入測試環境，並可依執行紀錄還原 |
| [`object-dependency-finder`](object-dependency-finder/) | 資料庫物件相依關係查找函式 |

## 開發與審查規範

本專案定義嚴格之程式品質、資安防護與審查紀律，詳細規範請參閱 [`CLAUDE.md`](CLAUDE.md)：

1. **AI 交叉獨立審查**：
   - 專案所有程式產出（SP/Function、Python 工具、SQL 腳本或重要文件）**禁止由單一 AI 開發 Session 自行判定結案**。
   - **必須送交其他合適的 AI 開發工具（優先採跨工具、跨模型家族，或全新獨立審查 Session）進行獨立審查**，排除脈絡盲點。
2. **嚴格去識別化與隱私防護**：
   - 全專案檔案**切勿提及任何特定公司機構名稱、人員姓名、部門稱謂或個人資料（PII）**。
   - 檔案路徑一律採用相對路徑或環境變數表示，禁止包含本機使用者名稱之絕對路徑。
3. **平台與版本相容性**：
   - 嚴格遵守 Greenplum 6.x（PostgreSQL 9.4.26）版本約束與 MPP 分散式架構特性。

