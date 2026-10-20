# ADR: 実機のホストの定義と値を dotfiles-private の nix/hosts/ に置き、ローカル flake が 2 つ目の path: 入力で読み、setup が hostname で選ぶ

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-20 にユーザーが承認 (段階 1)。文面は PR でレビュー |
| 日付 | 2026-10-20 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-257](https://app.notion.com/p/dotfiles-private-1-PC-skill-pjp-dotfiles-register-host-dotfiles-3ff79149a66f819ba141fdd679878b87)（dotfiles 側）。集約は [TKT-245](https://app.notion.com/p/dotfiles-private-nix-host-PC-dotfiles-flake-nix-3ff79149a66f81ecab8ac9d144f866c1) |
| 関連 ADR | [002_nix_hosts_and_local_flake](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)（登録簿とローカル flake。この ADR は実機の置き場所を private へ足す）、[015](../015_win_google_ime_powertoys_20261011T234247JST/README.md)・[016](../016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)（dotfiles-private を public の flake input にしない）、[022_one_password_outside_wsl](../022_one_password_outside_wsl_20261018T105655JST/README.md)（lavie を `--host pollenjp@laptop` で当てる手順。登録した PC では使わない）、[024_local_flake_template_migrate](../024_local_flake_template_migrate_20261020T120111JST/README.md)（雛形の版の印と移し方。この ADR で雛形の版が変わる） |
| 運用手順 | [`nix/README.md`「dotfiles-private に登録したホスト」](../../../nix/README.md#dotfiles-private-に登録したホスト) |
| 設計 | [`docs/superpowers/specs/2026-10-20-dotfiles-private-hosts-design.md`](../../superpowers/specs/2026-10-20-dotfiles-private-hosts-design.md) |

---

## 1. 背景 (Context)

マシンごとの差は 3 か所に分かれていた。

| 場所 | 中身 | git |
| --- | --- | --- |
| `nix/hosts/default.nix`（public の登録簿） | 型（`pollenjp@x86_64-linux` など）と実機（`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop`） | public |
| `~/dotfiles/flake.nix` の `local` と手で足したホスト | マシンごとの option の値（Dev Tracker・Notion の宛先・cc-pages の port など） | 管理外 |
| setup のホストの決め方 | `--host` → `DOTFILES_HOST` → ローカル flake のホスト → `$USER` と `uname` からの推測 | — |

困っていたこと（ユーザーの言葉:「`~/dotfiles/setup --self-update --update` で更新することがおおく、host を指定し忘れてしまうことがおおい」
「dotfiles という public な repository で管理しようとしているけど、これを dotfiles-private 側に移すにはどうするかの方が大事」）:

- **`--host` の付け忘れ。** lavie（NixOS の実機）の世代は、登録簿の `pollenjp@laptop` ではなく推測の `pollenjp@x86_64-linux` で
  作られていた。nixos-config の README は「`--host` は省かない」と書くが、毎回覚えておく必要がある
- **値が PC ごとの手書き。** `local` の値は各 PC の git 管理外のファイルにしか無く、雛形が変わるたびに PC ごとに移す（ADR 024）
- **実機の情報が public にある。** public に載せたくない差分は `local` に書く決まりだが、そうすると上の手書きに戻る

## 2. 決定 (Decision)

### A. 実機は dotfiles-private の `nix/hosts/<user>@<hostname>.nix` に置く

```
dotfiles-private/
└── nix/
    └── hosts/
        └── <user>@<hostname>.nix    1 実機 1 ファイル。ファイル名から .nix を除いたものがホストの名前
```

中身は登録簿の 1 エントリと同じ形で、`mkHome` を受け取って呼ぶ関数（段階 3 で public から移すときにそのまま写せる）。
そのファイルがその PC の値の全部（`mkHome` の引数 + 今まで `local` に書いていた値）を持つ。

```nix
{ mkHome, ... }:
mkHome {
  username = "…";
  system = "x86_64-linux";
  claude = {
    devTracker.enable = true;
    notion.profile = "…";
  };
  modules = [
    {
      dotfiles.ccPages.port = …;
    }
  ];
}
```

`nix/` の下だけを読む（`ssh/` と辞書は `/nix/store` に入れない）。読んだものは誰でも読める `/nix/store` に入る（今までの `local` の値と同じ扱い）。
秘密（API キー・トークン）は置かない（今までどおり `~/.config/pjp/env`）。

### B. 読む仕組みは本体の `lib.privateHosts`

`nix/lib/private-hosts.nix`。dotfiles-private の `nix/`（path か、`outPath` を持つ attrset）を受け取り、`hosts/*.nix` を `builtins.readDir`
で並べて、各ファイルを `{ mkHome = <素の mkHome>; }` で呼ぶ。`hosts/` が無い・空なら `{ }`。`.nix` でないファイルは拾わない。

- 素の `mkHome` を渡すので、ローカル flake の **`local` は private のホストに当たらない**。雛形の `local` は `devTracker.enable = false`・
  `notion.profile = null` を同じ優先度で書くので、当てると private の値とぶつかって評価が落ちる
- 本体の flake は dotfiles-private を input に持たない（ADR 015 / 016: public の lock に private の rev を残さない・public の CI が private を
  取れずに落ちる）。呼ぶのはローカル flake の雛形だけ
- 読み方を本体に置くので、読み方を直しても雛形の版は変わらない

### C. ローカル flake の雛形が 2 つ目の `path:` 入力で読む

```nix
inputs.dotfiles.url = "path:<本体>/nix";
inputs.dotfiles-private.url = "path:<dotfiles-private の clone>/nix";
inputs.dotfiles-private.flake = false;
…
privateHosts = dotfiles.lib.privateHosts dotfiles-private;
…
homeConfigurations = dotfiles.lib.hostsWith [ local ] // privateHosts // { … };
```

- 指す先は `nix/scripts/private-host.sh input-dir` が決める: 雛形を書くときに clone の `nix/` があればそこ、無ければ本体の空の stub
  （`nix/private-stub`）。どちらでも入力の行の形は同じ（入力を条件で消すと、雛形の形が PC で変わり 3-way merge が込み入る）
- clone ができたあと stub を指したままなら、`local-flake-migrate.sh` が指し直す（`status` は印が同じでも入力が違えば 1、
  `prepare` はその 1 行を移す）
- 重ね順は登録簿 → private → このマシンだけのホスト（後ろが勝つ）。private が登録簿と同じ名前なら private が勝つ（段階 3 で実機を移す形）
- `path:` 入力は narHash で lock されるので、setup の lock の張り直し（`sync_local_flake_lock`）と `local-flake-migrate.sh compare` は
  `path:` 入力を全部見て、合っていない入力だけをまとめて `nix flake update <名前>…` で張り直す
- 雛形の heredoc の展開は `${nix_dir}`・`${private_nix_dir}`・`${template_id}`（`local-flake-migrate.sh` が同じ展開を真似て描く）。
  雛形の版の印は変わるので、既存の PC には一度ずつ移す知らせが出る（ADR 024）

### D. setup は `--host` が無ければ、この PC の名前のホストを選ぶ

| 順 | 対象ホスト |
| --- | --- |
| 1 | `--host`（`DOTFILES_HOST` も） |
| 2 | ローカル flake（`~/dotfiles/flake.nix`）が定義しているホスト |
| 3 | dotfiles-private に登録したこの PC のホスト（`<user>@<短い hostname>`）。clone に `nix/hosts/<その名前>.nix` があり、ローカル flake の入力がその clone の `nix/` を指すときだけ |
| 4 | `$USER` と `uname` からの推測 |

- この PC の名前は `private-host.sh name` だけが決める（setup と登録の skill で同じ名前になるように）。user は `$USER`、hostname は
  macOS ならネットワークで変わらない `LocalHostName`（`scutil`）、ほかは `uname -n` の最初の `.` まで（`hostname -s` と同じ）。
  bash と uname だけで動く（setup は Nix を入れる前にも判定する）
- clone の場所の決め方は 1 つ（`$DOTFILES_PRIVATE_DIR` → `$(ghq root)/github.com/pollenjp/dotfiles-private` → `~/ghq/…`）。
  bootstrap-*.sh の `private_dir()` と本文が同じことをテストで見る
- 選んだホストの出どころを出す（`対象ホスト: X  (dotfiles-private の …/nix/hosts/X.nix で定義)`）。`--which-host` は
  `<ホスト><TAB><決め方>` を出して終わる（登録の script とテストが setup の判定をそのまま引く）
- 知らせ: clone にこの PC のファイルがあるのにローカル flake が読んでいない（入力が無い・stub を指す）→ 残りの手作業に直し方。
  `--host`・`DOTFILES_HOST`・メニューの `h` で、この PC の登録した名前と違うホストを選んだ → 警告（止めない。明示した方で当てる。
  まとめの `[対象ホスト]` にも載る）。nixos-config の README などに残る `--host pollenjp@laptop` の手順で当てたときに気づけるように
- **dotfiles-private は switch の前に取る**（手順 `private-fetch`。「既存マシン更新」と「新しいマシン適用」に入る）。clone があれば
  bootstrap-dotfiles-private.sh を流して fast-forward し、同じ実行の後ろの手順 bootstrap-dotfiles-private（order 50）は飛ばす。
  clone が無ければ何もせず、後ろの手順が今までどおり clone する。取れなくても止めない（手元の clone で評価する）

### E. 登録は skill `pjp-dotfiles-register-host` と `private-host.sh`

決まった処理は `nix/scripts/private-host.sh`（本体と同じ版で配る）と `nix/lib/host-draft.nix` が持ち、skill は判断と確認の取り方を持つ。

| コマンド | すること |
| --- | --- |
| `inspect` | この PC（名前・WSL なら Windows のユーザー名）・clone と登録・ローカル flake（入力・手で足したホスト・`local` の行）・setup が選ぶホスト・今の世代と outPath が一致するホスト（元にするホストの候補）を出す |
| `draft --base <ホスト>` | 元のホスト（+ `local`）の `options.dotfiles` を歩き、option の既定（優先度 1500）より強い定義を持つ値を `mkHome` の引数（`wsl`・`onePassword`・`claude`）と `modules` に描く。既定と同じ値を明示した行も拾い、既定が別の option から決まる値と改名の旧名は拾わない。`local` の dotfiles の外の行は描かずに頭のコメントで知らせる |
| `compare --base <ホスト> --private <作業ツリー>` | 旧い形（ローカル flake の写しの元のホスト。`local` が当たる）と新しい形（private の `<名前>`。`local` は当たらない）を、同じ本体・同じ lock で評価して drvPath を比べる。0 = 同じ（この登録で世代の中身は変わらない）、1 = 違う（`config.dotfiles` の違いを出す）、3 / 4 = 評価できない |

- 「中身が同じ」は、同じ本体・同じ lock での旧い形と新しい形の比べ方で決める。今の世代との一致では決めない（本体を進めると、skill を 1 つ
  足しただけでも全ホストの世代が変わる）。今の世代との一致は、元にするホストを見つけるため（`inspect`）と参考の表示にだけ使う
- 評価はローカル flake の写しで行い、`~/dotfiles` と dotfiles-private には書かない（`draft` が書くのは `--out` だけ）
- 手順は会話の置き場所で分ける: 調べる・下書きの確認と、merge 後のローカル flake の移行はその PC の会話が、dotfiles-private に書く・
  比べる・PR は dotfiles-private の worktree の会話がする（集約ハブや別の repo の会話なら、pjp-herdr-other-repo で子に下書きを渡す）
- 書く前に確認を取る: dotfiles-private に書く前に下書きと、登録で振る舞いが変わる所（署名・Notion の宛先など）を見せる。
  `~/dotfiles/flake.nix` を移す前に差分を見せる（ユーザーのファイル）

### F. 段階

| 段階 | すること |
| --- | --- |
| 1（この ADR） | 仕組み（B〜E）と、lavie の登録（dotfiles-private の PR） |
| 2 | WSL の PC の登録（その PC で skill を呼ぶ） |
| 3 | 実機が全部 private に移ったら、public の登録簿から実機（`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop`）を消し、nixos-config の README の `--host pollenjp@laptop` を直す |

段階 3 まで、public の登録簿の実機の行は 1 行も消さない。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/lib/private-hosts.nix` | 新設（`lib.privateHosts`） |
| `nix/lib/host-draft.nix` | 新設（下書きの `collect`・`render`） |
| `nix/private-stub/README.md` | 新設（clone の無いマシンが指す空の stub） |
| `nix/flake.nix` | `lib` に `privateHosts`。checks に `private-hosts-state`・`host-draft-state`・`private-host-test`・`setup-host-test` |
| `nix/scripts/private-host.sh` | 新設（`name`・`dir`・`input-dir`・`inspect`・`draft`・`compare`） |
| `nix/scripts/setup-local-flake.sh` | 雛形に `inputs.dotfiles-private` と `privateHosts` |
| `nix/scripts/local-flake-migrate.sh` | `${private_nix_dir}` を描く。印が同じでも入力が違えば移す。lock は `path:` 入力ぜんぶ。compare は dotfiles-private のホストを区別する |
| `nix/scripts/setup.sh` | ホストの決め方（3 番目に private）・`--which-host`・手順 `private-fetch`・lock の張り直し・知らせ |
| `nix/scripts/bootstrap-dotfiles-private.sh` | `resolve_dir()` を `private_dir()` に改名（ほかの bootstrap と本文を揃える）。先頭のコメント |
| `nix/files/claude/skills/pjp-dotfiles-register-host/SKILL.md` | 新設 |
| `nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md` | dotfiles-private の入力の指し直しと、compare の読み方 |
| `nix/tests/*` | `private-hosts.nix`・`host-draft.nix`・`private-host.test.sh`・`setup-host.test.sh` を新設。`setup-local-flake.test.sh`・`local-flake-migrate.test.sh` にケースを足した |
| `nix/README.md`・`README.md`・`nix/hosts/default.nix`・`nix/lib/mk-home.nix`・ADR 002 | 今の形に揃えた |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| 各 PC の `~/.config/pjp/env` に `DOTFILES_HOST` を書く | `--host` の付け忘れは直るが、値は PC ごとの手書きのまま git に残らない |
| public の登録簿に値も書く | 実機の情報が public に出る |
| dotfiles-private を本体の flake の input にする | public の lock に private の rev が残り、public の CI が private を取れずに落ちる（ADR 015 / 016） |
| private のホストにも `local` を当てる | 雛形の `local` が同じ優先度で既定を書くので、private の値とぶつかって評価が落ちる。`mkDefault` に変えると雛形と既存の PC の移行が込み入る |
| clone が無いマシンでは入力の行を書かない | 雛形の形が PC で変わり、3-way merge が込み入る。stub なら形が同じ |
| 下書きを `local` の行の文字列から写す | 関数の形の `local`・`mkForce`・元のホストの引数を扱えない。評価した `options` から描けば、描いたものを評価し直して drvPath で確かめられる |
| 下書きを素の `mkHome` の `config` との差で描く | 既定が別の option から決まる値と、改名の旧名の alias まで書いてしまう（旧名は評価のたびに警告が出る） |
| setup が毎回 switch の手順の中で取得する | clone を取れない PC（会社の PC）で、後ろの bootstrap と合わせて警告が 2 回出る |
| bootstrap-dotfiles-private を switch の前へ動かす | 新しい PC では switch の前に gh や鍵が無く、clone できないまま setup が終わる（後ろで取り直せない） |
| `--host` で public のホストを指したら止める・値を `local` に残す | ユーザーの普段の打ち方は `--host` なし。止めると nixos-config の手順が通らない。値を残すと雛形のままにならない。警告で足りる |

## 5. 影響 (Consequences)

良くなること:

- 登録した PC は `--host` を付けなくても、そのファイルのホストで switch する（付け忘れても汎用のホストに落ちない）
- PC の値が git（private）に残り、雛形が変わっても値を移さなくてよい（登録した PC の `local` は使われない）
- 値を直して push すれば、`~/dotfiles/setup --update` 1 回で取得して switch する（取得が switch の前）
- 登録の前に、旧い形と新しい形の drvPath が同じことを確かめられる

注意が必要なこと:

- dotfiles-private の `nix/` の中身は誰でも読める `/nix/store` に入る
- 雛形の版が変わるので、全 PC で一度は移す知らせが出る
- 登録した PC では `local` の値はそのホストに当たらない。一時的に値を試すときは、dotfiles-private の作業ツリーのファイルを直す
  （`path:` 入力は commit していない変更も見える。git status に残るので戻し忘れにも気づける）
- 登録した PC で `--host <public のホスト>` を付けると、値は登録したファイルではなく雛形の既定から来る（setup が警告する）
- hostname を変えると別のホストの名前になる（setup は推測に落ち、clone に前の名前のファイルが残る）
- dotfiles-private を取れない PC（会社の PC）は、今までどおり public の型とローカル flake で動く（stub を指す）

## 6. 検証 (Verification)

- テスト: `nix/tests/private-hosts.nix`（6 件）・`nix/tests/host-draft.nix`（9 件。描いた下書きを `builtins.toFile` で import し直し、
  元のホストと drvPath が同じ・値を 1 つ変えると違う）・`nix/tests/private-host.test.sh`（18 件）・`nix/tests/setup-host.test.sh`（13 件）、
  `setup-local-flake.test.sh`（11 件）・`local-flake-migrate.test.sh`（86 件）を手元と flake の checks（サンドボックス）で流して通った
- 実機（lavie）で、`~/dotfiles` の写しと scratchpad の偽の dotfiles-private で（本物には書かずに）:
  - `inspect` は 31 秒。`draft --base pollenjp@x86_64-linux` は `local` の 4 つの値だけを描いた
  - `compare --base pollenjp@x86_64-linux` は 0（旧い形と `pollenjp@lavie` の drvPath が同じ）
  - 新しい雛形で書いたローカル flake で、`setup.sh --which-host` は `pollenjp@lavie	private`、drvPath は compare と同じ
  - 実物の `~/dotfiles/flake.nix` の写しを（本体をこの branch にして）`local-flake-migrate.sh` で移すと、元の雛形 87922f9 から衝突 1 件を
    自動で解き、登録簿の 6 ホストは drvPath が同じ、`pollenjp@lavie` は「この PC のホスト」として 1（setup が選ぶホストが変わる）
  - lavie の home-manager の世代は、この変更の作業中に（この作業の外で）別の本体から switch されていて、main と今の `local` のどのホストとも
    一致しなかった。`inspect` はそのとき「一致するホストはありません」と出す（元にするホストは setup の推測か、ユーザーに確かめる）

## 7. 移行・運用手順

PC を登録するときは、その PC で Claude Code に `pjp-dotfiles-register-host` skill を使わせる（調べる → 下書きの確認 → dotfiles-private の
branch に書く → 比べる → PR → merge 後にローカル flake を今の雛形へ移し、移した値を `local` から外す）。手で行うなら:

```sh
p=~/ghq/github.com/pollenjp/dotfiles/nix/scripts/private-host.sh
bash $p inspect                                   # 元にするホストを見つける (一致するホスト)
bash $p draft --base <ホスト>                      # 下書き (stdout)。dotfiles-private の作業ツリーの nix/hosts/<名前>.nix に置く
bash $p compare --base <ホスト> --private <作業ツリー>   # 0 なら、この登録で世代の中身は変わらない
```

merge のあと、`~/dotfiles/flake.nix` を今の雛形へ移す（`local-flake-migrate.sh prepare`。dotfiles-private の入力が clone の `nix/` を指す）。
移したあと `~/dotfiles/setup --which-host` が `<user>@<hostname>	private` を出せば、`--host` なしの `setup --update` がそのホストを当てる。
