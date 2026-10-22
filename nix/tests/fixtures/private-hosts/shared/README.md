# nix/tests/private-hosts.nix の作り物

dotfiles-private の `nix/shared/` の形。`.nix` の module は登録した全ホストに足す。`.nix` でないこのファイルと、
名前が `.` で始まるファイル (`.hidden.nix`。読めば評価が止まる) は拾わないことも確かめる。
