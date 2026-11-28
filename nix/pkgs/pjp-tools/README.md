# pjp-tools (ハブと子の道具)

herdr-app と hc の集約ハブ (`~/h`) と、ハブが立てる子の会話が使う道具の Rust の workspace。設計は dotfiles-private の
ADR 124 (`docs/adr/124_*`) と spec (`docs/superpowers/specs/2026-11-28-hub-tools-public-design.md`)。

| crate | bin | 道具 |
| --- | --- | --- |
| `crates/pjp` | `pjp` | 入口。`pjp hub|child|mark|pack …` は同じディレクトリの `pjp-<道具>` を起こし、ほかの `pjp …` は private な claude-skills の shim (`pjp-skills`) へそのまま渡す |
| `crates/pjp-hc-hub` | `pjp-hub` | `pjp hub init|check|guard|hello|bake` (ハブを作る・守る・会話の始めに点検する・panel の図を焼く) |
| `crates/pjp-hc-child` | `pjp-child`・`pjp-mark`・`pjp-pack` | `pjp child …` (子を立てる・読む・送る・片付ける)・`pjp mark …` (space の名前と印)・`pjp pack …` (pack の JSON) |
| `crates/pjp-core` | — | 土台 (OS の違い・終了コード・置き場所・外のコマンド・時刻・private な足し分があるか) |

使い方は skill (`nix/files/claude/skills/pjp-hc-hub`・`pjp-hc-child`・`pjp-hc-hub-panel`) と、各道具の `--help`。

## どこから来たか

claude-skills (private) の `skills/pjp-hc-hub/rust`・`skills/pjp-hc-child/rust`・`crates/pjp-core` から移した (ハブの雛形 `assets/hub` と
子の claude の引数 `assets/claude-args.toml` も)。`crates/pjp-core` は claude-skills の `crates/pjp-core` から分かれた写しで、claude-skills に
残る private な道具 (pjp ticket など) の土台とは別々に育つ (claude-skills の shim 専用の clone・toolchain は写していない)。コメントの
「spec §n」は、移す前の設計 (claude-skills の `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md`) を指す。

private な足し分 (Dev Tracker・Notion・解説動画) は claude-skills に残る。公開の道具は足し分を前提にせず、足し分があるとき
(`pjp-skills` が PATH か `<CARGO_HOME か ~/.cargo>/bin/` にある・`~/.claude/skills/pjp-hc-hub-private/` がある) だけ、その案内を出す。

## 配り方

- Linux: `default.nix` の package。home-manager は `nix/home/modules/pjp-tools.nix` が、hc が入るホスト (`dotfiles.herdrCore.enable`) と
  claude-skills の道具を使うホスト (`dotfiles.claude.privateSkills.enable`) に入れる
- Windows: CI (`.github/workflows/pjp-tools-release.yml`) が、この workspace の git の tree の hash (key) ごとの Release に exe を置き、runner の
  手順 `pjp-tools` が確かめて `%LOCALAPPDATA%\dotfiles\bin\` に置く (win/README.md の「ハブと子の道具 (pjp-tools)」)

## 直す

```sh
cd nix/pkgs/pjp-tools
nix develop ../..#pjp-tools --command cargo test --workspace
nix develop ../..#pjp-tools --command cargo clippy --workspace --all-targets -- -D warnings
nix develop ../..#pjp-tools --command cargo fmt --all
```

- 試験は CI でも流れる: Linux と macOS は nix の checks (`pjp-tools-test`・`pjp-tools-lint`)、Windows は `.github/workflows/pjp-tools.yml`
- 依存を足す・上げるときは、公開から 7 日以上たった版にする (`Cargo.toml` の冒頭)
- 個人の値 (ユーザー名・ホスト名・機器名・tailnet の IP・公開鍵・メール) と、Dev Tracker のチケットの ID・URL を書かない (公開の repo)。
  試験の値は作った名前 (`host-a`・`wsl1`・`user`・`ABC-1` など) にする
