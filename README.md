# consult

Claude Code 用のスキル。Claude Code 純正の `/advisor` の代わりに、ローカルのディスパッチャースクリプトと Agent tool を使って、外部/別モデル（既定 [Codex](https://github.com/openai/codex)、他に Grok・Claude Opus/Fable）へセカンドオピニオンを求める。

## これは何か

Claude Code 純正の `/advisor` は、メインモデルより強いモデルに「方針決定前・エラー連発時・完了宣言前」の3場面で自動相談する実験的機能。サーバ側で管理される仕組みのため、利用者側からアドバイザーの選択や実行条件を細かく制御しにくい場合がある。

このスキルは同種の場面（`SKILL.md` では4つの場面）での相談を自前実装したもの。アドバイザーを自由に選べ、Codex / Grok のような Claude 以外のモデルにも相談できる。

Gemini（Antigravity CLI `agy`）は相談先から外している。Antigravity の規約上、個人向けプランでは Claude Code などサードパーティのエージェントが `agy` を起動・包むことが認められていないため。

## 要件

- [Claude Code](https://claude.com/claude-code)
- bash
- [jq](https://jqlang.org/)
- 相談先として使いたい CLI（[Codex CLI](https://github.com/openai/codex)、Grok CLI など）。設定した advisor のうち、実際にインストール済みのものだけが使われる。

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

以下の4場面に当たったら、Claude が1つの判断につき1回まで、既定アドバイザーに必ず相談する（場面を列挙で固定しているのは、「重要なら」のような曖昧な条件だと相談がほとんど起きなかったため）。

1. 他の案も成り立つ状況で、ユーザが判断に使う推奨を出す直前
2. 同じエラー・テスト失敗が2回続いた時
3. 複数ファイル・複数成果物にまたがる作業の完了報告の直前
4. 不可逆な操作・外向きの操作（削除・一括変更・送信・公開など）の手順を確定する直前

相談したら、報告に実際に応答したモデル名と結論1行、回答の原文を保存したファイルのパスが書かれる。Claude と相談相手がそろってユーザの決めた方針の変更を勧めたときは、Claude は自分で変えずにユーザに聞く。

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
  "timeout_seconds": 900,
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

`consult.sh` は環境変数でその回だけの動きを変えられる。

- `CONSULT_TIMEOUT_SECONDS=<秒>` — タイムアウトを上書きする（優先順位は環境変数 > `config.json` > 既定900秒）。Codex は300秒を超える応答がよくあり、Claude Code の Bash tool は600秒で切れるので、SKILL.md では `run_in_background: true` で起動する。
- `CONSULT_NO_FALLBACK=1` — 指定した相手が失敗しても次の相手へ切り替えずに止まる。外部に出せない情報を含む相談で、別のサービスへ自動で渡らないようにするときに使う。

### advisor サブエージェント（任意）

Claude 系（`type: "claude-agent"`）の相談では、Agent tool を `subagent_type: "advisor"` で起動する。`~/.claude/agents/advisor.md` に次のような定義を置くと、相談役が読み取り専用の道具しか持たなくなる（依頼文ではなくツールで保証する）。無ければ general-purpose で起動し、依頼文で読み取り専用を頼む。

```markdown
---
name: advisor
description: consult スキルから Claude 系のセカンドオピニオン役として呼ぶ読み取り専用の相談役。briefing ファイルと関連ファイルを読み、質問に答える。モデルは呼び出し側が model で指定する。
tools: Read, Grep, Glob, WebFetch, WebSearch
---

あなたはセカンドオピニオンを求められたアドバイザーです。依頼文で示された briefing ファイルを読み、挙がった関連ファイルも自分で読んで確かめ、briefing の質問に番号ごとに結論→理由の順で答えてください。相談者の推しに同意する必要はありません。確かめた事実と推測を分け、根拠はファイルパスや URL で示してください。
```

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
