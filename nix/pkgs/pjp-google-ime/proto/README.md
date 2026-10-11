# Mozc の .proto の写し

`pjp-google-ime` が Google 日本語入力の `config1.db` と `user_dictionary.db` を読み書きするための、
Mozc の protobuf の定義。手を加えずに写している (ライセンスは `LICENSE`、BSD-3-Clause)。

| ファイル | 写した元 |
| --- | --- |
| `config.proto` | `google/mozc` の `src/protocol/config.proto` |
| `user_dictionary_storage.proto` | `google/mozc` の `src/protocol/user_dictionary_storage.proto` |
| `LICENSE` | `google/mozc` の `LICENSE` |

写した commit: `18e76511af9371a9a4409b1d13c3e30884b53e9c` (2026-10-09)。

## 新しくするとき

新しい版の Google 日本語入力が項目を足すと、`bootstrap-windows-google-ime.sh --import` が
「今の .proto に無い項目がある」で止まる。そのときは同じ 3 つを新しい commit から写し直し、
上の commit を書き換えて、`nix build ./nix#checks.x86_64-linux.pjp-google-ime-unittest` を流す。

```sh
rev=<commit>
for f in src/protocol/config.proto src/protocol/user_dictionary_storage.proto LICENSE; do
  gh api -H "Accept: application/vnd.github.raw" "repos/google/mozc/contents/${f}?ref=${rev}" >"nix/pkgs/pjp-google-ime/proto/$(basename "${f}")"
done
```

辞書の品詞の名前 (`google_ime.py` の `POS_NAMES`) は `user_dictionary_storage.proto` のコメントと
突き合わせてある (`test_google_ime.py`)。品詞が増えたらテストが落ちるので、`POS_NAMES` を足す。
