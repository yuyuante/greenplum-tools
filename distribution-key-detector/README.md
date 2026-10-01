# Greenplum 最佳分佈鍵偵測工具 (Distribution Key Detector)

本目錄存放了用於偵測 Greenplum 資料表最佳分佈鍵（Distribution Key）的預儲程序（PL/pgSQL 資料庫函數）。

---

## 1. 檔案清單

*   **`detect_distribution_key.sql`**：Greenplum 偵測函數 `public.gp_detect_distribution_key` 的安裝 SQL 腳本。

---

## 2. 安裝方式

請使用 `psql` 命令列、DBeaver、pgAdmin 或您的資料庫用戶端工具，執行 `detect_distribution_key.sql` 中的全部內容。這會在 `public` schema 下建立一個同名函數。

---

## 3. 使用方法

### 步驟 1：更新統計資訊 (重要)
為了確保評估基準為最新且最精準的，**執行檢測前請先對目標表進行 `ANALYZE`**：
```sql
ANALYZE my_schema.my_large_table;
```

### 步驟 2：執行偵測函數
呼叫函數並傳入目標資料表的 **Schema 名稱** 與 **資料表名稱**：
```sql
SELECT * FROM public.gp_detect_distribution_key('my_schema', 'my_large_table');
```

---

## 4. 欄位說明與評估指標

函數回傳的結果表包含以下欄位：

*   **`column_name`**：欄位名稱。第一行固定為 `== CURRENT_TABLE_STATUS ==`，用以顯示該表目前的分佈策略與傾斜係數。
*   **`data_type`**：欄位資料型態。
*   **`n_distinct`**：估計的唯一值基數（來自 `pg_stats`）。
    *   若為正數：估計唯一值數量。
    *   若為負數（如 -1, -0.5）：唯一值佔總列數的比例（-1 代表 100% 唯一，-0.5 代表 50% 唯一）。
*   **`null_fraction`**：空值比例（0 ~ 1 之間），越接近 0 越好。空值大於 80% 的欄位將被判定為不推薦。
*   **`max_value_freq`**：該欄位中最常出現之單一重複值佔總筆數的比例（Heavy Hitter 佔比），越接近 0 越好。
*   **`recommendation_score`**：推薦分數（0 ~ 100 分），分數越高適配度越高。
*   **`suitability_rating`**：適配等級。包含：
    *   `STRONGLY_RECOMMENDED` (強烈推薦，分數 >= 85)
    *   `RECOMMENDED` (推薦，分數 >= 70)
    *   `ACCEPTABLE` (普通，分數 >= 50)
    *   `POOR` (不推薦)
*   **`analysis_detail`**：該欄位的具體統計分析與警告資訊。

---

## 5. 解讀與優化建議

1.  **優先挑選唯一值多、空值率低（最好為 0%）、且無高頻重複值的欄位**。
2.  **大表（Fact Table）**：
    *   選擇分數在 85 分以上的欄位。
    *   如果有複數個高分欄位，**優先選擇經常與其他大表進行 `JOIN` 條件關聯的欄位**。這能實現 **Co-located Join**，將查詢時跨 segment 重新分佈資料的網路開銷 (Motion) 降至最低。
3.  **小表（Dimension Table，如少於 10 萬列）**：
    *   建議直接採用 `DISTRIBUTED REPLICATED`（複製分佈），使每個 segment 都保有一份完整拷貝。
4.  **嚴重傾斜處理**：
    *   若沒有任何單一欄位分數合格，請考慮使用**複合分佈鍵**（以多欄位聯合分佈，例如 `DISTRIBUTED BY (col1, col2)`）來打破重複值傾斜。
