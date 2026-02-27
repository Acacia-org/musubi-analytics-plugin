---
name: musubi-setup
description: musubi analytics のセットアップ。API キーの設定と hook の自動配置を行います。
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# musubi-setup

Claude Code セッションのトランスクリプトデータを musubi ダッシュボードに送信するためのセットアップを行います。

## Steps

### 1. 状態チェック

`~/.claude/settings.json` を読み、以下の設定状態を確認する:

- `env.MUSUBI_API_KEY` の有無
- `hooks.Stop` に `musubi-stop-transcript-collect.sh` が含まれているか
- `~/.claude/hooks/musubi-stop-transcript-collect.sh` が存在するか
- `~/.claude/hooks/musubi-parse-transcript.mjs` が存在するか

**全て設定済みの場合:**

AskUserQuestion で確認:

- **設定を更新する** — ステップ 2 に進む
- **何もしない** — 「セットアップ済みです」と表示して終了

**未設定の項目がある場合:** ステップ 2 に進む

### 2. API キー取得案内

以下を表示:

```
musubi analytics をセットアップします。

1. musubi ダッシュボードをブラウザで開く
2. Settings > AI Analytics > API Keys に移動
3. 新しい API キーを発行（例: "my-macbook"）
4. API キーをコピーして、次の質問に貼り付けてください
```

AskUserQuestion で API キーの入力を待つ。

#### 疎通確認

API URL は環境変数 `MUSUBI_API_URL` が設定されていればそれを使い、なければ `https://api.musubi-me.app` をデフォルトとする。

```bash
curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer <API_KEY>" \
  "<api-url>/api/transcript/health"
```

- HTTP 200 以外: エラーメッセージを表示して中断
- HTTP 200: レスポンス JSON から `workspaceName` と `userName` を取得して表示:

```
接続確認OK！
ワークスペース: <workspaceName>
ユーザー: <userName>
```

### 3. 自動設定

#### Hook スクリプトのデプロイ

以下のファイルを `~/.claude/hooks/` にコピー:

- `musubi-parse-transcript.mjs`
- `musubi-stop-transcript-collect.sh`

ソースパスの検索順:

1. Plugin インストールパス: `~/.claude/plugins/musubi-analytics@musubi-analytics/skills/musubi-setup/scripts/`
2. プロジェクトローカル: `$CLAUDE_PROJECT_DIR/.claude/hooks/`（開発用フォールバック）

コピー後、`chmod +x ~/.claude/hooks/musubi-stop-transcript-collect.sh` を実行。

#### `~/.claude/settings.json` の更新

`env` に追加:

- `MUSUBI_API_KEY`: ユーザーが入力した API キー

Stop hook を追加（既存の hooks とマージ、既に存在する場合はスキップ）:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/musubi-stop-transcript-collect.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### 4. 完了メッセージ

```
セットアップ完了！
Claude Code セッション終了時にトランスクリプトデータが自動送信されます。
ダッシュボードでデータを確認してください。
```
