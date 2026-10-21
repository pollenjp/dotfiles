# ADR: setup は対象ホストを推測せず、公開の登録簿から実機を外し、PC の値は dotfiles-private の登録かローカル flake の tmp の 1 か所にだけ書く (段階 3)

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-21 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-21 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-267](https://app.notion.com/p/3ff79149a66f812e9e84f1e559d8ed29)（dotfiles 側）。集約は [TKT-271](https://app.notion.com/p/3ff79149a66f81b6894de060a71e6f2d) |
| 前提 ADR | [026_dotfiles_private_hosts](../026_dotfiles_private_hosts_20261020T215857JST/README.md)（段階 1。この ADR はその §2.F の段階 3 を行い、§2.D の 4 番目の推測をやめる） |
| 改める ADR | [002](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)（ローカル flake の `local` の重ね方）、[007](../007_claude_skill_host_option_20260926T130250JST/README.md)（Dev Tracker の既定 true と、雛形の `local` の false）、[026](../026_dotfiles_private_hosts_20261020T215857JST/README.md)（§2.D の推測と §2.F の段階 3）。[022](../022_one_password_outside_wsl_20261018T105655JST/README.md) の `--host pollenjp@laptop` で当てる手順は、登録したホストを `--host` なしで当てる形になる |
| 運用手順 | [`nix/README.md`「まとめて実行する」](../../../nix/README.md#まとめて実行する)（決める順と止める時機）・[「新規マシンの手順」](../../../nix/README.md#新規マシンの手順)・[「登録簿に載せずにマシンを足す」](../../../nix/README.md#登録簿に載せずにマシンを足す) |
| 設計 | [`docs/superpowers/specs/2026-10-21-dotfiles-private-hosts-stage3-design.md`](../../superpowers/specs/2026-10-21-dotfiles-private-hosts-stage3-design.md) |

---

## 1. 背景 (Context)

ADR 026 で、実機のホストの定義と値を dotfiles-private の `nix/hosts/<user>@<hostname>.nix` に置き、setup が `--host` なしで
その PC のホストを選ぶようにした。段階 2 までで、ユーザーの私物の PC 2 台を登録した。残っていた問題は 3 つ。

| 問題 | 中身 |
| --- | --- |
| 推測 | setup は `--host`・ローカル flake のホスト・dotfiles-private のこの PC のホストのどれも無いと、`$USER` と `uname` から推測した（`<user>@wsl` → `<user>@<system>`）。登録した PC でも、ローカル flake が clone の `nix/` を読んでいない（前の雛形・stub を指す）と、黙って型のホストへ落ちる。推測で型の世代になり、git の署名が外れた例がある（ADR 026 の背景） |
| 実機の情報が public にある | 公開の登録簿に実機 3 つ（`pollenjp@wsl`（Windows のユーザー名入り）・`pollenjp@wsl-no-1password`・`pollenjp@laptop`）が残っていた。ADR 026 の §2.F は、実機が private に移ったら消すと決めていた |
| `local` の重ね方 | 雛形の `local` は登録簿の全ホストに当たり、tmp の例も `local` を渡すので、本体が定義済みの値を差し替えるのに `mkForce` が要った。登録した PC では `local` は使われない |

ユーザーの意図（TKT-267）: setup が推測で公開の登録簿のホストを選ぶのをやめ、PC の値は dotfiles-private の登録（登録した PC）か、
ローカル flake に足した `tmp`（登録していない PC）のどちらか 1 か所にだけ書く。

推測は WSL の上でテストにも効いていた。`nix/tests/setup-host.test.sh` は `/proc/version` を偽っていないので、変更前の setup.sh を
WSL の上で流すと、推測が登録簿の `<user>@wsl` を選んで 4 件落ちた（CI の Linux のランナーでは通っていた）。

## 2. 決定 (Decision)

### A. setup は対象ホストを推測しない

| 順 | 対象ホスト | `--which-host` の決め方 |
| --- | --- | --- |
| 1 | `--host`（`DOTFILES_HOST`・メニューの `h` も） | `--host`・`DOTFILES_HOST`・`menu` |
| 2 | ローカル flake が定義しているホスト（`tmp` など） | `local` |
| 3 | dotfiles-private に登録したこの PC のホスト（clone に `nix/hosts/<名前>.nix` があり、ローカル flake の入力がその clone の `nix/` を指すとき） | `private` |
| — | どれも無ければ止める（終了コード 1） | — |

- 推測の段・`host_source` の `guess`・推測にだけ使っていた `is_wsl` を setup.sh から消す
- **止める文は選べる道を 3 つ出す**: この PC を dotfiles-private に登録する（`pjp-dotfiles-register-host` skill。登録の前の 1 回は 3 で当てる）・
  `~/dotfiles/flake.nix` に `tmp` を足す（dotfiles-private を読めない PC）・`--host <型>` を付ける（型は登録簿から `sandbox` を除いて並べる）。
  clone にこの PC のファイルがあるのにローカル flake が読んでいなければ、代わりに読ませ方（`local-flake-migrate.sh prepare` で今の雛形へ移す。
  ローカル flake がまだ無ければ `--steps local-flake`）と、それまでの当て方（`--host <型>`）を出す
- **止める時機**: 自動で決めたホストは `private-fetch` と `local-flake` のあとで決め直す（ADR 026）。この実行の手順のあとに「clone に
  この PC のファイルがある」（今ある・`private-fetch` で来うる）と「ローカル flake がその clone を読む」（今読む・`local-flake` がこの実行で
  置く）がそろいうるなら手順を流し、決まらなければ switch の頭で止める（取得で届いた登録を同じ実行で拾う）。そろいようがなければ
  （Nix が無い新しいマシン・clone が無い・その手順を選んでいない・登録してあるのにローカル flake が読んでいない）execute の前に止める
  （Nix を入れてから・`preflight-unlink` が home-manager の symlink を外してから止めない）
- `--which-host` も決まらなければ同じ文で 1。`DOTFILES_HOST`（`~/.config/pjp/env`）は今までどおり効く

### B. ローカル flake の雛形から `local` を外す

```nix
homeConfigurations = dotfiles.homeConfigurations // privateHosts // {
  # tmp = dotfiles.lib.mkHome { … };   (コメントの例)
};
```

- tmp の例は値を `mkHome` の引数と `modules` に直に書く。dotfiles の option は、option の既定（優先度 1500）より強いだけの普通の定義なので
  `mkForce` は要らない。有効な行は WSL（`windowsFiles`・`exeExecTrace`）・1Password・Dev Tracker（true）・Notion の宛先で、`gitViaGh`・
  Notion の `routes` と `override`・解説動画の `autoStart`・cc-pages の port は例の中のコメントに置く（例のコメントを 1 段外しても、
  使わない値が入らない）。Windows のユーザー名の例は作り物
- 冒頭のコメントの switch の例は `~/dotfiles#<ホスト>`
- `setup-local-flake.sh` と setup の残りの手作業から、`hostsWith`・`notion.profile` の語を探す警告を外す（今の雛形はどちらも持たない。
  前の雛形は雛形の版の印で知らせる。Notion の宛先が未設定なら home-manager の warnings が出る）
- 本体の `lib.hostsWith` は残す（前の雛形のローカル flake が呼ぶ。全 PC が移ったら消せる）

### C. Dev Tracker の既定を false にする（ADR 007 の §2.A と §2.C を改める）

`dotfiles.claude.devTracker.enable` の既定を false にし、使う所で true を書く: dotfiles-private に登録したファイル・`tmp`（雛形の例）・
`sandbox`（CI の「warnings が空」の確かめが Dev Tracker の経路を通るよう）。型のホストを `--host` で当てた PC では使わない（前の雛形の
`local` が false を書いていたのと同じ振る舞い）。

### D. 公開の登録簿から実機を外す（ADR 026 の §2.F の段階 3）

`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop` を消し、型 3 つと `sandbox` を残す。CI が WSL・1Password・`windowsFiles`・
`exeExecTrace` の組み合わせを build し続けるよう、作り物のホストを x86_64-linux の checks（`home-wsl-example`）にだけ足す
（`homeConfigurations` には出さない。setup の一覧に出ず、`--host` で選べない。macOS のランナーで x86_64-linux を build しない）。
テストの値も作り物にする（`one-password.nix` は登録簿の実機の代わりに作り物の 4 通りで見る）。

### E. 新しい PC の初回

| PC | 流れ |
| --- | --- |
| dotfiles-private を読める | `setup --new-machine --host <型>` で 1 回当てる（Nix・gh・clone がそろう）→ `pjp-dotfiles-register-host` で登録の PR → merge → ローカル flake を今の雛形へ移す（stub から clone へ指し直す）→ `setup --update`（`--host` なし） |
| 読めない | `setup --steps local-flake` でローカル flake を置き、`tmp` を書いてから setup を流す |

元にするホストが段階 3 で公開の登録簿から消えた PC（`pollenjp@wsl` などで当てていた、まだ登録していない PC）は、段階 3 の前の本体を
`git archive` で写して draft・compare する（`pjp-dotfiles-register-host` skill に手順）。

### F. こちらで決めたこと（設計の builder check。ユーザーに確かめずに決めた）

1. WSL の型は作らない（`wsl.enable` だけで増えるのは who-is-asking の 1 つで、ほかは 1Password・windowsFiles・exeExecTrace と組みのときに入る）
2. `lib.hostsWith` は残す
3. 止める時機は決め直しのあと。決め直しで決まりようがないときと新しいマシンは execute の前
4. 026 に足さずに 027 を書く（推測・`local`・Dev Tracker の既定まで決めるため）
5. nixos-config の ADR は書き換えない（README と architecture の運用手順だけ直す。別の repo の PR）
6. stub から clone への指し直しは自動にしない（ADR 026 のまま。skill で確認を取って行う）
7. merge の順: 登録した PC のローカル flake を今の雛形へ移したあとに merge する（移していない PC は止まって案内が出る）
8. 公開の repo に載る値は、新しく書くものと今回触るファイルだけ守る（ADR の本文・過去の plans / specs・出力した図・git の履歴は書き換えない）
9. execute の前に止める条件に「clone が無い」を足す
10. 消えたホストを打つ運用の文書（textbook・`win/README.md`）も直す

実装のときに決めたこと:

- 止める時機の「決め直しで決まりうるか」は、ファイル（今ある・取得で来うる）とローカル flake（今読む・この実行で置く）の両方で見る
  （設計の 3 条件に「登録してあるのにローカル flake が読んでいない（`local-flake` で置けない）」を足した。登録した PC で前の雛形のまま
  `--update` を打ったとき、取得も switch もせずにすぐ読ませ方を出す）
- 作り物の WSL のホストは flake.nix の checks に直に書く（`home-wsl-example`）。tmp の例は fixture
  （`nix/tests/fixtures/local-flake-tmp/tmp.nix`）にし、雛形の本文と同じかを `setup-local-flake.test.sh` が、評価できて warnings が空なことを
  `local-flake-tmp-state` が見る
- `local-flake-migrate.sh compare` は今までどおり `sandbox` を比べない（移す元の前の雛形の `local` は、`sandbox` の値とぶつかって評価が落ちる）
- 下書き（`private-host.sh draft`）の頭のコメントから `local` を外す（「ローカル flake の値はこのホストには当たらない」「ローカル flake で評価した値」）

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/setup.sh` | 推測の段を消し、`host_may_resolve`（決め直しで決まりうるか）・`host_undecided`（止める文）・`type_hosts`（型の名前）。`--which-host`・execute の前・switch の頭で止める。残りの手作業の `hostsWith`/`notion.profile` の grep を外す。usage・見出し・選び直しの文 |
| `nix/scripts/setup-local-flake.sh` | 雛形から `local` を外し、tmp の例を `mkHome` の引数に直に書く形にする。既存ファイルへの `hostsWith`・`notion.profile` の警告を外す |
| `nix/scripts/private-host.sh` | `local` の無い flake で inspect（「local: 無い (今の雛形)」）・draft が動く。setup が決まらないときは「決まらない (setup は止まる)」。推測の表示を消す |
| `nix/scripts/local-flake-migrate.sh` | `sandbox` を比べない理由のコメント（比べ方は変えない） |
| `nix/lib/host-draft.nix` | 下書きの頭のコメントから `local` を外す |
| `nix/lib/mk-home.nix` | コメント（Dev Tracker の既定・`local`・作り物の例） |
| `nix/home/options.nix` | `devTracker.enable` の既定を false に。説明の置き場所（`local` → 登録したファイルか `tmp`）。`windowsUserName` の例を作り物に |
| `nix/home/modules/claude.nix` | `notion.profile` の警告の直し方を、そのホストの `mkHome`（登録したファイルか `tmp`）に書く形に |
| `nix/hosts/default.nix` | 実機 3 つを消し、先頭のコメントを今の形に。`sandbox` に `claude.devTracker.enable = true` |
| `nix/flake.nix` | checks に `home-wsl-example`（x86_64-linux だけ）・`local-flake-tmp-state`。`setup-local-flake-test`・`local-flake-migrate-test` に fixture も渡す。コメント |
| `nix/tests/*` | 下の「6. 検証」 |
| `nix/pjp-env/dotfiles.txt` | `DOTFILES_HOST` の取り得る値 |
| `nix/README.md`・`README.md`・`win/README.md`・ADR 001 の textbook | 推測・登録簿の実機・`local` の記述を今の形に。消えたホストを打つ例は `<ホスト>` か型に。触った所の実機の値を一般の書き方に |
| `nix/files/claude/skills/pjp-dotfiles-register-host`・`pjp-dotfiles-local-flake-migrate` | 型を元にする登録・消えたホストを元にする登録・段階 3 の雛形へ移すときの `local` の扱い |
| ADR 002・007・022・026 | 冒頭の表と該当箇所に注記（本文は当時の記録として残す） |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| Dev Tracker: 本体の既定は true のまま、型のホストに false を書く（案 B） | ユーザーが案 A（本体の既定を false にする）を選んだ。B では型のホストと `sandbox` で値が分かれ、どのホストで何が入るかを登録簿の行ごとに覚えることになる |
| 推測を残し、登録した PC でだけ止める | 登録していない PC でも、推測で型の世代になって値が黙って外れる問題は同じ。決まらないことをその場で知らせる方が直しやすい |
| 決まらないとき、いつも execute の前に止める | `private-fetch` で届いた登録や、この実行で置いたローカル flake を同じ実行で拾えない（新しい PC で 2 回流すことになる） |
| 決まらないとき、いつも switch の頭で止める | Nix の無い新しいマシンで Nix を入れてから止まる。既存のマシンで `--new-machine` を打つと、`preflight-unlink` が home-manager の symlink を外してから止まる |
| 雛形の `local` を空にして残す | 登録した PC では使われず、登録していない PC は `tmp` に書けば足りる。`local` が型のホストに当たる形が残ると、`mkForce` の要る重ね方も残る |
| WSL の型（`<user>@wsl`）を登録簿に足す | 増えるのは who-is-asking の 1 つだけで、ほかは組みのときに入る。初回は `<user>@x86_64-linux` で当て、登録で `wsl` の値を足せば足りる |
| `lib.hostsWith` を消す | 前の雛形のローカル flake が評価できなくなる |
| setup が stub から clone へ自動で指し直す | ユーザーのファイルを確認なしに書き換える（ADR 026 のまま、skill で確認を取る） |

## 5. 影響 (Consequences)

良くなること:

- 推測で型のホストになり、登録した PC の値（git の署名など）が黙って外れることが無くなる。決まらなければ、その場で直し方が出る
- 公開の登録簿に実機の情報（Windows のユーザー名など）が無くなる
- PC の値の置き場所が 1 か所になる（登録したファイルか `tmp`）。`tmp` の例は `mkForce` 無しで書ける
- WSL の上でも setup-host.test.sh が通る（推測が手元の `/proc/version` を見なくなった）

注意が必要なこと:

- **ローカル flake を今の雛形へ移していない PC は、merge のあと `--host` なしの setup が止まる**（登録した PC は、ローカル flake が clone を
  読むまで登録したホストを選べない。登録していない PC は推測が無くなる）。止まると直し方が出る。登録した PC は merge の前に移しておく
- 前の雛形の `local` の値は型のホストにしか当たらない。`local` に値を書いていた登録していない PC は、その値を `tmp` か登録へ移す
  （`local-flake-migrate.sh prepare` は `local` の塊を衝突として残すので、黙って消えない）
- 型のホストを `--host` で当てた PC では Dev Tracker が off になる（前の雛形の `local` と同じ）。型だけで足りる PC は、毎回 `--host <型>` を
  付けるか `DOTFILES_HOST` に書く
- 雛形の版の印が変わるので、全 PC で一度は移す知らせが出る
- 公開の登録簿に WSL のホストが無いので、新しい WSL の PC は初回を `<user>@x86_64-linux` で当て、登録のときに `wsl` の値を足す
- 段階 3 の前に `pollenjp@wsl` などで当てていた、まだ登録していない PC を登録するときは、段階 3 の前の本体の写しが要る（skill の手順）

## 6. 検証 (Verification)

VERIFICATION_PLACEHOLDER

## 7. 移行・運用手順

merge の前に、登録した PC で（ローカル flake が今の雛形で clone を読んでいるか）:

```sh
~/dotfiles/setup --which-host        # <user>@<hostname><TAB>private なら移してある
```

`private` が出ない登録した PC は、先にローカル flake を今の雛形へ移す（`pjp-dotfiles-local-flake-migrate` skill）。

merge の後、各 PC で:

```sh
~/dotfiles/setup --self-update --update   # 本体を新しくして switch。前の雛形なら「前の雛形から作られています」と出る
```

移す知らせが出たら、`pjp-dotfiles-local-flake-migrate` skill でローカル flake を今の雛形へ移す（登録した PC は `local` の塊が衝突なく
消える）。止まったら、出た案内のとおり、登録する（`pjp-dotfiles-register-host`）・`~/dotfiles/flake.nix` に `tmp` を足す・`--host <型>` を
付ける、のどれかで決める。
