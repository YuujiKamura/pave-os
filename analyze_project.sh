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
# 日本の公共土木工事プロジェクトの分析

以下はフォルダ構成サマリです。出力はJSONのみ（説明文不要）。

## ドメイン知識（重要）

日本の公共工事には明確なマイルストーンがある:
- **入札日**: 競争入札に参加した日
- **契約日**: 発注者と契約を締結した日
- **着工日**: 現場作業を開始した日（着工届の日付が根拠）
- **竣工日**: 工事完了・引渡しの日（竣工届の日付が根拠）
- **工期**: 契約上の着工日〜竣工日。これが「この工事の期間」

ファイル日付の注意:
- 建設業許可証（2018年等）、保険証書、過去の参考資料は**工事より何年も前の日付**を持つ。これらは他案件からの持ち回り書類であり、工期の判定に使ってはならない
- **着工時フォルダ**のファイル集中日付 = 着工日の推定根拠
- **変更契約・竣工フォルダ**のファイル集中日付 = 竣工日の推定根拠
- **契約時フォルダ**の契約書日付 = 契約日の推定根拠

フォルダ番号は時系列ではなく「中身を置く用事ができた順」に作られる。

## フェーズの実態

公共舗装工事では以下が**並列**で走る:
1. 着手準備（契約直後）: 契約処理、道路使用許可（警察待ち）、施工計画書、材料確認、施工体制、設計照査 → 第1回打合せ
2. 施工準備: 地下埋設確認、安全書類、下請確定
3. 施工本番: 切削→舗装→区画線。写真・出来形・品質管理・温度管理・週報が毎日
4. 竣工処理: 実施数量、検査評定、創意工夫、変更契約

## 出力JSON構造

{
  "project_name": "工事名",
  "work_type": "工種（舗装補修/舗装打換/区画線等）",
  "milestones": {
    "bid_date": "YYYY-MM-DD（入札日、推定）",
    "contract_date": "YYYY-MM-DD（契約日、推定）",
    "start_date": "YYYY-MM-DD（着工日、推定）",
    "end_date": "YYYY-MM-DD（竣工日、推定）",
    "duration_days": 0
  },
  "subcontractors": ["下請業者名"],
  "folders": [
    { "name": "フォルダ名", "file_count": 0, "activity_period": "YYYY-MM-DD~YYYY-MM-DD", "summary": "内容" }
  ],
  "phases": [
    {
      "name": "フェーズ名",
      "period": "YYYY-MM-DD~YYYY-MM-DD",
      "parallel_tasks": ["同時に走る作業"],
      "folders_involved": ["関連フォルダ名"],
      "description": "説明"
    }
  ],
  "deliverables": { "photos": 0, "pdfs": 0, "spreadsheets": 0, "cad_files": 0, "total": 0 },
  "insights": ["この工事固有の知見3-5個。一般論は不要"]
}

activity_period注意: 持ち回り書類（許可証等）の古い日付は除外し、この工事で実際に作業が発生した期間のみ記載せよ。

---
HEADER

# awkでフォルダごとのサマリを生成
awk -F'/' '
{
  split($1, a, " ")
  ts = a[1]
  size = a[2]
  # 第1レベルフォルダを取得（相対パスから）
  relpath = $0
  sub(/^[0-9.]+ [0-9]+ /, "", relpath)
  if (relpath ~ /\//) {
    n = split(relpath, parts, "/")
    folder = parts[1]
  } else {
    folder = "(root)"
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
