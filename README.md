# musubi-analytics Plugin

Claude Code のトランスクリプトデータを解析し、musubi ダッシュボードに送信する Plugin。
スキル・サブエージェント・MCP の利用状況をセッション単位で追跡する。

## 公開手順（管理者向け）

1. `packages/claude-plugin/` の内容を独立した GitHub リポジトリにプッシュ

   ```bash
   # 例: github.com/yourorg/musubi-analytics-plugin
   cd packages/claude-plugin
   git init && git remote add origin git@github.com:yourorg/musubi-analytics-plugin.git
   git add . && git commit -m "Initial release" && git push -u origin main
   ```

2. リポジトリは public でも private でも可（private の場合は社内メンバーのみアクセス可能）

## インストール手順（ユーザー向け）

### 1. Marketplace 追加（初回のみ）

```
/plugin marketplace add yourorg/musubi-analytics-plugin
```

### 2. Plugin インストール

```
/plugin install musubi-analytics@musubi-analytics
```

### 3. セットアップ実行

```
/musubi-setup
```

- ダッシュボードで API キーを発行
- API キーを入力
- 疎通確認・hook 自動配置

### 4. 動作確認

Claude Code セッションを終了し、ダッシュボードでデータ到着を確認。

## アップデート手順

```
/plugin update musubi-analytics@musubi-analytics
```

GitHub リポジトリに push するだけで、ユーザーは update コマンドで最新版を取得可能。

## アーキテクチャ

```
Session End → Stop hook → parse-transcript.mjs → POST /api/transcript → DB (cc_* テーブル)
```

- **Stop hook**: Claude Code セッション終了時に自動実行
- **parse-transcript.mjs**: JSONL トランスクリプトを解析してモデル別・ツール別に集計
- **/api/transcript**: 集計データを受信し cc_sessions / cc_session_models / cc_session_tools に upsert

## 収集データ

- セッション単位のトークン使用量・コスト
- モデル別（Opus/Sonnet/Haiku）の内訳
- ツール別の呼び出し回数
- MCP サーバー、Skill、サブエージェントの利用状況
