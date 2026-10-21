# 段階 3: setup の推測をやめ、公開の登録簿から実機を外す — 設計 (TKT-267)

- チケット: [TKT-267](https://app.notion.com/p/3ff79149a66f812e9e84f1e559d8ed29)
  (dotfiles の作業)。集約は [TKT-271](https://app.notion.com/p/3ff79149a66f81b6894de060a71e6f2d)
  (集約ハブの会話。nixos-config の作業は別の子のチケット)
- 方針は 2026-10-21 にユーザーが承認した (解説動画の短尺を見たあと)。この文書はその書き写しと、実装に要る細部
- 承認のときにユーザーが決めたこと: Dev Tracker を既定で切る値は、**本体の既定を false にする** (案 A。却下した案 B は
  「本体の既定は true のまま、型のホストに false を書く」)
- 前段: [ADR 026](../../adr/026_dotfiles_private_hosts_20261020T215857JST/README.md) と
  [その設計](2026-10-20-dotfiles-private-hosts-design.md) (段階 1)。段階 2 (WSL の PC の登録) は dotfiles-private の PR で済んだ
- 関連: ADR 002 (登録簿とローカル flake)・ADR 007 (Dev Tracker の host option と local)・ADR 012 (exeExecTrace)・
  ADR 022 (1Password を WSL の外でも使う)・ADR 024 (雛形の版の印と移行)

## 背景と意図

ADR 026 で、実機のホストの定義と値を dotfiles-private の `nix/hosts/<user>@<hostname>.nix` に置き、setup が `--host` なしで
その PC のホストを選ぶようにした。段階 2 までで、ユーザーの私物の PC 2 台を登録した。残っている問題は 3 つ。

- **推測。** setup は `--host`・ローカル flake のホスト・dotfiles-private のこの PC のホストのどれも無いと、`$USER` と `uname` から
  推測する (`<user>@wsl` → `<user>@<system>`)。登録した PC でも、ローカル flake が clone の `nix/` を読んでいない
  (前の雛形・stub を指す) と、黙って型のホストへ落ちる。ADR 026 の背景のとおり、推測で型の世代になり git の署名が外れた例がある
- **実機の情報が public にある。** 登録簿に実機 3 つ (`pollenjp@wsl` (Windows のユーザー名入り)・`pollenjp@wsl-no-1password`・
  `pollenjp@laptop`) が残っている。ADR 026 の F は、実機が private に移ったら消すと決めていた
- **local の重ね方。** 雛形の `local` は登録簿の全ホストに当たり、tmp の例も `local` を渡すので、本体が定義済みの値を差し替えるのに
  `mkForce` が要る。登録した PC では `local` は使われない

ユーザーの意図 (TKT-267): setup が推測で公開の登録簿のホストを選ぶのをやめ、PC の値は dotfiles-private の登録 (登録した PC) か、
ローカル flake に足した `tmp` (登録していない PC) のどちらか 1 か所にだけ書く形にする。

## ゴール

1. setup の推測をやめる。決める順は `--host` (`DOTFILES_HOST`・メニューの `h`) → ローカル flake のホスト → dotfiles-private の
   この PC のホスト。どれにも当たらなければ止めて (終了コード 1)、3 つの道 (登録する・`tmp` を足す・`--host <型>`) を案内する
2. 雛形から `local` を外す。`homeConfigurations` は 登録簿 (local なし) → dotfiles-private → tmp を重ねるだけにする。tmp の例は
   値を `mkHome` の引数と `modules` に直に書く (`mkForce` の要らない形)
3. Dev Tracker を既定で切る: 本体の `dotfiles.claude.devTracker.enable` の既定を false にし、使う所で true を書く
4. 公開の登録簿から実機 3 つを外す。テストと CI の確かめは作り物のホストで残す
5. 新しい PC の初回の流れを README と skill に書く
6. 決定を ADR 027 に残し、ADR 002・007・022・026 の該当箇所に注記を足し、README・`nix/README.md`・skill を今の形に揃える
7. nixos-config (private の repo) の README と `docs/architecture/README.md` の `--host pollenjp@laptop` を直す (別の repo・別の PR)

## 非ゴール

- まだ登録していない PC の登録 (その PC で `pjp-dotfiles-register-host` を使う。TKT-269)
- 各 PC の `~/dotfiles/flake.nix` を新しい雛形へ移すこと (各 PC で `pjp-dotfiles-local-flake-migrate` を使う)
- `lib.hostsWith` を消すこと (前の雛形のローカル flake が呼ぶ。全 PC が移ったあとの別の話)
- clone ができたあとに stub から clone へ入力を指し直すのを、setup が自動ですること (ADR 026 のまま。skill で確認を取って行う)
- setup が `~/dotfiles/flake.nix` を自動で書き換えること
- WSL の型のホストを足すこと (「こちらの判断」の 1)
- nixos-config の ADR を書き換えること (当時の記録として残す)

## アンチゴール (技術的に動いても失敗とみなすもの)

- どのホストにも当たらない PC で、setup が黙って何かのホストで switch する
- 取得 (`private-fetch`) で届いた登録や、この実行で作ったローカル flake を、同じ実行で拾えずに止まる
- Nix がまだ無い新しいマシンで、Nix を入れてから「ホストが決まらない」と止まる
- 前の雛形 (`local` と `hostsWith` を持つ ADR 007・ADR 026 の版) のローカル flake が、新しい本体で評価できなくなる
- public の repo (文書・テスト・skill の例・PR の本文) に、PC の private の値 (hostname・Windows のユーザー名) が入る
- CI が WSL・1Password・windowsFiles・exeExecTrace の組み合わせを build しなくなる
- sandbox の検証 (CI の「warnings が空」) が Dev Tracker の経路を通らなくなる
- 分かりにくいエラーで止まる (例: 登録してあるのにローカル flake が clone を読んでいないとき、直し方を出さずに止まる)

## 制約

- setup.sh はホストの判定を Nix のインストールの前にも行う。nix と jq に頼らず、bash 3.2 (macOS) でも動かす
- 雛形の heredoc を直すと雛形の版の印が変わり、各 PC に移す知らせが出る (ADR 024)。`local-flake-migrate.sh` は履歴の雛形を
  描いて 3-way merge する
- 前の雛形のローカル flake は `dotfiles.lib.hostsWith [ local ]` を呼ぶ
- 本体は public。テストの値は作り物にする (ユーザー名・Windows のユーザー名・hostname)
- flake の checks は Nix のサンドボックスで流れる (ネットワークも本物の dotfiles-private も無い)

## 決まったこと

### 1. setup のホストの決め方 (推測をやめる)

| 順 | 対象ホスト | `host_source` |
| --- | --- | --- |
| 1 | `--host` (`DOTFILES_HOST`・メニューの `h` も) | `option` / `env` / `menu` |
| 2 | ローカル flake が定義しているホスト (tmp) | `local` |
| 3 | dotfiles-private に登録したこの PC のホスト (clone に `nix/hosts/<名前>.nix` があり、ローカル flake の入力がその clone の `nix/` を指すとき) | `private` |
| — | どれも無ければ止める | — |

- `detect_host` の推測 (3 番目の段) と `host_source=guess` を消す。推測にだけ使っていた関数は消し、ほかでも使うもの (`is_wsl` など) は残す
- **止める時機。** 自動で決める対象ホストは、今も `private-fetch` と `local-flake` の手順のあとに決め直している (`redetect_host`)。
  - 決まらないときに止めるのは、その決め直しのあと (switch の手順の頭。`step_switch` は今も `ensure_host_registered` を呼んでいる)
    にする。取得で届いた登録と、この実行で作ったローカル flake を拾うため
  - ただし、決め直しで決まりようがないとき (Nix が入っていない新しいマシン、dotfiles-private の clone が無いとき、または
    `private-fetch` も `local-flake` も選ばれていないとき) は、今と同じく execute の前に止める。Nix を入れてから止めない。
    clone が無ければ決め直しで決まることは無く、Nix のある既存のマシンで `--new-machine` を打ったときに、`preflight-unlink` が
    home-manager の symlink を外してから switch で止まる (シェルの設定が消えたままになる) のを避けるため
- `--which-host` は、決まらなければ今と同じく終了コード 1 で、下の案内を出す
- **止めるときの文。** 対象ホストが決まらないことと、選べる道 3 つを出す:
  1. この PC を dotfiles-private に登録する (Claude Code で `pjp-dotfiles-register-host`。登録の前の 1 回は 3 で当てる)
  2. `~/dotfiles/flake.nix` に tmp を足す (dotfiles-private を読めない PC。tmp は既定の対象ホストになる)
  3. `--host <型>` を付ける (型の名前を並べる。登録簿のホストから `sandbox` を除いたもの)
  - clone にこの PC のファイルがあるのにローカル flake が読んでいない (入力が無い・stub を指す) ときは、それを先に出し、
    今の雛形へ移す案内 (`local-flake-migrate.sh prepare` と skill) を出す。今は `--host` で指したときだけ出している
- 推測にかかわる表示を消す・直す: `post_notes` の「対象ホストは推測の … になりました」、`redetect_host` の case の `guess`、
  `host_source_label`、usage の説明、メニューの見出し (未判定)、`private-host.sh inspect` の「setup が --host なしで選ぶホスト」
  (決まらないときは「決まらない (setup は止まる)」のように出す)
- `DOTFILES_HOST` (`~/.config/pjp/env` に書く) は今までどおり効く

### 2. ローカル flake の雛形

- `local` を消し、`homeConfigurations = dotfiles.homeConfigurations // privateHosts // { … };` にする
  (`dotfiles.homeConfigurations` は `hostsWith [ ]` と同じもの)
- tmp の例 (コメント) は `local` を渡さず、値を `mkHome` の引数に直に書く。どれも option の既定 (優先度 1500) より強いだけの普通の
  定義なので `mkForce` は要らない。例に並べるもの:
  - `username`・`system`
  - `wsl` (`enable`・`windowsUserName`・`windowsFiles.enable`・`exeExecTrace.enable`) と `onePassword.enable`
  - `claude` (`devTracker.enable = true`・`gitViaGh.enable`・`notion.profile`・`notion.routes`・`notion.override`・
    `videoOffer.autoStart.enable`)
  - `modules` (`dotfiles.ccPages.port` など、`mkHome` の引数に無い option)
  - 今の `local` にある説明 (反映は `setup --update` か switch か、など) は tmp の例の該当行へ移す
  - Windows のユーザー名の例は作り物にする (今の雛形の値は登録簿の実機の値)
- 冒頭のコメント `home-manager switch --flake ~/dotfiles#pollenjp@wsl` は `#<ホスト>` にする
- 雛形の版の印が変わる。setup の「移す」知らせは今の仕組みのまま
- `setup-local-flake.sh` が既存のファイルに出す警告 (`hostsWith` が無い・`notion.profile` が無い) と、`setup.sh` の `post_notes` の
  同じ grep は、新しい雛形が持たない語を探しているので外す
- `local-flake-migrate.sh`:
  - ADR 026 の版から新しい版へ移すと `local` の塊が消える。登録した PC の `local` は登録の手順 6 で雛形の既定に戻してあるので、
    3-way merge は衝突しない見込み。手元で値を書いたままの `local` は衝突として残る (値を登録か tmp へ移すのは skill の判断)
  - compare は今 `sandbox` を比べない (`local` が sandbox にも当たり `notion.profile` がぶつかるため)。新しい雛形ではその理由が
    無くなるが、比べるようにするかは実装に任せる
- `local` の行を読む `private-host.sh` (`inspect` の表示と `draft` の notes) は、`local` の無い flake でも動くこと

### 3. Dev Tracker の既定 (ADR 007 を改める)

- `nix/home/options.nix` の `dotfiles.claude.devTracker.enable` の既定を false にし、説明を直す (「雛形は false を書いている」
  「登録簿のホストを直接指すときはこの既定 (true)」の段落)
- `sandbox` に `claude.devTracker.enable = true;` を足す (`notion.profile = "personal"` はそのまま。CI の「warnings が空」の確かめが、
  今のまま Dev Tracker の経路を通る)
- dotfiles-private に登録したファイルは true を明示している。tmp の例は true を書く行を見せる
- 型のホストを `--host` で当てた PC は Dev Tracker が off になる (今の雛形の `local` と同じ振る舞い)
- `private-host.sh draft` (`nix/lib/host-draft.nix`) は「option の既定より強い定義」を描くので、既定を変えると下書きの出方が変わる。
  テストの fixture (`nix/tests/fixtures/host-draft/`) を直す
- ADR 007 の決定 A (既定は true) と C (`local` が false を書く) は ADR 027 が改める

### 4. 公開の登録簿・テスト・CI

- `nix/hosts/default.nix` から `pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop` を消す。残るのは型 3 つ
  (`pollenjp@x86_64-linux`・`pollenjp@aarch64-linux`・`pollenjp@aarch64-darwin`) と `sandbox`
- 先頭のコメントを今の形に直す (実機は dotfiles-private、登録していない PC の差分は tmp。`local` へ誘導していた所)
- `nix/tests/one-password.nix`: 登録簿の実機を見ている所を、作り物の `mkHome` で 4 通り (非 WSL・1Password 無し / 非 WSL・有り /
  WSL・無し / WSL・有り) を作って見る形にする
- CI の build: 今は登録簿の全ホストを build し、exeExecTrace を入れたホストは `pollenjp@wsl` だけ (ADR 012)。
  WSL・1Password・windowsFiles・exeExecTrace を入れた作り物のホストを flake の checks に足して build する。
  `homeConfigurations` には出さない (setup の `list_hosts` に出ない・`--host` で選べない)
- ほかに実機の名前を使っているテスト・fixture があれば作り物にする

### 5. 新しい PC の初回と、skill

- README (`nix/README.md` の手順 0 と新しいマシンの節) に書く流れ:
  - dotfiles-private を読める PC: `setup --host <型>` で 1 回当てる (Nix・gh・clone が揃う) → Claude Code で
    `pjp-dotfiles-register-host` → PR を merge → ローカル flake を移す (stub から clone へ指し直す) → `setup --update` (`--host` なし)
  - 読めない PC: `~/dotfiles/flake.nix` に tmp を書いてから setup を流す
- `pjp-dotfiles-register-host`:
  - 型を元にする登録 (新しい PC): WSL の PC なら `wsl` の値を足す (Windows のユーザー名は `inspect` の値。windowsFiles・
    exeExecTrace・onePassword はユーザーに聞く)。compare は足した分だけ 1 になる
  - 元にするホストが段階 3 で登録簿から消えている PC (`pollenjp@wsl` などで当てていた PC): 段階 3 の前の本体を写して
    draft・compare する (前提の「本体を写す」と同じ形で `git archive <段階 3 の前の rev> nix`)。rev の引き方も書く
  - 手順 6 の 4 (移した値を外す): 新しい雛形では `local` が無いので、tmp に書いていた値を外す話になる。前の雛形の PC は今までどおり
  - 推測にかかわる記述 (`inspect` の「推測」・候補の例) を直す
- `pjp-dotfiles-local-flake-migrate`: 段階 3 の雛形へ移すときの `local` の塊の扱い (登録した PC は雛形どおり消す・値が残る PC は
  tmp か登録へ移す) と、compare の読み方を足す
- `nix/pjp-env/dotfiles.txt` の `DOTFILES_HOST` の説明 (取り得る値) を直す

### 6. 文書

公開の repo に載る値の範囲 (builder check の問いへのこちらの判断):

- 新しく書くもの (この spec・ADR 027・PR の本文・commit) と、今回触るファイルには、実機の値 (Windows のユーザー名・hostname) を
  入れない。今回触るファイルの中に既にある実機の値は、作り物か一般の書き方 (`<ホスト>`・`<user>@<host>` など) に替える
  (例: `nix/home/options.nix` の `example`・`nix/README.md` の herdr の節の例)
- ADR の本文・過去の plans / specs・出力した図は当時の記録なので書き換えない (注記を足す ADR でも本文は替えない)
- git の履歴は書き換えない (force push は取り消せない。消したいなら別の判断としてユーザーが決める)
- Notion のチケットの URL は、slug に hostname が入ることがあるので、id だけの形 (`https://app.notion.com/p/<id>`) で書く

- ADR 027 を新しく書く (段階 3)。ADR 002 (`local` の重ね方)・007 (Dev Tracker の既定と `local`)・026 (D の推測と F の段階 3) を
  改めたことを書き、それぞれの ADR の該当箇所に注記を足す (この repo の慣習に合わせる)
- ADR 022 の「`--host pollenjp@laptop` で当てる」の 2 か所 (注意と移行の手順) に、段階 3 の後は登録したホストを `--host` なしで
  当てる、という注記を足す
- `README.md`・`nix/README.md`・`win/README.md`・textbook (`docs/adr/001_*/textbook/`): 推測・登録簿の実機・`local` の記述を
  今の形にし、消えたホスト (`pollenjp@wsl` など) を打つコマンド例を `<ホスト>` か型にする (段階 3 の後に打つと止まるため)
- この spec は `docs/superpowers/specs/2026-10-21-dotfiles-private-hosts-stage3-design.md` に置く

### 7. nixos-config (別の repo・別の PR・別のチケット)

- README の 3 か所 (初回の `--steps switch --host pollenjp@laptop --backup` と「`--host` は省かない」の段落・1Password の手順 4・
  日常) を直す:
  - 日常: `~/dotfiles/setup --update` (`--host` なし。dotfiles-private に登録したホストを setup が選ぶ)
  - 初回 (入れ直し): clone がまだ無いので、1 回目は型 (`--host pollenjp@x86_64-linux`) で当て、bootstrap が dotfiles-private を
    clone したあと、ローカル flake を移して (stub から clone へ)、`setup --update` で登録したホストに切り替える
  - 1Password の手順 4: `~/dotfiles/setup --update` (署名は登録したホストに入っている)
  - 「本体を直接指すと `local` が外れる」の注意は、本体には登録したホストが無いことに直す
- `docs/architecture/README.md` の `dotfiles/nix#pollenjp@laptop` を直す
- nixos-config の ADR は当時の記録として書き換えない
- dotfiles の段階 3 と独立に merge できる (その PC はもう登録済みで、ローカル flake も移してある)

## テスト

- `setup-host.test.sh`:
  - 推測のケース (2・12 など) を「決まらず止まる」に直す。WSL でも `<user>@wsl` を選ばない
  - 止める文に 3 つの道が出る。clone にこの PC のファイルがあるのにローカル flake が読んでいないときは、移す案内が出る
  - 決め直し (10・11) は、最初にホストが決まっていなくても execute の前に止まらず、同じ実行で拾う
  - Nix が無いマシン、または決め直しの手順が選ばれていないときは、execute の前に止まる
  - 今のテストは `/proc/version` を偽っていないので、WSL の上で流すと推測が `<user>@wsl` に寄る見込みがある (未検証)。
    推測を消せば当たらなくなるが、WSL で流して確かめる
- `setup-local-flake.test.sh`: 新しい雛形に `local` と `hostsWith` が無い。tmp の例のコメントを外したものが評価できる (`mkForce` なし)。
  既存のファイルへの警告 (`hostsWith`・`notion.profile`) が出ない
- `local-flake-migrate.test.sh`: ADR 026 の版 (`local` が既定のまま) から新しい版へ、衝突なしで移る。`local` に値が残っていれば
  衝突として残る
- `private-host.test.sh`: `local` の無い flake で `inspect`・`draft` が動く。`inspect` の「setup が選ぶホスト」で決まらないときの表示
- `one-password.nix`: 作り物の 4 通り
- `host-draft.nix`: `collect` は値ではなく優先度で拾うので、既定を false にしても今の fixture の出力は変わらない見込み。
  「既定と同じ値も描く」の確かめは `devTracker.enable = false` を明示した側で保つ
- 既定の true に頼っているテスト (`claude-notion.nix`・`claude-video-offer.nix` など) は、`devTracker.enable = true` を明示する
- tmp の例が評価できることの確かめ: サンドボックスの scriptTest には nix が無いので、例を fixture として commit し、雛形の本文との
  一致を bash で、評価を Nix の check で確かめる、などの形 (実装に任せる)
- 新しい check: WSL の作り物のホストの build (x86_64-linux の checks にだけ置く。macOS のランナーで x86_64-linux を build しない)
- `nix flake check --all-systems --no-build` と CI が通る

## こちらの判断 (ユーザーに確かめずに決めたもの)

1. **WSL の型は作らない。** `wsl.enable` だけで増えるのは who-is-asking の 1 つで、ほかは 1Password・windowsFiles・exeExecTrace と
   組みになったときに入る。新しい WSL の PC は初回を `pollenjp@x86_64-linux` で当て、登録のときに `wsl` の値を足す
2. **`lib.hostsWith` は残す。** 前の雛形のローカル flake が評価できるように。消すのは全 PC が移ったあと
3. **止める時機は決め直しのあと。** 取得で届いた登録を同じ実行で拾う。決め直しで決まりようがないときと新しいマシンは、execute の前
4. **ADR は 027 を新しく書く。** 026 の段階 3 を行うだけでなく、推測・`local`・Dev Tracker の既定まで決めるので、026 に足さずに分ける
5. **nixos-config の ADR は書き換えない。** README と architecture の運用手順だけ直す
6. **stub から clone への指し直しは自動にしない。** ADR 026 のまま、skill で確認を取って行う
7. **merge の順。** 段階 3 は、登録した PC のローカル flake を移したあとに merge する (推測が無くなると、移していない PC は止まる)。
   まだ登録していない PC は、段階 3 の merge の前に登録すれば止まらずに済む。止まっても案内が出る
8. **公開の repo に載る値は、新しく書くものと今回触るファイルだけ守る (builder check)。** ADR の本文・過去の plans / specs・
   git の履歴は書き換えない。全部を消すのは作業量も意味も別の話 (履歴に残るので、秘匿が目的なら履歴の書き換えが要る)
9. **execute の前に止める条件に「clone が無い」を足す (builder check)。** 足しても、成功するはずの実行を失わない
10. **消えたホストを打つ運用の文書 (textbook・`win/README.md`) も直す (builder check)。** 段階 3 の後に打つと止まるため

## 実装に任せること

- `setup.sh` の止める所の形 (関数の分け方・文の言い回し・案内に型の名前を並べる形)
- WSL の作り物のホストの名前と、checks の名前・置き場所
- `one-password.nix` の作り物の組み立て
- `local-flake-migrate.sh` の compare で `sandbox` を比べるようにするか
- README の節の並びと言い回し
