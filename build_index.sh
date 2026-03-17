#!/bin/bash
# PaveOS: ファイルインデックスDB生成
# 全ファイルのメタデータ + ファイル名ベースのラベル推定
# Usage: ./build_index.sh "H:/マイドライブ/〇〇工事"

set -euo pipefail

PROJECT_DIR="${1:?Usage: $0 <project_folder_path>}"
OUTPUT_DIR="${2:-$(dirname "$0")/index}"
MODEL="${PAVEOS_MODEL:-gemini-2.5-flash}"

mkdir -p "$OUTPUT_DIR"

PROJECT_NAME=$(basename "$PROJECT_DIR")
INDEX_FILE="$OUTPUT_DIR/${PROJECT_NAME}.jsonl"

echo "=== PaveOS Index Builder ==="
echo "Project: $PROJECT_NAME"
echo ""

# Step 1: 全ファイルメタデータ取得
echo "[1/3] Scanning files..."
RAW_FILE=$(mktemp)
find "$PROJECT_DIR" -type f \
  -not -path '*/.git/*' -not -path '*/.specstory/*' -not -path '*/.claude/*' \
  -not -name '*.JPG' -not -name '*.jpg' -not -name '*.jpeg' -not -name '*.png' \
  -printf '%T@ %s %P\n' 2>/dev/null | sort > "$RAW_FILE"

TOTAL=$(wc -l < "$RAW_FILE")
echo "  Found $TOTAL non-image files"

# Step 2: ファイル名からラベルを推定（ルールベース、AIなし）
echo "[2/3] Labeling by filename patterns..."
awk '
{
  ts = $1; size = $2
  $1 = ""; $2 = ""
  path = substr($0, 3)
  fname = path
  gsub(/.*\//, "", fname)

  # 拡張子
  ext = ""
  if (match(fname, /\.[^.]+$/)) ext = substr(fname, RSTART+1)
  ext_lower = tolower(ext)

  # ラベル推定（ファイル名パターン）
  label = "unknown"
  importance = "low"

  # 設計図書（入札時の最重要資料）
  if (fname ~ /工事設計書/) { label = "design_document"; importance = "critical" }
  else if (fname ~ /特記仕様書/) { label = "special_spec"; importance = "critical" }
  else if (fname ~ /共通仕様書/) { label = "common_spec"; importance = "high" }
  else if (fname ~ /施工条件明示/) { label = "conditions_list"; importance = "high" }
  else if (fname ~ /公告文/) { label = "public_notice"; importance = "medium" }
  # サフィックス規則（発注者のファイル命名慣行: k=金額, s=仕様, z=図面, h=福利費）
  else if (fname ~ /k[0-9]+\.(pdf|xlsx?)$/) { label = "cost_document"; importance = "high" }
  else if (fname ~ /s[0-9]+\.(pdf|docx?)$/) { label = "spec_document"; importance = "high" }
  else if (fname ~ /z[0-9]+\.(pdf)$/) { label = "plan_drawing"; importance = "high" }
  else if (fname ~ /h[0-9]+\.(pdf)$/) { label = "welfare_cost"; importance = "medium" }

  # 契約・入札
  else if (fname ~ /契約|keiyaku/) { label = "contract"; importance = "high" }
  else if (fname ~ /入札/) { label = "bid"; importance = "medium" }
  else if (fname ~ /落札/) { label = "bid_result"; importance = "high" }

  # 着工・竣工
  else if (fname ~ /着工届/) { label = "start_notice"; importance = "critical" }
  else if (fname ~ /竣工届|引き渡し|引渡/) { label = "completion_notice"; importance = "critical" }
  else if (fname ~ /変更契約/) { label = "contract_change"; importance = "high" }

  # 工程・週報
  else if (fname ~ /工程表|koutei/) { label = "schedule"; importance = "high" }
  else if (fname ~ /週報/) { label = "weekly_report"; importance = "medium" }
  else if (fname ~ /打ち合わせ|打合せ/) { label = "meeting_record"; importance = "medium" }

  # 施工計画
  else if (fname ~ /施工計画/) { label = "construction_plan"; importance = "high" }
  else if (fname ~ /仕様書/) { label = "specification"; importance = "high" }

  # 設計・図面
  else if (ext_lower ~ /^(dxf|dwg|jww)$/) { label = "cad_drawing"; importance = "medium" }
  else if (fname ~ /平面図|横断図|縦断図|展開図/) { label = "drawing"; importance = "medium" }

  # 地下埋設
  else if (fname ~ /地下埋設|埋設物/) { label = "buried_utility"; importance = "medium" }
  else if (fname ~ /立会/) { label = "buried_utility"; importance = "medium" }

  # 下請
  else if (fname ~ /見積/) { label = "estimate"; importance = "medium" }
  else if (fname ~ /下請契約/) { label = "subcontract"; importance = "medium" }

  # 材料
  else if (fname ~ /材料|承認願/) { label = "material_approval"; importance = "medium" }
  else if (fname ~ /カタログ|catalog/) { label = "catalog"; importance = "low" }

  # 施工体制
  else if (fname ~ /施工体制|体系図/) { label = "org_chart"; importance = "medium" }
  else if (fname ~ /作業員名簿|名簿/) { label = "worker_list"; importance = "medium" }
  else if (fname ~ /建設業許可/) { label = "business_permit"; importance = "low" }
  else if (fname ~ /保険|労災/) { label = "insurance"; importance = "low" }
  else if (fname ~ /建退共/) { label = "retirement_fund"; importance = "low" }

  # 安全
  else if (fname ~ /安全|KY/) { label = "safety"; importance = "low" }

  # 品質
  else if (fname ~ /温度管理/) { label = "temperature_mgmt"; importance = "medium" }
  else if (fname ~ /品質管理|品管/) { label = "quality_mgmt"; importance = "medium" }
  else if (fname ~ /出来形/) { label = "measurement"; importance = "medium" }
  else if (fname ~ /試験|密度/) { label = "test_result"; importance = "medium" }

  # 数量
  else if (fname ~ /数量|内訳|精算/) { label = "quantity"; importance = "high" }
  else if (fname ~ /伝票/) { label = "voucher"; importance = "medium" }

  # 許認可
  else if (fname ~ /道路使用|許可/) { label = "permit"; importance = "medium" }
  else if (fname ~ /規制図/) { label = "traffic_plan"; importance = "medium" }
  else if (fname ~ /届出/) { label = "notification"; importance = "medium" }

  # 産廃
  else if (fname ~ /産廃|廃棄物/) { label = "waste"; importance = "medium" }
  else if (fname ~ /積載量/) { label = "load_weight"; importance = "medium" }

  # 創意工夫
  else if (fname ~ /創意工夫/) { label = "innovation"; importance = "medium" }

  # 検査
  else if (fname ~ /検査|チェック/) { label = "inspection"; importance = "medium" }

  # 位置図・地図
  else if (fname ~ /位置図|地図|map/) { label = "location_map"; importance = "low" }

  # CORINS
  else if (fname ~ /[Cc][Oo][Rr][Ii][Nn][Ss]/) { label = "corins"; importance = "medium" }

  # 汎用拡張子
  else if (ext_lower == "gsheet") { label = "spreadsheet"; importance = "medium" }
  else if (ext_lower == "gslides") { label = "slides"; importance = "low" }
  else if (ext_lower == "xlsx" || ext_lower == "xls") { label = "spreadsheet"; importance = "medium" }
  else if (ext_lower == "pdf") { label = "document"; importance = "medium" }
  else if (ext_lower == "json") { label = "data"; importance = "low" }
  else if (ext_lower == "zip") { label = "archive"; importance = "low" }

  # フォルダ（第1レベル）
  folder = path
  if (path ~ /\//) {
    split(path, parts, "/")
    folder = parts[1]
  } else {
    folder = "(root)"
  }

  # JSONL出力
  gsub(/"/, "\\\"", path)
  gsub(/"/, "\\\"", fname)
  gsub(/"/, "\\\"", folder)
  printf "{\"path\":\"%s\",\"name\":\"%s\",\"folder\":\"%s\",\"ext\":\"%s\",\"size\":%s,\"ts\":%s,\"label\":\"%s\",\"importance\":\"%s\"}\n", path, fname, folder, ext_lower, size, ts, label, importance
}
' "$RAW_FILE" > "$INDEX_FILE"

INDEXED=$(wc -l < "$INDEX_FILE")
echo "  Indexed $INDEXED files"

# Step 3: 統計サマリ
echo "[3/3] Summary..."
echo ""
echo "=== Label Distribution ==="
awk -F'"label":"' '{split($2,a,"\""); print a[1]}' "$INDEX_FILE" | sort | uniq -c | sort -rn | head -20
echo ""
echo "=== Critical/High Importance Files ==="
grep -E '"importance":"(critical|high)"' "$INDEX_FILE" | awk -F'"name":"' '{split($2,a,"\""); print a[1]}' | head -20
echo ""
echo "=== Done ==="
echo "Index: $INDEX_FILE ($INDEXED entries)"

rm -f "$RAW_FILE"
