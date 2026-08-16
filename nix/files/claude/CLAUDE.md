# ユーザーレベルの指示

`~/.claude/` の一部（`CLAUDE.md` / `skills/` / `agents/` / `commands/`）は
**Nix (home-manager) 管理**で、dotfiles 本体（`$(ghq root)/github.com/pollenjp/dotfiles`）
の `nix/files/claude/` の複製が `/nix/store` 経由で配置されている。
直接編集せず、リポジトリ側を編集して `home-manager switch` すること。

詳しい手順は、該当パスを編集しようとしたときに `PreToolUse` フック
（`~/.claude/hooks/nix-managed-guard.sh`）が返す。

`skills/` などには private リポジトリ（`claude-skills`）の作業クローンへの symlink も
混ざる。そちらは直接編集してよいが、実体はクローンなので **commit が要る**。

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

`flake.nix` の骨組み・devShell へ入り直す script の形・`.env` の読み込みなど、
実際に書くときの詳細は `pjp-nix-flake` skill。

## 命名

自作の skill / agent / command は、名前を **`pjp-` で始める**（`pjp-drawio` など）。
配信物と同じ名前空間に並ぶので、prefix が無いと一覧で自分のものを見分けられない。

書き方は各 `skills/README.md` を参照（置き場所によって形が変わる）。
