# nix/tests/local-flake-migrate.test.sh の fixture

`template-adr026.txt` は、ローカル flake の雛形 (`nix/scripts/setup-local-flake.sh` の heredoc) の **ADR 026 の版**
(`local` を持ち、`dotfiles.lib.hostsWith [ local ] // privateHosts // { … }` と重ねる版。commit `f1c71ee`) の原文
(展開する前の `${nix_dir}` などのまま)。テストは、これを前の版として使い捨ての repo に commit し、今の雛形 (ADR 027。`local` を
持たない) へ `local-flake-migrate.sh prepare` で移せることを確かめる。

tmp の例のコメントにあった Windows のユーザー名だけ、作り物 (`alice`) に替えてある。移し方 (3-way merge) は、前の版・手元・
今の版の 3 つを同じ fixture から描くので、替えても確かめることは変わらない。
