# pave-os

完成した土木工事プロジェクトのフォルダを食わせると、構造化されたナレッジベース（JSON）を生成する。

次の工事で「前回どうだった？」に答えるための参照データを自動で作る。


## 使い方

```bash
./analyze_project.sh "H:/マイドライブ/〇〇工事"
```

出力: `output/YYYYMMDD_HHMMSS_工事名.json`

### 必要なもの

- bash（Git Bash可）
- [Gemini CLI](https://github.com/google-gemini/gemini-cli)（認証済み）
- `find` コマンド

### 環境変数

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `PAVEOS_MODEL` | `gemini-2.5-flash` | 使用するGeminiモデル |

## 出力例

```json
{
  "project_name": "〇〇市道 第X号線工事",
  "work_type": "舗装工事",
  "period": { "start": "2025-09", "end": "2026-03" },
  "subcontractors": ["A社", "B社"],
  "folders": [
    { "name": "施工計画書", "file_count": 95, "date_range": "2025-12~2026-03", "summary": "..." }
  ],
  "phases": [
    {
      "name": "着工準備・施工計画",
      "period": "2025-09~2026-01",
      "parallel_tasks": ["材料承認", "測量・設計照査", "道路使用許可申請", "施工計画書作成"],
      "description": "..."
    }
  ],
  "deliverables": { "photos": 1831, "pdfs": 1000, "total": 2692 },
  "insights": ["..."]
}
```

## 仕組み

1. `find` で全ファイルのメタデータ（日時・サイズ・パス）を1回で取得
2. `awk` でフォルダごとに集計・圧縮（2700ファイル → 9KB）
3. Gemini CLIに圧縮済みコンテキストを投げてJSON生成

Claude等の有料APIを消費しない。Gemini CLIで完結する。

## ロードマップ

- [ ] 複数工事のパターン比較
- [ ] フェーズごとの所要日数の統計
- [ ] 次の工事向け静的計画テンプレート生成
- [ ] 施工中の動的計画（「今ここまで来た、次は何が必要か」）

## License

MIT
