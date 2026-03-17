#!/bin/bash
# PaveOS: 完成工事フォルダをGeminiに食わせてナレッジ化する
# Usage: ./analyze_project.sh "H:/マイドライブ/〇市道 南千反畑町第１号線舗装補修工事"

set -euo pipefail

PROJECT_DIR="${1:?Usage: $0 <project_folder_path>}"
OUTPUT_DIR="${2:-$(dirname "$0")/output}"
MODEL="${PAVEOS_MODEL:-gemini-2.5-flash}"

mkdir -p "$OUTPUT_DIR"

PROJECT_NAME=$(basename "$PROJECT_DIR")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="$OUTPUT_DIR/${TIMESTAMP}_${PROJECT_NAME}.json"

echo "=== PaveOS Analyzer ==="
echo "Project: $PROJECT_NAME"
echo "Model: $MODEL"
echo ""

# Step 1: 全ファイル一覧を1回のfindで取得
echo "[1/3] Scanning all files (single pass)..."
RAW_FILE=$(mktemp)
find "$PROJECT_DIR" -type f \
  -not -path '*/.git/*' -not -path '*/.specstory/*' -not -path '*/.claude/*' \
  -printf '%T@ %s %P\n' 2>/dev/null > "$RAW_FILE"

TOTAL=$(wc -l < "$RAW_FILE")
echo "  Found $TOTAL files"

# Step 2: フォルダごとに集計（awk一発）
echo "[2/3] Building folder summary..."
CONTEXT_FILE=$(mktemp)

cat > "$CONTEXT_FILE" << 'HEADER'
以下は完成した日本の舗装補修工事プロジェクトのフォルダ構成サマリです。

このデータからJSON構造を生成してください。出力はJSONのみ（説明文不要）:
{
  "project_name": "工事名",
  "work_type": "工種",
  "period": { "start": "YYYY-MM", "end": "YYYY-MM" },
  "subcontractors": ["下請業者名（フォルダ名やファイル名から推定）"],
  "folders": [
    { "name": "フォルダ名", "file_count": 0, "date_range": "YYYY-MM-DD~YYYY-MM-DD", "summary": "内容" }
  ],
  "phases": [
    { "name": "フェーズ名", "period": "YYYY-MM~YYYY-MM", "parallel_tasks": ["同時作業"], "description": "説明" }
  ],
  "deliverables": { "photos": 0, "pdfs": 0, "spreadsheets": 0, "cad_files": 0, "total": 0 },
  "insights": ["知見3-5個"]
}

注意: フォルダ番号≠時系列。日付から実際の作業順序を推定せよ。並列作業を特定せよ。

---
HEADER

# awkでフォルダごとのサマリを生成
awk -F'/' '
{
  split($1, a, " ")
  ts = a[1]
  size = a[2]
  # 第1レベルフォルダを取得
  folder = $1
  sub(/^[0-9.]+ [0-9]+ /, "", folder)
  if (folder ~ /\//) {
    n = split(folder, parts, "/")
    folder = parts[1]
  }

  # フォルダごとに集計
  count[folder]++
  total_size[folder] += size
  if (!(folder in min_ts) || ts < min_ts[folder]) min_ts[folder] = ts
  if (!(folder in max_ts) || ts > max_ts[folder]) max_ts[folder] = ts

  # 拡張子集計
  fname = $NF
  if (match(fname, /\.[^.]+$/)) {
    ext = substr(fname, RSTART)
    ext_count[folder " " ext]++
  }

  # 代表ファイル名（最初の3つだけ）
  if (count[folder] <= 3) {
    if (samples[folder] != "") samples[folder] = samples[folder] ", "
    samples[folder] = samples[folder] fname
  }
}
END {
  for (f in count) {
    # タイムスタンプをYYYY-MM-DDに変換
    min_date = strftime("%Y-%m-%d", min_ts[f])
    max_date = strftime("%Y-%m-%d", max_ts[f])

    printf "### %s\n", f
    printf "ファイル数: %d | サイズ: %dKB | 期間: %s ~ %s\n", count[f], total_size[f]/1024, min_date, max_date
    printf "代表: %s\n\n", samples[f]
  }
}
' "$RAW_FILE" >> "$CONTEXT_FILE"

CONTEXT_SIZE=$(wc -c < "$CONTEXT_FILE")
echo "  Context: $((CONTEXT_SIZE / 1024))KB"

# Step 3: Geminiに投げる
echo "[3/3] Sending to Gemini ($MODEL)..."
RESULT=$(cat "$CONTEXT_FILE" | gemini -m "$MODEL" -o text 2>&1) || true

if [ -z "$RESULT" ]; then
  echo "ERROR: Gemini returned empty response"
  echo "Context saved: $CONTEXT_FILE"
  rm -f "$RAW_FILE"
  exit 1
fi

# JSONだけ抽出
JSON=$(echo "$RESULT" | sed -n '/```json/,/```/{ /```/d; p; }')
if [ -z "$JSON" ]; then
  JSON=$(echo "$RESULT" | perl -0777 -ne 'print $1 if /(\{.*\})/s')
fi
if [ -z "$JSON" ]; then
  JSON="$RESULT"
fi

echo "$JSON" > "$OUTPUT_FILE"

echo ""
echo "=== Done ==="
echo "Output: $OUTPUT_FILE"

rm -f "$RAW_FILE" "$CONTEXT_FILE"
