# ユーザーレベルの指示

`~/.claude/` の一部（`CLAUDE.md` / `skills/` / `agents/` / `commands/`）は
**Nix (home-manager) 管理**で、dotfiles 本体（`$(ghq root)/github.com/pollenjp/dotfiles`）
の `nix/files/claude/` の複製が `/nix/store` 経由で配置されている。
直接編集せず、リポジトリ側を編集して `home-manager switch` すること。

詳しい手順は、該当パスを編集しようとしたときに `PreToolUse` フック
（`~/.claude/hooks/nix-managed-guard.sh`）が返す。

`skills/` などには private リポジトリ（`claude-skills`）の作業クローンへの symlink も
混ざる。そちらは直接編集してよいが、実体はクローンなので **commit が要る**。

## 応答の言語

ユーザーへの返答・報告・質問は**日本語**で書く。skill のテンプレートや指示文が
英語でも、出力は日本語に訳して出す（選択肢のメニューも訳す）。英語の skill を
読んだ直後ほど英語につられやすいので、送る前に言語を確かめる。

commit メッセージ・コードのコメント・repo に置く文書は、その repo の慣習に合わせる。

## 方針を承認したら PR まで走り切る

superpowers の流れ (brainstorming → writing-plans → 実行 → finishing) で承認を求めるのは
**方針の承認 1 回だけ**にする。superpowers の承認の関門 (spec の承認・実装計画のレビューと
実行方式の選択・実装後の 3 択) より、この節を優先する。ユーザーと話している会話のための節で、
subagent は自分への依頼に従う。

- 方針の承認は spec を書く前に 1 回聞き、「承認したら PR まで確認を挟まずに進める」と、その先の段階
  (spec → 実装計画 → 実装 → PR など) とともに書き添える。この承認を spec と実装計画の承認としても扱う
- この承認を得ないまま writing-plans や finishing に来たら (計画だけ頼まれた・brainstorming を
  通らなかったなど)、そこで 1 回だけ聞く。writing-plans では同じく書き添えて承認を、finishing では
  PR を出してよいかを聞く
- 承認のあとは聞かずに進める。builder check の問いは自分で決めて spec に残し、実行方式は推奨を
  理由 1 文とともに告げ、worktree の外なら既定の branch から feature branch を切り、実装後は
  push して PR を作る (merge はしない)。push の前に、PR に載る commit が今回の作業だけかを確かめる
- 承認のあとに書く spec は承認済みの設計の書き写しなので、解説動画の対象にしない
- 止まるのは、取り消せない操作・セキュリティに関わる操作・merge や共有 branch への push・
  方針を覆す発見・PR に今回の作業でない commit が載るとき・この CLAUDE.md の他の節や
  superpowers 以外の skill が確認を求める操作のとき。ユーザーがその会話で別の進め方を言えば従う
- 自分で決めたこと (builder check の判断・実行中の ruling) は、PR を返すときに並べる

skill を読んだ直後には hook (`~/.claude/hooks/run-through-nudge.sh`) も念を押してくる。

## 同梱 script の依存ツール

skill や repo に script を足し、その script が手元に無い外部ツールを要求するとき、
用意する手段はこの順に検討する。

1. **nix flake** — その skill / repo に `flake.nix` と `flake.lock` を置き、
   devShell に入れる。script 側は PATH に無ければ
   `exec nix develop --command "$0"` で入り直す
   （実例は `claude-skills/scripts/lint.sh`）
2. **mise** — flake が過剰なとき。`mise.toml` の `[tools]` に書く
3. **system へ直接入れる** — 1 も 2 も不可能なときだけ

`pip install` / `npm install -g` / `apt install` / `brew install` は実行しない。
3 を選ぶ場合は、1 と 2 が不可能な理由を述べて**確認を取ってから**にする。

ここで決めているのは **その script に閉じた依存** の話。自分のグローバル環境に
何を入れるか（グローバル CLI は Nix、言語ランタイムは mise）は別で、
ADR 001 の決定 6 に従う。

`flake.nix` の骨組み・devShell へ入り直す script の形・`.env` の読み込み・
`flake.lock` の更新（**素の `nix flake update` は使わない**）など、実際に書くときの
詳細は `pjp-nix-flake` skill。

## 命名

自作の skill / agent / command は、名前を **`pjp-` で始める**（`pjp-drawio` など）。
配信物と同じ名前空間に並ぶので、prefix が無いと一覧で自分のものを見分けられない。

書き方は各 `skills/README.md` を参照（置き場所によって形が変わる）。

## 解説動画を作る

`pjp-video-explainer-offer` が skill の一覧にあるときだけ、まとまった設計を提案したとき・
PR を作ったときにその skill を読み、条件に合えば解説動画の短尺を答えを待たずに裏で作り始める。
一覧に無ければ何もしない (ファイルを探さない・作らない)。PR の作成・タグ「設計」の cc-page・
spec / ADR の書き出しは hook (`~/.claude/hooks/video-offer-nudge.sh`) も知らせてくる。
