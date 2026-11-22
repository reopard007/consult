# consult

Claude Code 用のスキル。Claude Code 純正の `/advisor` の代わりに、ローカルのディスパッチャースクリプトと Agent tool を使って、外部/別モデル（既定 [Codex](https://github.com/openai/codex)、他に Grok・Claude Opus/Fable）へセカンドオピニオンを求める。

## これは何か

Claude Code 純正の `/advisor` は、メインモデルより強いモデルに「方針決定前・エラー連発時・完了宣言前」の3場面で自動相談する実験的機能。サーバ側で管理される仕組みのため、利用者側からアドバイザーの選択や実行条件を細かく制御しにくい場合がある。

このスキルは同じ3場面での相談を自前実装したもの。アドバイザーを自由に選べ、Codex / Grok のような Claude 以外のモデルにも相談できる。

## 要件

- [Claude Code](https://claude.com/claude-code)
- bash
- [jq](https://jqlang.org/)
- 相談先として使いたい CLI（[Codex CLI](https://github.com/openai/codex)、Grok CLI など）。設定した advisor のうち、実際にインストール済みのものだけが使われる。

> **Gemini（Antigravity CLI `agy`）について**: 以前は advisor に含めていたが、2026-11-22 に外した。Antigravity の [FAQ](https://antigravity.google/docs/faq) と [追加規約](https://antigravity.google/terms) では、個人向けの契約で Claude Code などサードパーティのエージェントやアプリが `agy` を起動・ラップすることは認められていないため。自分で `config.json` に追加する場合も、契約条件を確認すること。

## インストール

```bash
git clone <this-repo-url> ~/.claude/skills/consult
```

または、このリポジトリを別の場所に置いて `~/.claude/skills/consult` へ symlink する。

```bash
git clone <this-repo-url> ~/path/to/consult
ln -s ~/path/to/consult ~/.claude/skills/consult
```

## 使い方

### 自動発動

以下のいずれかに該当し、相談する価値がある重要さだと判断された時、Claude が1つの判断につき1回まで自動的にこのスキルを使う。

1. 複数の実装方針・設計判断で迷い、これから方針を確定しようとしている
2. 同種のエラーが2回以上繰り返し発生し、自力での解決に行き詰まっている
3. 大きめのタスクの完了をユーザに宣言する直前

### 明示発動

- 「相談して」「セカンドオピニオンが欲しい」「他のモデルにも聞いて」→ 既定アドバイザーへ相談
- 「codex に聞いて」「grok/opus/fable に相談して」→ 指定アドバイザーへその回だけ切替
- 「全員に聞いて」「codex と opus 両方に」→ 合議モード（全アドバイザーへ並列相談）
- `/consult` → 既定アドバイザーへ相談

詳細な手順は [`SKILL.md`](./SKILL.md) を参照。

## 設定

`config.json` でアドバイザーを定義する。

```json
{
  "default": "codex",
  "fallback_order": ["codex", "opus"],
  "timeout_seconds": 300,
  "advisors": {
    "codex": {
      "type": "cli",
      "bin": "codex",
      "args": ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-"],
      "input": "stdin",
      "label": "OpenAI Codex"
    }
  }
}
```

- `type: "cli"` — 外部 CLI ツール。`scripts/consult.sh` が可用性検出・タイムアウト・フォールバックを処理する。
- `type: "claude-agent"` — Claude 系モデル（Opus / Fable など）。`consult.sh` は経由せず、Claude Code の Agent tool を `model` パラメータ付きで直接起動する。
- `input: "stdin"` — briefing ファイルの中身を標準入力で渡す。
- `input: "arg"` — briefing の中身をコマンドライン引数として渡す。**この方式はプロンプト全文がプロセス引数に載るため、同一マシンの他ユーザーから `ps` 等で見える可能性がある**（下記セキュリティ節参照）。

既定アドバイザーやフォールバック順の変更、新しい advisor の追加は `config.json` の編集だけでよい。`scripts/consult.sh` 側の変更は不要。

## セキュリティとプライバシー

- このスキルは、相談内容（コード・エラーメッセージ・設計判断の背景など）を **外部の AI CLI / モデルへ送信する**。機密情報・顧客データ・社内限定情報を含む相談をする前に、それらの外部送信が許容されるか確認すること。
- `input: "arg"` の advisor（既定設定では Grok）は、プロンプト全文をプロセスの起動引数として渡す。同一マシン上の他ユーザーがプロセス一覧（`ps aux` 等）を見られる環境では、内容が露出する可能性がある。機密性の高い相談では `input: "stdin"` の advisor を使うこと。
- `config.json` は任意の `bin` と `args` を実行できる設計になっている。信頼できない `config.json` を使わないこと。
- 各 CLI の認証情報（API キー等）はこのリポジトリでは一切扱わない。各 CLI 自身のローカル設定・認証機構に依存する。

## 既知の制限

- `scripts/consult.sh` は `type: "cli"` の advisor のみを実行する。`type: "claude-agent"` の advisor（Claude Opus / Fable）は、スキル側（`SKILL.md` の手順）が Agent tool を直接呼び出して処理する。
- 各 CLI の挙動は、インストールされているバージョンやそのアカウント設定に依存する。

## ライセンス

[MIT](./LICENSE)
