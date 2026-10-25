# dotfiles

Nix home-manager で配置する。リポジトリ本体は `~/ghq/github.com/pollenjp/dotfiles` に置き、
日々の操作は `~/dotfiles/setup` から行う（`~/dotfiles` はローカル専用 flake の置き場所）。
手順は [`nix/README.md`](./nix/README.md)。

| パス | 中身 |
| --- | --- |
| [`nix/`](./nix/README.md) | home-manager の flake と `setup.sh`。対象は Linux / macOS / WSL |
| [`win/`](./win/README.md) | Windows 側のアプリの設定（Orca など）。WSL の `~/dotfiles/setup --update` が `/mnt/c` へコピーして配る |
| [`CLAUDE.md`](./CLAUDE.md) | この repo で作業する Claude Code への決まり（設計の文書の置き場・PR と commit に書くもの） |

決めたことと、その理由の記録（ADR）と設計の文書（spec・実装計画）は、この repo（public）には置かず、private な
[pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の `docs/` に置く（[`CLAUDE.md`](./CLAUDE.md)）。
コードのコメントや README の「ADR NNN」は、そこの `docs/adr/` の ADR を指す。

ssh の接続先は private な [pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の `ssh/` に置き、
`setup` が `~/.ssh/config.d/` へ張り、Windows の `%USERPROFILE%\.ssh` へはコピーする
（[ADR 016](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)）。

実機のホストの定義と値も dotfiles-private の `nix/hosts/<user>@<hostname>.nix` に置き、登録した PC では `setup` が `--host` なしで
そのホストを選ぶ（[ADR 026](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/026_dotfiles_private_hosts_20261020T215857JST/README.md)。登録は Claude Code の
`pjp-dotfiles-register-host` skill）。public の登録簿（`nix/hosts/default.nix`）には型（`<user>@<system>`）と検証用の `sandbox` だけを
置き、dotfiles-private を読めない PC は `~/dotfiles/flake.nix` に足したホスト（`tmp`）に値を書く。どちらも無ければ `setup` は推測せずに
止まり、選べる道を出す（[ADR 027](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/027_stop_guessing_host_20261021T143517JST/README.md)）。
登録した全 PC に効かせる値（mise の遅延を期間付きで緩める上書きなど）は、dotfiles-private の `nix/shared/*.nix` に置く
（[`nix/README.md`](./nix/README.md#dotfiles-private-に登録したホスト)）。

herdr の集約ハブ `~/h` は、private な claude-skills の skill `pjp-herdr-hub` の `hub-init.sh` を `setup` が打って作る
（[`nix/README.md`](./nix/README.md#herdr-の集約ハブ-h)）。

> 以前は `~/dotfiles` に clone して `./main.bash setup` で symlink を張る旧経路もあった
> （Windows の Git Bash もこれを使っていた）。
> [ADR 013](https://github.com/pollenjp/dotfiles-private/blob/main/docs/adr/013_remove_legacy_tree_20261007T015646JST/README.md) で削除し、
> Git Bash の設定は管理しなくなった。旧経路のファイルは `4a54c96` までの履歴にある。
