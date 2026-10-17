# ADR: `~/.config/pjp/env` の頭に、受け取る環境変数の一覧を setup が書き直す欄として置く

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-17 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-17 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-203](https://app.notion.com/p/config-pjp-env-setup-3fc79149a66f81c39cddefbcd4ccbb76) |
| 運用手順 | [`nix/README.md`「マシンローカルの環境変数」](../../../nix/README.md#マシンローカルの環境変数-configpjpenv) |

---

## 1. 背景 (Context)

### やりたかったこと

- Notion の Dev Tracker の personal に API キーで書くための変数名 (`PJP_NOTION_TOKEN_PERSONAL`) を思い出せず、
  skill の SKILL.md を読み直すことになった
- dotfiles と skill が受け取る環境変数を、値を書く場所である `~/.config/pjp/env` を開いたときに読めるよう、
  ファイルの頭にコメントで並べたい。形は 1 変数につき「何のための変数か。取り得る値: …。」の行と
  `# <名前>=xxxxxx` の行
- dotfiles や skill の側で変数が増えたり説明が変わったりしたら、`~/dotfiles/setup --update` で文言を追従させたい
- すでに書いてある値は変えたくない

### 設計を縛る事実

#### 1. このファイルには秘密の値が入っていて、今の setup は 2 回目以降は中身に触らない

`bootstrap-local-env.sh` は、無ければテンプレート (全行コメント) を置き、在れば中身に触らずパーミッションだけを
600 へ締める。中身を書き換えるのは、この約束を改めることになる。

```sh
# nix/scripts/bootstrap-local-env.sh (この ADR の前)
# ## 中身は絶対に上書きしない
#
# 実際の API キーが入っているファイルなので、既に在るときは何も書かない。
# 作るのは初回だけ。
```

#### 2. ローダは「識別子で始まる `KEY=` の行」だけを読む

bash (`bash.nix` の `initExtra`)・fish (`fish.nix` の `interactiveShellInit`)・Notion の宛先の resolver
(claude-skills の `notion_profile.py`) の 3 つが、同じ規則でこのファイルを読む。`#` で始まる行は 3 つとも
読み飛ばし、同じ名前が 2 度あれば後の行が勝つ。

```sh
# nix/home/modules/bash.nix
          if [[ "''${_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # shellcheck disable=SC2163
            export "''${_line}"
          fi
```

```python
# claude-skills skills/pjp-notion-profile/scripts/notion_profile.py
ENV_LINE_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
```

#### 3. きっかけの変数を読むのは dotfiles ではなく claude-skills

`PJP_NOTION_TOKEN_<名前>` を読むのは claude-skills (private) の `pjp-notion-profile` の resolver で、
dotfiles (public) の script ではない。ほかに `WHISPER_MODEL` (`pjp-video-explainer-pictogram`) のように、
skill だけが読む変数もある。

#### 4. setup の中では、claude-skills の取得がこの手順より先に走る

bootstrap の実行順は、ヘッダの `# order:` (無ければ 50)、同じなら名前の辞書順。`bootstrap-claude-skills.sh`
(claude-skills を pull して `~/.claude/skills/` へ symlink する) も `bootstrap-local-env.sh` も `order` を
書いていないので、前者が先に走る。dotfiles の skill (`nix/files/claude/skills/`) は、その前の switch で
`~/.claude/skills/` に置かれている。

#### 5. この PC のファイルは、作ったときのテンプレート 10 行と値の 1 行

テンプレートは 7aaaba6 で足してから一度も変わっていない (この PC のファイルは行の種類だけを数えて確かめた。
中身は見ていない)。

## 2. 決定 (Decision)

### A. ファイルの頭に、印で囲んだ「dotfiles が書く欄」を置く

```
# >>> dotfiles が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>
#
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# … (形式の決まり)
#
# ---- dotfiles ----
#
# setup が対象にするホストを決めるための変数 (--host と同じ)。取り得る値: …。
# DOTFILES_HOST=xxxxxx
#
# ---- skill: pjp-notion-profile ----
#
# …
#
#####################################################
# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<
PJP_NOTION_TOKEN_PERSONAL=ntn_…
```

- 印の始まりの行は `# >>> dotfiles`、終わりの行は `# <<< dotfiles` で始まる。印として見るのはこの頭だけで
  (行末の CR と、1 行目の頭の UTF-8 BOM は外して見る)、後ろの日本語の文言は変えてよい。別の文字コードで
  保存されても印を見失わない
- 印の間 (印の行を含む) が setup のもの。すべての行が `#` で始まるので、3 つのローダはどれも欄を読まない
- 印の外 (始まりより上と、終わりより下) はユーザーのもの。setup は 1 バイトも変えない
  (CRLF の行・末尾に改行の無い行・UTF-8 でない文字も、そのまま)
- 欄の中身は、始まりの印・形式の決まり・一覧 (出どころごとの節)・`#####` の行・終わりの印の順

### B. `bootstrap-local-env.sh` が `setup --update` のたびに欄を書き直す

| ファイルの様子 | すること |
| --- | --- |
| 無い | 欄だけのファイルを作る (600) |
| symlink・普通のファイルでない・読み書きできない・NUL を含む (UTF-16 など)・`env.bak` がディレクトリ | 書かずに warn で知らせ、exit 0 |
| 印が 1 組 (始まりが 1 つ、終わりが 1 つ、始まりが先) | 印の間を新しい欄に替える。印の外は 1 バイトも変えない |
| 印の間に、空でなく `#` で始まらない行がある | その行を元の順のまま、終わりの印のすぐ下へ移す。移した変数名を warn で知らせる |
| 印が無く、頭の 10 行が今のテンプレートと同じ | その 10 行を欄に替え、11 行目からは 1 バイトも変えない |
| 印が無く、それ以外 | 欄を頭に足すだけ。今の行は 1 行も消さない |
| 印が壊れている (片方だけ・どちらかが 2 つ以上・終わりが先) | 書かずに、印の行番号と直し方を warn で知らせ、exit 0 |
| 書き上がりが今と同じ | 何も書かない (更新時刻も変えない) |

- 欄の中の、`#` で始まらない行を移す先を「終わりの印のすぐ下」にするのは、欄の下の行より前に置くことで、
  後の行が勝つ順を変えないため
- テンプレートとの比べ方は、行末の CR を外した 1 行ずつの完全一致。1 文字でも違えば消さない
- このファイルのことで setup は止めない。書けないとき (一時ファイルが作れないなど) も warn で知らせて exit 0
- group と other の権限があれば外す (644 なら 600 にする。中身を書かないときも、書かずに抜けるときも、symlink の
  先も)。600 より狭い権限 (400・000 など) は広げない (G)

### C. 書くときは前の版を 1 つだけ残し、一時ファイルから入れ替える

- 書き上がりが今と違えば、今のファイルを同じディレクトリの `env.bak` (600) へ写してから、同じディレクトリの
  一時ファイル (600) に書いて `mv` する。途中で落ちても、半端なファイルは残らない
- `env.bak` は 1 世代だけ。欄の中に手で書いたコメント (救わない。下の D) の逃げ場で、世代を重ねないのは
  秘密の値の写しを増やさないため
- 画面に出すのは「作った」「書き直した」「最新だった」、触れなかった行の数、移した変数名だけ。値と、
  ユーザーの行そのものは出さない

### D. 欄の中に手で書いたコメントは救わない

欄の中の `#` で始まる行は、一覧の文言か手で書いたコメントかを見分けられない。前回書いた欄の記録を持てば
見分けられるが、欄の見出しで「ここには書かない」と言い、`env.bak` に残すことで足りるとした。

### E. 一覧の文言は、変数を読むコードの隣に置く

| 出どころ | ファイル | 欄の中の節の見出し |
| --- | --- | --- |
| dotfiles の script が読む変数 | dotfiles の `nix/pjp-env/dotfiles.txt` (script のいる checkout から読む) | `# ---- dotfiles ----` |
| skill が読む変数 | skill のディレクトリの `pjp-env.txt` (`~/.claude/skills/*/pjp-env.txt` から集める) | `# ---- skill: <ディレクトリ名> ----` |

- 並びは dotfiles が先、skill はディレクトリ名の順 (C ロケール)
- `pjp-env.txt` は素のテキストで書く。setup が各行の頭に `# ` を付け (空行は `#`)、先頭と末尾の空行は落とす。
  空 (空行だけ) なら節を作らない
- 頭に `# ` が付くので、断片に `FOO=bar` と書いても欄の中では `# FOO=bar` になり、生きた変数は生まれない
- 次の断片は欄に入れずに warn で知らせる
  - 読めない断片
  - `# ` を付けた行が印として読まれてしまう断片 (`>>> dotfiles` や `<<< dotfiles` で始まる行を持つもの)
  - 行の途中に制御文字 (タブを除く) か U+0085・U+2028・U+2029 を持つ断片。claude-skills の resolver は
    Python の `str.splitlines()` で行を切り、CR・`\v`・`\f`・`\x1c`〜`\x1e`・U+0085・U+2028・U+2029 でも行を分ける。
    bash と fish からは `#` で始まる 1 行でも、resolver からは欄の中に生きた `KEY=` の行が生まれる
- 1 変数の書き方は「何のための変数か。取り得る値: …。」の行と `<名前>=xxxxxx` の行 (値が決まっているなら
  その値)。変数の間は空行で区切る。ここに書くと困る変数は、最後に「ここには書かない」の行でまとめる
- skill の文言は skill と一緒に届く。claude-skills を直して push すれば、各 PC の次の `setup --update` で欄に出る。
  その PC に無い skill の変数は欄にも出ない

### F. 一覧に載せる変数

基準は「このファイルに書いて、そのマシンで常に効かせる意味があるか」。

| 扱い | 変数 |
| --- | --- |
| 載せる (例の行つき) | `PJP_NOTION_TOKEN_<名前>` (pjp-notion-profile)・`WHISPER_MODEL` (pjp-video-explainer-pictogram)・`DOTFILES_HOST`・`DOTFILES_LOCAL_DIR`・`DOTFILES_PRIVATE_DIR`・`CLAUDE_SKILLS_DIR`・`CC_PAGES_DIR` (dotfiles) |
| 「ここには書かない」の行でだけ触れる | `NOTION_API_TOKEN` (書くと、どの repo でもその token が勝つ)・`USE_LINUX_SSH` (常に効くと `ssh-add` も Linux 側になり、git の署名鍵が並ばない)・`DOTFILES_MIN_RELEASE_AGE_DAYS` と `FLAKE_MIN_RELEASE_AGE_DAYS` (常に効くと flake.lock の遅延が外れたままになる) |
| 載せない | 1 回だけコマンドの前に付ける上書き (`DOTFILES_BACKUP_EXT`・`DOTFILES_ALLOW_ANY_PATH`・`NIX_INSTALLER_ARGS` など)、devShell・テスト・CI が自分で張る変数 (`*_REEXEC`・`PJP_D3JS_*`・`CHROMIUM_BIN`・`VOICEVOX_ENGINE_BIN`・`FAKE_*` など)、ほかの道具の変数 (`GHQ_ROOT`・`GITHUB_TOKEN`) |

### G. 方針の承認のあとに決めたこと (こちらの判断)

設計を読んだ reviewer が「自分で決められる」と挙げた点を、次のように決めた。

- 1 行目の頭の UTF-8 BOM は、印と古いテンプレートを見分けるときに外す (A)。Windows のエディタで BOM 付きで
  保存し直されると、始まりの印を見失って「印が壊れている」の warn が毎回出るため。書き直した欄の頭に BOM は付かない
- 行の途中に制御文字を持つ断片は入れない (E)。claude-skills の resolver から見て欄の中に生きた変数が生まれるのを、
  本物の `notion_profile.read_env_file` で確かめた (`# x\rPJP_NOTION_TOKEN_PERSONAL=…` の行から変数が 1 つ読まれる)。
  UTF-8 として読めない断片は、resolver が置き換え文字にして読むだけで行は分けないので、止めない
- `CLAUDE_SKILLS_DIR`・`CC_PAGES_DIR` (clone の置き場所) も、`DOTFILES_PRIVATE_DIR` と同じ基準で載せる (F)
- 権限は「600 でなければ 600」ではなく「group と other の権限を外す」にする (B)。ユーザーが自分で 400 や 000 に
  狭めたファイルを、毎回 600 へ広げないため。644 のような普通の場合はどちらでも 600 になる
- 書き上がりのレビューで出た次の点も、同じ PR で直す。`=` だけで終わる行 (KEY= を付けずに貼ったパディング付きの
  base64 の値) は、移した変数名として出さない (値そのものを出すことになる)。名前に改行などを含む skill のディレクトリは
  節を作らない (見出しの行から生きた行が生まれる)。頭に BOM のある断片は BOM を外して読む
- dotfiles の断片は `nix/files/` ではなく `nix/pjp-env/` に置く (E)。`nix/files/` は store が配るファイルの置き場所で、
  `dotfiles.txt` は store に置かず bootstrap が checkout から読むため (`nix/vulnxscan-whitelist.csv` と同じ扱い)
- この PC の本物の `~/.config/pjp/env` は、merge の前には書き換えない。確かめるのは写しで行い (6)、本物は merge の
  後にユーザーが流す `setup --update` で書き換わる

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/bootstrap-local-env.sh` | 「無ければ作る」から「欄を書き直す」へ。頭のコメントの約束 (中身は上書きしない) も改める |
| `nix/pjp-env/dotfiles.txt` | 新規。dotfiles の script が読む変数の一覧 |
| `nix/tests/bootstrap-local-env.test.sh`・`nix/flake.nix` | 偽の HOME と checkout で欄の書き直しを確かめる check (`bootstrap-local-env-test`)。repo の `dotfiles.txt` も渡して、欄に入れられることを確かめる |
| `nix/README.md` | 「マシンローカルの環境変数」の節 (2 回目以降の振る舞い・欄・断片の書き方)、手順の表、ファイルの木 |
| `nix/files/claude/skills/README.md` | skill が環境変数を受け取るときの `pjp-env.txt` の書き方 |
| `docs/adr/README.md` | 一覧に 020 を足す |
| claude-skills の `skills/pjp-notion-profile/pjp-env.txt`・`skills/pjp-video-explainer-pictogram/pjp-env.txt`・`skills/README.md` | 別の PR。断片 2 つと書き方 |

## 4. 検討した代替案

### 値の行 (`KEY=VALUE`) を抜き出し、全体を書き直してから末尾へ書き戻す

単独では採らない。一覧のコメントと手で書いたコメントを見分けられないので、コメントは全部捨てることになる。
コメントアウトして休ませた token (`#PJP_NOTION_TOKEN_WORK=…`) も消え、秘密の値なので失うと戻せない。
欄の中に書いてしまった値を救う保険としてだけ、この考え方を使う (B の表の 4 行目)。

### 書いてよい行を印で区切るだけ (欄の中の値を救わない)

採らない。欄の中に書いてしまった値が、次の `setup --update` で黙って消える。

### 一覧を dotfiles に 1 枚で持つ

採らない。きっかけの `PJP_NOTION_TOKEN_<名前>` を読むのは claude-skills なので (事実 3)、skill の変数を変える
たびに 2 つの repo を直すことになり、文言が古びる。その PC に無い skill の変数まで並ぶ。

### 一覧を別のファイル (`~/.config/pjp/env.example` など) に置き、`env` には触らない

秘密の値に触れる危険は無くなるが、値を書くときに開くファイルで読みたい、という目的から外れるので採らない。

### 前回書いた欄を記録し、欄の中に手で書いたコメントも救う

ADR 018 のように書いた記録を持てば見分けられるが、`env.bak` で足りるので採らない (D)。

### 印を日本語の文言ごと見分ける

採らない。文言を直すたびに古い印を見失い、Windows のエディタで別の文字コードで保存されたときも見失う。
頭の ASCII だけを見る (A)。

## 5. 影響 (Consequences)

### 良くなること

- 値を書くときに開くファイルで、書ける変数とその意味が読める
- skill に変数を足した PR が `pjp-env.txt` も足せば、各 PC の欄に届く
- 欄に書き間違えた値は欄の下へ移るので、消えない

### 注意が必要なこと

- 中身を書き換えない、という今の約束を改める。書き換えるのは欄だけで、欄の外は変えない
- 欄の中に手で書いたコメントは、次に欄が変わったときに消える (`env.bak` に 1 世代だけ残る)
- `env.bak` は値の写しなので、`env` と同じく 600 で置く
- 印を手で壊すと、直すまで欄は古いまま (warn で知らせる)
- skill の変数の文言は、その skill の repo の `pjp-env.txt` を直さないと変わらない。コードと一緒に直す

## 6. 検証 (Verification)

- `nix build ./nix#checks.x86_64-linux.bootstrap-local-env-test` (29 件)。何を確かめるかはテストの先頭の
  「## 確かめること」。同じテストを GNU の bash 3.2.57 と one-true-awk 20260426 (macOS の awk と同じ系統) でも流し、
  29 件通った
- shfmt・shellcheck・nixfmt・`check-test-headers.sh`・`check-test-grep-q.sh`・`warn-helpers-test` (97 件)
- `./nix/scripts/verify.sh`: flake の評価・使い捨ての HOME への activate・冪等性は通った。最後の段 (`nix/files/` に
  `dotfiles/` への参照が無いか) は、main にも既にある 11 件で落ちる (この変更で件数は変わらない)
- 本物の `notion_profile.read_env_file` (claude-skills) に、制御文字を含む断片を入れて組んだ欄を読ませ、欄から
  読まれる変数が 0 件であることを確かめた。制御文字を含む行を欄の外に直接書くと 1 件読まれる (この穴を E で塞いだ)
- この PC の `~/.config/pjp/env` の写し (使い捨ての 700 の dir に 600 で写す) に流し、テンプレートの 10 行が欄に
  替わり、残りの 1 行がバイトで同じ・ローダが読む行が 1 行のまま・`env.bak` が元とバイトで同じ (600)・2 回目は
  「最新」で何も書かない、を値を画面に出さずに確かめた。本物は書き換えていない
- 本物の `~/.claude/skills` から使い捨ての `XDG_CONFIG_HOME` へ欄を組み、`pjp-notion-profile` と
  `pjp-video-explainer-pictogram` (claude-skills の PR) の節が警告なしに入ることを確かめた
- 書き上がりを別の reviewer が読み、指摘 (書かずに抜けるときに権限を締めない・`=` だけで終わる行を名前として出す
  ほか) を G のとおり直した

## 7. 移行・運用手順

### この PC・ほかの PC

```sh
~/dotfiles/setup --update
```

印の無い今のファイルは、頭のテンプレートが欄に替わる。テンプレートを手で直していた PC では、テンプレートを
残したまま欄が頭に足されるので、要らなければ欄の下に残った古いテンプレートを手で消す。

### 変数を足すとき

- dotfiles の script が読む変数は `nix/pjp-env/dotfiles.txt` に足す
- skill が読む変数は、その skill のディレクトリの `pjp-env.txt` に足す (無ければ作る)。書き方は
  [`nix/files/claude/skills/README.md`](../../../nix/files/claude/skills/README.md) と claude-skills の `skills/README.md`
