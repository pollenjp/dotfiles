# dotfiles-private の nix/ の代わり (空)

ローカル flake (`~/dotfiles/flake.nix`) の雛形は、dotfiles-private の clone の `nix/` を `path:` の入力
(`inputs.dotfiles-private`) に取り、`nix/hosts/<user>@<hostname>.nix` に登録した PC のホストを読む
（[ADR 026](../../docs/adr/026_dotfiles_private_hosts_20261020T215857JST/README.md)・[`nix/README.md`](../README.md#dotfiles-private-に登録したホスト)）。

雛形を書いたときに clone の `nix/` が無かったマシン（dotfiles-private を取れない会社の PC・clone する前の新しい PC）では、
入力の行の形を変えずに、ここを指す。`hosts/` が無いので、`dotfiles.lib.privateHosts` は何も足さない。

clone ができたら、値を引き継いで今の雛形へ移すとき（`nix/scripts/local-flake-migrate.sh prepare`）に clone の `nix/` へ
指し直す。ここには何も足さない（`hosts/` を置くと、このマシンのローカル flake がそれをホストとして読む）。
