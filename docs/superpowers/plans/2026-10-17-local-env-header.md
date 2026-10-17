# `~/.config/pjp/env` の頭の「dotfiles が書く欄」実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bootstrap-local-env.sh` を「無ければ作る」から「頭の印付きの欄を `setup --update` のたびに書き直し、欄の外は 1 バイトも変えない」へ変え、欄に並べる環境変数の一覧を dotfiles の `nix/pjp-env/dotfiles.txt` と各 skill の `pjp-env.txt` から集める。

**Architecture:** script は欄を一時ファイルに組み (`render_block`)、今のファイルの印の行を awk で探して、印の外を `head` / `tail` でバイトのまま切り出し、欄と継ぎ合わせる。書き上がりが今と違うときだけ、前の版を `env.bak` に写してから一時ファイルを `mv` する。迷う場面 (印が壊れている・symlink・書けない) は warn で知らせて exit 0。

**Tech Stack:** bash (macOS の 3.2 でも動く書き方)・POSIX の awk / head / tail / cmp・Nix flake の checks (`runCommand`)

**Spec:** `docs/adr/021_local_env_header_20261017T224146JST/README.md` (ADR 021、方針は 2026-10-17 にユーザーが承認)

## Global Constraints

- 印の始まりの行 (欄が書く文面): `# >>> dotfiles が書く欄 (setup --update のたびに書き直す。ここには書かない) >>>`
- 印の終わりの行 (欄が書く文面): `# <<< dotfiles が書く欄ここまで。この行より下に生の KEY=VALUE を書く (setup はここから下を書き換えない) <<<`
- 印として見るのは頭だけ: 行末の CR を 1 つ外し、1 行目なら先頭の UTF-8 BOM も外したうえで、`# >>> dotfiles` / `# <<< dotfiles` で始まる行
- 欄の中のすべての行は `#` で始まる。`^[A-Za-z_][A-Za-z0-9_]*=` に合う行は欄に 1 つも無い (bash・fish・`notion_profile.py` の 3 つのローダの規則)
- 印の外は 1 バイトも変えない (CRLF・末尾に改行の無い行・UTF-8 でない文字も)
- 値とユーザーの行そのものは、stdout にも stderr にも `DOTFILES_SETUP_WARNINGS` にも出さない。出してよいのは件数と変数名
- このファイルのことで exit 0 以外を返さない (setup の後ろの手順を巻き込まない)
- 書き換えるときは、同じディレクトリの `env.bak` (600、1 世代) へ前の版を写し、同じディレクトリの一時ファイル (600) から `mv`
- 書き上がりが今と同じなら何も書かない。パーミッションが 600 でなければ 600 へ締める (今と同じ)
- bash 3.2 で動く書き方: `mapfile`・連想配列・`${x,,}` を使わない。空の配列は `${a[@]+"${a[@]}"}` で受ける
- shfmt (`.editorconfig`: 2 空白・`binary_next_line`・`case_indent`) と shellcheck を通す
- テストの先頭のコメントに「## 確かめること」を書く (`check-test-headers.sh`)。コマンドの出力を `| grep -q` に流さない (ファイルに落として見る。`check-test-grep-q.sh`)
- warn() と summary_warn() は `bootstrap-windows-terminal.sh` と同じ形で持つ (`warn-helpers.test.sh` が全 script を並べて見る)
- commit メッセージは日本語の `<種類>(<範囲>): …`。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` と `Claude-Session: https://claude.ai/code/session_01YPQ36vMszDJNbU8Y8dn4fU` の 2 行
- `~/.config/pjp/env` (この PC の本物) を開いて中身を読まない・表示しない

## Review Focus

- ファイルの頭に UTF-8 BOM がある (Windows のエディタで保存した): 印も古いテンプレートも見失わず、書き直した欄の頭に BOM は付かない (Task 2 の T12)
- `pjp-env.txt` が CRLF・末尾に改行が無い: 欄の行に CR が混ざらず、最後の行も落ちない (Task 1 の T4)
- `~/.claude/skills/` に切れた symlink がある (claude-skills の clone を消した): 黙って飛ばし、warn も出さない (Task 1 の T2)
- 今のファイルが空 (0 バイト): 欄だけになり、「0 行」と言う (Task 2 の T13)
- 印の外の最後の行に改行が無く、そのすぐ後ろに欄の行が来る形にはならない (印の外の下側は常にファイルの末尾。上側は印の行の前で必ず改行で終わる): T6 のバイト比較で押さえる

---

### Task 1: 欄を組んで、無ければ作る

**Files:**
- Modify: `nix/scripts/bootstrap-local-env.sh` (全体を書き直す。頭のコメントの約束も ADR 021 に合わせる)
- Create: `nix/pjp-env/dotfiles.txt`
- Create: `nix/tests/bootstrap-local-env.test.sh`
- Modify: `nix/flake.nix` (checks に `bootstrap-local-env-test` を足す)

**Interfaces:**
- Produces (script の中の関数。Task 2 が使う):
  - `render_fragment <見出し> <ファイル>`: 欄の 1 節を stdout へ。読めない・印に化ける行があれば warn して何も出さず 1 を返す。空 (空行だけ) なら何も出さず 0
  - `render_block`: 欄の全体 (始まりの印〜終わりの印) を stdout へ
  - 変数 `env_file` (`${XDG_CONFIG_HOME:-${HOME}/.config}/pjp/env`)・`env_dir`・`bak_file` (`${env_dir}/env.bak`)・`repo_dir` (script のいる checkout の根)
- Produces (テストの道具。Task 2 が足すケースも使う): `new_case <名前>`・`run <ケース>`・`envf <ケース>`・`ok` / `ng`
- 欄の組み方 (ADR 021 の A・E): 始まりの印 → 下の「前置き」 → 節 (dotfiles が先、skill は `~/.claude/skills/*/pjp-env.txt` をディレクトリ名の C ロケール順) → `#####################################################` (# が 53 個) → 終わりの印
- 1 節: `# ---- <見出し> ----`・`#`・断片の各行・`#`。見出しは `dotfiles` か `skill: <ディレクトリ名>`
- 断片の行: 行末の CR を外す。先頭と末尾の空行は落とす。空行は `#`、それ以外は `# ` + 行。`# ` を付けた行が印として読まれるもの (行頭が `>>> dotfiles` か `<<< dotfiles`) を持つ断片と、行の途中に制御文字 (タブを除く) か U+0085・U+2028・U+2029 を持つ断片 (ADR 021 の G) は、節ごと入れない

前置き (始まりの印の次から、そのまま書く):

```
#
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (dotfiles の nix/README.md「マシンローカルの環境変数」)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#   - 同じ名前を 2 回書くと、後の行が勝つ
#
# 下に並ぶのは、dotfiles と skill が受け取る環境変数。使うものは、この欄より下へ
# 「#」を外して書き写し、値を入れる。
#
```

`nix/pjp-env/dotfiles.txt` (このまま):

```
setup が対象にするホストを決めるための変数 (--host と同じ)。取り得る値: ~/dotfiles/flake.nix か nix/hosts/default.nix に載っているホスト名。
DOTFILES_HOST=xxxxxx

ローカル flake の置き場所を変えるための変数。取り得る値: ディレクトリのパス (既定は ~/dotfiles)。
DOTFILES_LOCAL_DIR=xxxxxx

dotfiles-private の clone の置き場所を変えるための変数。取り得る値: ディレクトリのパス (既定は $(ghq root)/github.com/pollenjp/dotfiles-private)。
DOTFILES_PRIVATE_DIR=xxxxxx

claude-skills (private な skill 置き場) の clone の置き場所を変えるための変数。取り得る値: ディレクトリのパス (既定は $(ghq root)/github.com/pollenjp/claude-skills)。
CLAUDE_SKILLS_DIR=xxxxxx

cc-pages (長い応答を読む web ビューア) の clone の置き場所を変えるための変数。取り得る値: ディレクトリのパス (既定は $(ghq root)/github.com/pollenjp/cc-pages)。
CC_PAGES_DIR=xxxxxx

ここには書かない (コマンドの前に付けて 1 回だけ使う):
  USE_LINUX_SSH=1 ssh <ホスト>  常に効かせると ssh-add も Linux 側になり、git の署名鍵が並ばない
  DOTFILES_MIN_RELEASE_AGE_DAYS=0 ~/dotfiles/setup --steps flake-update  常に効かせると flake.lock の遅延が外れたままになる (FLAKE_MIN_RELEASE_AGE_DAYS も同じ)
```

- [ ] **Step 1: テストの骨組みと Task 1 のケースを書く**

`nix/tests/bootstrap-local-env.test.sh <script> [<dotfiles.txt>]`。形は `bootstrap-windows-terminal.test.sh` に揃える (`set -u -o pipefail`・`ok` / `ng`・最後に件数を出して失敗があれば exit 1)。

- `new_case <名前>`: `<work>/<名前>/repo/nix/scripts/` に script を写し、`<work>/<名前>/repo/nix/pjp-env/dotfiles.txt` にテスト用の断片 (2 変数) を置き、`<work>/<名前>/home/.claude/skills/` に下の skill を置く
  - `alpha/pjp-env.txt` (普通の 1 変数)・`zeta/pjp-env.txt` (`FOO=bar` の行と空行を含む)・`empty/pjp-env.txt` (空行だけ)・`noenv/` (pjp-env.txt 無し)・`linked` → `<ケース>/clone/skills/linked/` への symlink (pjp-env.txt あり)・`broken` → 無い場所への symlink・`bad/pjp-env.txt` (`<<< dotfiles を足す` の行を含む)・`crlf/pjp-env.txt` (CRLF で、末尾に改行が無い)
- `run <ケース>`: `env HOME=<ケース>/home XDG_CONFIG_HOME=<ケース>/home/.config DOTFILES_SETUP_WARNINGS=<ケース>/warnings "${BASH}" <ケース>/repo/nix/scripts/bootstrap-local-env.sh` を流し、`out`・`err`・`rc` をケースの dir に落とす
- テスト用の秘密の値 `secret=ntn_test_secret_do_not_print` を決めておく

ケース:

- T1「無ければ作る」: rc 0・ファイルがある・パーミッション 600・1 行目が始まりの印の文面・最後の行が終わりの印の文面・すべての行が `#` で始まる・`^[A-Za-z_][A-Za-z0-9_]*=` に合う行が 0・out に「作りました」・`env.bak` が無い
- T2「節の並び」: 見出しが `# ---- dotfiles ----`・`# ---- skill: alpha ----`・`# ---- skill: crlf ----`・`# ---- skill: linked ----`・`# ---- skill: zeta ----` の順に 1 つずつ。`skill: empty`・`skill: noenv`・`skill: broken`・`skill: bad` は無い。err に `broken` は出ない
- T3「断片から生きた変数は生まれない」: `zeta` の `FOO=bar` は `# FOO=bar` として欄にあり、断片の空行は `#` になっている。各節は見出しの次が `#`、その次が断片の 1 行目 (先頭の空行が落ちている)
- T4「CRLF と末尾に改行の無い断片」: 欄のどの行にも CR が無く、`crlf` の最後の行が欄にある
- T5「印に化ける断片は入れない」: err に `!! ` と `bad/pjp-env.txt` があり、`warnings` にも同じ行がある。欄の始まりの印・終わりの印はそれぞれ 1 つだけ
- T5b「行の途中に制御文字がある断片は入れない」(ADR 021 の G で足した): `ctrl/pjp-env.txt` (`…\rPJP_NOTION_TOKEN_PERSONAL=bogus`) と `uline/pjp-env.txt` (行の途中に U+2028) → 両方 err に出て節が無い。欄に C0 の制御文字 (タブと改行を除く)・DEL・U+0085・U+2028・U+2029 が 1 つも無い
- T6「本物の dotfiles.txt」(第 2 引数があるときだけ): それを偽の checkout に置いて作ると、rc 0・err が空・`dotfiles.txt` の空でない各行が `# ` を付けて欄にある

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-local-env.test.sh nix/scripts/bootstrap-local-env.sh nix/pjp-env/dotfiles.txt`
Expected: T1〜T6 が FAIL (今の script は欄を作らない。dotfiles.txt もまだ無い)

- [ ] **Step 3: `dotfiles.txt` を置き、script の作る側を書く**

頭のコメントは 1 行目を「マシンローカルの環境変数ファイル (~/.config/pjp/env) を用意し、頭の「dotfiles が書く欄」を書き直す。」にする (setup のメニューが 1 行目を説明として拾う)。「なぜ Nix で配置しないのか」は残し、「なぜ home.activation でやらないのか」は「秘密の入ったファイルを switch が書くと Nix 管理か否かの線が曖昧になる」に、「中身は絶対に上書きしない」は ADR 021 の約束 (欄だけ書き直し、欄の外は 1 バイトも変えない・迷ったら書かない) に書き換える。この Task ではファイルが無いときに欄だけのファイルを作るところまで (一時ファイルに `render_block` を書き、600 にして `mv`)。在るときは今と同じく中身に触らない。

- [ ] **Step 4: flake の checks に載せる**

`nix/flake.nix` の `bootstrap-windows-terminal-test` の隣に:

```nix
          bootstrap-local-env-test = pkgs.runCommand "bootstrap-local-env-test" { } ''
            bash ${./tests/bootstrap-local-env.test.sh} ${./scripts/bootstrap-local-env.sh} ${./pjp-env/dotfiles.txt}
            touch $out
          '';
```

- [ ] **Step 5: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-local-env.test.sh nix/scripts/bootstrap-local-env.sh nix/pjp-env/dotfiles.txt` と `nix build ./nix#checks.x86_64-linux.bootstrap-local-env-test -L`
Expected: T1〜T6 が ok、build が通る

- [ ] **Step 6: lint を流す**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-local-env.sh nix/tests/bootstrap-local-env.test.sh; shellcheck nix/scripts/bootstrap-local-env.sh nix/tests/bootstrap-local-env.test.sh; ./nix/scripts/check-test-headers.sh; ./nix/scripts/check-test-grep-q.sh'` と `nix build ./nix#checks.x86_64-linux.warn-helpers-test`
Expected: どれも何も言わずに通る

- [ ] **Step 7: Commit**

```bash
git add nix/scripts/bootstrap-local-env.sh nix/pjp-env/dotfiles.txt nix/tests/bootstrap-local-env.test.sh nix/flake.nix
git commit -m "feat(nix): ~/.config/pjp/env が無ければ、受け取る環境変数の一覧の欄を組んで作る (ADR 021)"
```

### Task 2: 今あるファイルの欄を書き直す

**Files:**
- Modify: `nix/scripts/bootstrap-local-env.sh`
- Modify: `nix/tests/bootstrap-local-env.test.sh`

**Interfaces:**
- Consumes: Task 1 の `render_block`・`env_file`・`env_dir`・`bak_file`、テストの `new_case`・`run`・`envf`
- Produces: script の振る舞い (ADR 021 の B の表) 全部

古いテンプレート (印の無い形。行末の CR と 1 行目の BOM を外した 1 行ずつの完全一致で見分ける):

```
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (nix/README.md も参照)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#
# 例:
#   FOO_API_KEY=sk-xxxx
```

継ぎ合わせ方 (b = 始まりの印の行番号、e = 終わりの印の行番号、n = 全行数):

| 形 | 新しい中身 |
| --- | --- |
| 印が 1 組 (b < e) | `head -n b-1` (b > 1 のときだけ) + 欄 + 「救う行」+ `tail -n +e+1` |
| 印が無く、古いテンプレート | 欄 + `tail -n +11` |
| 印が無く、それ以外 | 欄 + 今のファイルの全部 |

- 救う行: b と e の間の行のうち、空白 (空白・タブ・CR) だけでなく、1 文字目が `#` でない行。元のバイト (CR も含む) と元の順のまま。そのうち `^[A-Za-z_][A-Za-z0-9_]*=` に合う行の `=` より前を、warn で並べる変数名にする。合わない行は「KEY=VALUE の形でない行 <k> 行」とだけ言う
- 1 行目の BOM は印の判定と古いテンプレートの判定でだけ外す。書き直した中身は欄から始まるので BOM は消える (b = 1 のとき、BOM は印の行の一部)
- 印の数が 1 組でない (始まりか終わりが 0 と 1 以外・片方だけ・e < b) なら、書かずに warn。warn には両方の印の行番号と、直し方 (印を 1 組だけ残すか、欄ごと消して印の無い形に戻し、`~/dotfiles/setup --steps bootstrap-local-env` で流し直す) を書く
- 書く前に: `env_file` が symlink・普通のファイルでない・読み書きできない → 書かずに warn (どれも exit 0)。一時ファイルが作れない・`mv` に失敗した → warn して exit 0 (`env_file` は元のまま)
- stdout の言い方: 作った「作りました: <パス>」・書き直した「欄を書き直しました: <パス> (欄の外の <n> 行には触れていません。前の版は <bak>)」・古いテンプレート「印の無い古い形だったので、頭のテンプレート 10 行を欄に替えました: …」・頭に足した「印が無かったので、欄を頭に足しました: <パス> (今あった <n> 行はすべて欄の下に残しています。…)」・同じ「欄は最新です: <パス>」。最後に今と同じ「値を足すには (新しいシェルから有効になる):」の 2 行

- [ ] **Step 1: Task 2 のケースを足す**

各ケースは、書く前のファイルの写しを `<ケース>/before` に取っておき、バイトの比較に使う。印の外の比較は `tail -n +<k>` / `head -n <k>` をファイルに落として `cmp -s` で見る。

- T7「古いテンプレート」: 古いテンプレート 10 行 + `PJP_NOTION_TOKEN_PERSONAL=${secret}` + CRLF の行 `FOO=bar\r` + 改行の無い最後の行 `# memo` → rc 0・印が 1 組・終わりの印の次の行からが before の 11 行目からとバイトで同じ・`# 例:` の行が無い・out に「テンプレート 10 行」・`env.bak` が before とバイトで同じで 600
- T8「テンプレートが 1 文字違えば消さない」: 古いテンプレートの 1 行を変えたもの → 終わりの印の次の行からが before 全体とバイトで同じ・out に「頭に足しました」
- T9「印が 1 組なら印の間だけ」: `# above` + 始まりの印 + `# old text` + 終わりの印 + 値・`# 会社の PC 用`・`#PJP_NOTION_TOKEN_WORK=${secret}`・CRLF の行・改行の無い最後の行 → 1 行目が `# above`・`# old text` が無い・`# ---- dotfiles ----` がある・終わりの印より下が before の終わりの印より下とバイトで同じ
- T10「欄の中の値を救う」: 印の間に `FOO_API_KEY=${secret}` と `export BAR=1` → 終わりの印の次の 2 行がこの 2 行 (この順・バイトで同じ)、その下が before の終わりの印より下とバイトで同じ・err と `warnings` に `FOO_API_KEY` と「KEY=VALUE の形でない行 1 行」
- T11「2 回目は書かない」: T9 の後に `touch -d '2000-01-01 00:00:00'` してから流す → out に「最新」・更新時刻が 2000 年のまま・`env.bak` が 1 回目の後から変わらない
- T12「頭の BOM」: (a) BOM + 古いテンプレート + 値 → 古いテンプレートとして扱われ、新しい中身の 1 行目が BOM の無い始まりの印。(b) BOM + 始まりの印 … 終わりの印 + 値 → 1 組として扱われ、同じく BOM が消える
- T13「空のファイル」: 0 バイト → 欄だけになり、out に「0 行」
- T14「印が壊れている」: 始まりだけ / 1 組が 2 つ / 終わりが先 の 3 つ → どれも rc 0・before とバイトで同じ・err に「書き換えません」と行番号・`env.bak` が無い
- T15「symlink と書けないディレクトリ」: (a) `env` が別のファイルへの symlink → rc 0・symlink のまま・先のファイルが before と同じ・err に「symlink」。(b) `env` のディレクトリを 555 にする (`id -u` が 0 なら飛ばす) → rc 0・before と同じ・err に `!! `
- T16「パーミッション」: T11 の後のファイルを 644 にして流す → 600 になり、中身は同じ・out に「最新」
- T17「値を出さない」: ここまでの全ケースの out・err・warnings に `${secret}` が無い (ファイルへ `grep -F` する)
- T18「ローダが読むのは欄の外だけ」: T9 と T10 の後のファイルで、`^[A-Za-z_][A-Za-z0-9_]*=` に合う行の名前の並びが、救った行と欄の下の行の名前の並びと同じ (欄からは 1 つも来ない)

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-local-env.test.sh nix/scripts/bootstrap-local-env.sh nix/pjp-env/dotfiles.txt`
Expected: T1〜T6 は ok、T7〜T16・T18 が FAIL

- [ ] **Step 3: 継ぎ合わせを書く**

上の表のとおり。印の行番号は awk で 1 回で拾う (行末の CR と 1 行目の BOM を外し、`index(line, "# >>> dotfiles") == 1` のように固定文字列で見る)。書き上がりは `env_dir` の一時ファイルに作り、`cmp -s` で今と比べる。違えば `env.bak` を一時ファイル経由 (600) で置いてから `mv`。一時ファイルは EXIT の trap で消す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-local-env.test.sh nix/scripts/bootstrap-local-env.sh nix/pjp-env/dotfiles.txt` と `nix build ./nix#checks.x86_64-linux.bootstrap-local-env-test -L`
Expected: T1〜T18 がすべて ok

- [ ] **Step 5: lint を流す** (Task 1 の Step 6 と同じ)

- [ ] **Step 6: Commit**

```bash
git add nix/scripts/bootstrap-local-env.sh nix/tests/bootstrap-local-env.test.sh
git commit -m "feat(nix): ~/.config/pjp/env の頭の欄だけを書き直し、欄の外は 1 バイトも変えない (ADR 021)"
```

### Task 3: 文書

**Files:**
- Modify: `nix/README.md` (手順の表の 6.6・「マシンローカルの環境変数」の節・ファイルの木)
- Modify: `nix/files/claude/skills/README.md`
- Modify: `docs/adr/README.md`

**Interfaces:**
- Consumes: Task 1・2 の振る舞いと文面 (印・節の見出し・stdout の言い方)

- [ ] **Step 1: `nix/README.md` を直す**

- 手順の表 6.6 の説明: 「`~/.config/pjp/env` を置き、頭の「dotfiles が書く欄」を書き直す（後述）」
- 「マシンローカルの環境変数」の節: 「初回だけ形式を書いたテンプレート…上書きは一切しない」の段落を、ADR 021 の振る舞い (欄だけ書き直す・欄の外は 1 バイトも変えない・欄の中の値は欄の下へ移す・迷ったら書かずに warn・`env.bak`) に書き換える。その下に「### 一覧の欄 (ADR 021)」を足し、欄の形の短い例・出どころ (`nix/pjp-env/dotfiles.txt` と `~/.claude/skills/*/pjp-env.txt`)・載せる基準 (ADR 021 の F)・変数を足すとき・印の無い古いファイルの移り方を書く
- ファイルの木: `scripts/bootstrap-local-env.sh` の行を「~/.config/pjp/env を置き、頭の一覧の欄を書き直す (冪等。更新時も毎回走る。欄の外は書き換えない)」に。`files/` の下に `pjp-env/  ~/.config/pjp/env の頭の欄に並べる、dotfiles の script が受け取る環境変数 (dotfiles.txt)` を足す

- [ ] **Step 2: `nix/files/claude/skills/README.md` に節を足す**

「## 環境変数を受け取るとき (`pjp-env.txt`)」: skill が読む環境変数のうち、そのマシンで常に効かせる意味があるもの (ADR 021 の F の基準) は、skill のディレクトリに `pjp-env.txt` を置くと `~/.config/pjp/env` の頭の欄に `# ---- skill: <名前> ----` の節として載る。素のテキストで、1 変数を「何のための変数か。取り得る値: …。」の行と `<名前>=xxxxxx` の行で書き、空行で区切る。ここに書くと困る変数は「ここには書かない」の行でまとめる。`>>> dotfiles` / `<<< dotfiles` で始まる行は書けない。

- [ ] **Step 3: `docs/adr/README.md` の一覧に 020 を足す**

`| [021](./021_local_env_header_20261017T224146JST/README.md) | `~/.config/pjp/env` の頭に、受け取る環境変数の一覧を setup が書き直す欄として置き、欄の外は書き換えない | 2026-10-17 |`

- [ ] **Step 4: Commit**

```bash
git add nix/README.md nix/files/claude/skills/README.md docs/adr/README.md
git commit -m "docs(nix): ~/.config/pjp/env の頭の欄と pjp-env.txt の書き方を書く (ADR 021)"
```

### Task 4: claude-skills の断片 (別の repo・別の PR)

**Files (repo: `~/ghq/github.com/pollenjp/claude-skills`、branch: `feat/pjp-env-txt`):**
- Create: `skills/pjp-notion-profile/pjp-env.txt`
- Create: `skills/pjp-video-explainer-pictogram/pjp-env.txt`
- Modify: `skills/README.md` (「## 環境変数を受け取るとき (`pjp-env.txt`)」。Task 3 の Step 2 と同じ中身)

**Interfaces:**
- Consumes: Task 1 の断片の書き方と、dotfiles の作業ツリーの `nix/scripts/bootstrap-local-env.sh`

`skills/pjp-notion-profile/pjp-env.txt` (このまま):

```
Notion へ書く skill (pjp-dev-tracker など) が、プロファイル <名前> を API キーで認証するための変数。取り得る値: そのプロファイルの workspace の integration の API キー (ntn_…)。
<名前> は大文字にし、- は _ にする (personal → PJP_NOTION_TOKEN_PERSONAL、my-ws → PJP_NOTION_TOKEN_MY_WS)。無ければ ntn login の token を使う。
PJP_NOTION_TOKEN_PERSONAL=xxxxxx

ここには書かない:
  NOTION_API_TOKEN  書くと、どの repo でも宛先の規則を通らずにその token が勝つ
```

`skills/pjp-video-explainer-pictogram/pjp-env.txt` (このまま):

```
voice-match (お手本のナレーションに近い VOICEVOX の話者を探す script) が使う whisper.cpp のモデルを、手元のファイルに替えるための変数。取り得る値: ggml 形式のモデルファイルのパス (既定は ~/.cache/pjp-voice-match/ggml-large-v3-turbo.bin。無ければ初回に落とす)。
WHISPER_MODEL=xxxxxx
```

- [ ] **Step 1: branch を切って断片と README を書く** (`git switch -c feat/pjp-env-txt` を main から)

- [ ] **Step 2: lint と、本物の skill から欄が組めることを確かめる**

Run: `./scripts/lint.sh` (claude-skills の根で)。続けて、使い捨ての `XDG_CONFIG_HOME` で dotfiles の作業ツリーの script を流す (本物の `~/.config/pjp/env` には触れない):

```bash
t=$(mktemp -d) && XDG_CONFIG_HOME="$t" bash ~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-local-env.sh >"$t/out" 2>"$t/err"; grep -c '^# ---- skill: pjp-notion-profile ----$' "$t/pjp/env"; grep -c '^# ---- skill: pjp-video-explainer-pictogram ----$' "$t/pjp/env"; cat "$t/err"; rm -rf "$t"
```

Expected: lint が通る。2 つの見出しがそれぞれ 1、err が空

- [ ] **Step 3: Commit**

```bash
git add skills/pjp-notion-profile/pjp-env.txt skills/pjp-video-explainer-pictogram/pjp-env.txt skills/README.md
git commit -m "feat(skills): pjp-env.txt で ~/.config/pjp/env の頭の欄に、skill が受け取る環境変数を載せる"
```

### Task 5: この PC のファイルの写しで確かめ、ADR の検証を書いて PR を出す

**Files:**
- Modify: `docs/adr/021_local_env_header_20261017T224146JST/README.md` (§6 検証)

- [ ] **Step 1: この PC のファイルの写しで流す (値は出さない)**

使い捨ての dir (700) に `~/.config/pjp/env` を `cp -p` で写し、`XDG_CONFIG_HOME` をそこへ向けて dotfiles の作業ツリーの script を流す。確かめるのは、rc 0・out に「テンプレート 10 行」・写しの 11 行目からと、新しいファイルの終わりの印の次の行からが `cmp -s` で同じ・`^[A-Za-z_][A-Za-z0-9_]*=` の行の数が前後で同じ。中身は表示しない。終わったら dir ごと消す。本物は merge の後の `setup --update` で書き換わる

- [ ] **Step 2: 全部の check を流す**

Run: `nix build ./nix#checks.x86_64-linux.bootstrap-local-env-test ./nix#checks.x86_64-linux.warn-helpers-test ./nix#checks.x86_64-linux.check-test-headers-test -L` と Task 1 の Step 6 の lint
Expected: すべて通る

- [ ] **Step 3: ADR 021 の §6 に、実際に流したもの (テストの件数・lint・写しで確かめたこと) を書いて commit**

- [ ] **Step 4: push して PR を 2 本作る**

dotfiles: PR に載る commit がこの作業だけかを `git log --oneline main..HEAD` で確かめてから push し、`gh pr create`。本文に ADR 021 へのリンク・変わること・確かめたこと・自分で決めたこと・merge 後の手順 (`~/dotfiles/setup --update`) を書く。claude-skills: 同じく確かめて push し、`gh pr create`。本文で dotfiles の PR を指す (この PR の断片は dotfiles の PR が merge されるまで欄に出ない。先に merge しても害は無い)。
