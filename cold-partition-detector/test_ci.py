#!/usr/bin/env python3
"""
CI Regression & Static Analysis Test Suite
嚴格驗證全 PR 異動檔案之去識別化（0 PII）、負數門檻防呆與暫存表隔離規範
"""
import os
import re
import subprocess
import sys
from pathlib import Path

def get_target_files():
    """取得本次 PR 或 Commit 異動之所有檔案（支援 PR 分支比對與 main 分支合併後之 push 檢驗）"""
    root_dir = Path(__file__).resolve().parent.parent
    try:
        # 1. 優先比對 feature 分支與 main 基準: origin/main...HEAD
        result = subprocess.run(
            ["git", "-C", str(root_dir), "diff", "--name-only", "origin/main...HEAD"],
            capture_output=True,
            text=True,
            check=True
        )
        file_paths = [root_dir / f.strip() for f in result.stdout.splitlines() if f.strip()]

        # 2. 若為空（例如在 main 分支上的 push 事件），改為比對前一提交: HEAD~1...HEAD
        if not file_paths:
            result = subprocess.run(
                ["git", "-C", str(root_dir), "diff", "--name-only", "HEAD~1...HEAD"],
                capture_output=True,
                text=True,
                check=True
            )
            file_paths = [root_dir / f.strip() for f in result.stdout.splitlines() if f.strip()]
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"❌ 無法自 git diff 取得異動清單: {e.stderr}") from e

    if not file_paths:
        raise RuntimeError("❌ git diff 比對結果為 0 個檔案，無法判定異動範圍！")

    # 嚴格驗證異動清單中所有檔案均存在，杜絕任何漏掃與略過
    for f in file_paths:
        if not f.is_file():
            raise RuntimeError(f"❌ 異動檔案不存在或非一般檔案: {f}")

    return file_paths

def test_no_pii_and_local_paths():
    """驗證全異動檔案中無真實電子郵件、本機目錄路徑、內部專有網址或私有 IP"""
    print("==> 執行異動檔案之去識別化與機敏資訊完整掃描...")
    target_files = get_target_files()

    # 1. 嚴格模式檢測規則（不含任何特定機構或人員名稱，通用於所有公共儲存庫）
    patterns = [
        (re.compile(r'[a-zA-Z0-9_.+-]+@(?!users\.noreply\.github\.com)[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+'), "真實個人/內部 Email"),
        (re.compile(r'[a-zA-Z]:\\[Uu]sers\\[a-zA-Z0-9_.]+'), "Windows 本機個人路徑"),
        (re.compile(r'/(?:home|Users)/[a-zA-Z0-9_.]+'), "Unix/Mac 本機個人路徑"),
        (re.compile(r'https?://(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})'), "內部私有 IP 網址"),
        (re.compile(r'https?://[a-zA-Z0-9-]+\.(?:internal|corp|local|intra|domain)\b', re.IGNORECASE), "內部機構專用網址"),
    ]

    # 2. 支援環境變數自訂機敏黑名單（動態傳入，避免在程式庫中明文硬編碼特定名稱）
    extra_keywords = [k.strip() for k in os.environ.get("PII_DENY_KEYWORDS", "").split(",") if k.strip()]

    failed = False
    for path in target_files:
        try:
            content = path.read_text(encoding="utf-8", errors="strict")
        except UnicodeDecodeError:
            # 若含有非標準 UTF-8 字元，仍以 raw latin1 解碼檢查，絕不靜默略過任何檔案
            content = path.read_bytes().decode("latin1", errors="ignore")
        except Exception as e:
            raise RuntimeError(f"❌ 無法讀取異動檔案: {path} - {e}") from e

        for line_no, line in enumerate(content.splitlines(), start=1):
            for pat, desc in patterns:
                if pat.search(line):
                    print(f"❌ 發現 {desc}: {path.name}:{line_no} -> {line.strip()}")
                    failed = True
            for kw in extra_keywords:
                if kw.lower() in line.lower():
                    print(f"❌ 發現特定機敏關鍵字 '{kw}': {path.name}:{line_no}")
                    failed = True

    if failed:
        sys.exit(1)
    print(f"✅ 全異動檔案去識別化檢驗通過: 共掃描 {len(target_files)} 個異動檔案（無任何檔案被排除或略過），0 敏感資訊洩漏")

def test_negative_threshold_guard():
    """驗證正式版與輕量版均具備負數門檻防呆與主動拋錯"""
    print("==> 驗證負數門檻 (p_max_reads < 0) 防呆邏輯...")
    detector_dir = Path(__file__).resolve().parent
    formal_file = detector_dir / "db_owner.fun_proc_chk_cold_partitions.sql"
    lite_file = detector_dir / "db_owner.fun_get_cold_partitions.sql"

    for f in [formal_file, lite_file]:
        content = f.read_text(encoding="utf-8")
        assert "p_max_reads < 0" in content, f"❌ {f.name} 未包含負數門檻判斷"
        assert "不得為負數" in content, f"❌ {f.name} 未包含負數拋錯訊息"
        assert "COALESCE(p_max_reads, 0)" in content, f"❌ {f.name} 未包含 NULL 容錯"
        print(f"✅ {f.name}: 負數門檻防呆與主動拋錯機制確認具備")

def test_pg_temp_qualification():
    """驗證暫存表操作均限定 pg_temp"""
    print("==> 驗證暫存表限定 pg_temp...")
    formal_file = Path(__file__).resolve().parent / "db_owner.fun_proc_chk_cold_partitions.sql"
    test_sql_file = Path(__file__).resolve().parent / "test_cold_partition_detector.sql"

    for f in [formal_file, test_sql_file]:
        content = f.read_text(encoding="utf-8")
        assert "CREATE TEMP TABLE pg_temp." in content, f"❌ {f.name} 未限定 CREATE TEMP TABLE pg_temp."
        assert "DROP TABLE IF EXISTS pg_temp." in content, f"❌ {f.name} 未限定 DROP TABLE IF EXISTS pg_temp."
    print("✅ 暫存表 pg_temp 限定確認無誤")

if __name__ == "__main__":
    test_no_pii_and_local_paths()
    test_negative_threshold_guard()
    test_pg_temp_qualification()
    print("==================================================")
    print("✅ 全部靜態分析與回歸檢驗通過 (All checks passed)!")
    print("==================================================")
