# Windows 側の ~/.ssh を dotfiles-private から配る 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ssh の接続先の正本を `.ssh` submodule (pollenjp/dotfiles-ssh) から pollenjp/dotfiles-private の `ssh/` へ移し、WSL・Linux・macOS の `~/.ssh/config.d/` へは symlink で、Windows の `%USERPROFILE%\.ssh` へはコピーで配る。

**Architecture:** order 60 の `nix/scripts/bootstrap-ssh-config.sh` が `~/.ssh/config.d/` へ symlink を張る (今の `setup-ssh-config.sh` を置き換える)。order 91 の `nix/scripts/bootstrap-windows-ssh-config.sh` が Windows の `config` (`Include config.d/*.ssh_config` の 1 行) と `config.d\` へコピーし、置いた中身を sha256 の記録で管理して、書いたあとに `ssh.exe -v -G` で読んだファイルを確かめる。setup の `ssh-config` 手順と `.ssh` submodule は外す。

**Tech Stack:** bash (shfmt / shellcheck)、jq、coreutils、Nix flake の `checks` (`scriptTest`)

**Spec:** `docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md` (ADR 016、2026-10-12 に承認済み。チケットは TKT-145)

## Global Constraints

- `nix/scripts/bootstrap-ssh-config.sh` は `# order: 60`、`nix/scripts/bootstrap-windows-ssh-config.sh` は `# order: 91`。同じ値の `bootstrap-claude-accounts.sh` (60)・`bootstrap-windows-powertoys.sh` (91) とは名前の順に並び、互いに依存しない
- bootstrap の冒頭で、`#!` と `# shellcheck` と空のコメント行を除いた最初のコメント行が setup のメニューの説明になる。`# order:` はその後ろ (先頭 40 行以内) に書く
- script は `set -eu -o pipefail`。shfmt (`.editorconfig`: 2 空白・`binary_next_line`・`case_indent`) と shellcheck を通す (CI の lint が `nix/` の `*.sh` を全部見る)
- 記録は `~/.local/state/dotfiles/windows-ssh-config.deployed.json`。形は `{"version":1,"files":{"<.ssh からの相対パス>":"<sha256>"}}`
- 旧経路の 1 行は `Include ~/dotfiles/ssh_config`。BOM・CR・行の前後の空白・空行は無視して比べる
- Windows の `config` の中身は次の 4 行 (script の `config_body` とテストの `config_want` で同じ文字列):

  ```text
  # dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
  # マシン固有の Host は config.d\ に <名前>.ssh_config として置く。
  # config.d はファイル名の順に読み、同じキーは先に読んだ値が効く。
  Include config.d/*.ssh_config
  ```

- 退避は `<名前>.dotfiles-bak-<YYYYmmdd-HHMMSS>`、一時ファイルは `<名前>.dotfiles-tmp.XXXXXX` (bootstrap-windows-files.sh と同じ)。どちらも `*.ssh_config` で終わらないので `Include` されない
- 終了コード (Windows 側): 揃った・書いた・対象外・`windows-files.json` が無い・正本が無い / 空・ssh.exe を呼べない → 0、衝突・確かめの失敗 → 1、引数の誤り → 2
- ⚠ の枠は `⚠️ ━━━…━━━ ⚠️` の行で挟み、端末で `NO_COLOR` が無いときだけ黄色・太字にする (bootstrap-windows-openssh.sh と同じ)
- テストは Nix のサンドボックスで流れる。偽のコマンドの shebang は `$BASH` から作り、本物の `ssh.exe` を見せない PATH で流し、`nix/flake.nix` の `checks` に `scriptTest` で載せる。flake は git が追跡しているファイルしか見ないので、`nix build` の前に `git add` する
- 公開 repo に接続先 (ホスト名・private なファイル名) を書かない。テストの接続先は `*.example.test`
- `nix/scripts/verify.sh` は流さない (実機の user systemd に触る)。確かめは `nix build ./nix#checks.…` と `nix flake check ./nix`
- commit は日本語で `<type>(<scope>): … (TKT-145)` の形にし、本文の末尾に次の 2 行を付ける:

  ```text
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
  ```

- push・PR の作成・この PC の本物の `~/.ssh` と `%USERPROFILE%\.ssh` を書き換える操作は、ユーザーに確かめてから行う

## Review Focus

spec が言わないが、使う人が踏みやすい入力と、期待する振る舞い。どれも下のテストで押さえる。

1. ssh.exe が出すパスの区切り (`\\` と `/`) や大文字小文字が、置いたファイルと違う → 同じファイルとみなし、確かめを落とさない (Task 3 のテスト 20)
2. 接続先のファイル名に空白が入る (`b c.ssh_config`) → クォートが漏れずに張れ、コピー・削除・記録ができる (Task 2 のテスト 1・3、Task 3 のテスト 5・11)
3. 旧経路の 1 行だけの `config` に、BOM・CRLF・前後の空白・空行が付いている (メモ帳で保存したなど) → 衝突にせず置き換える (Task 3 のテスト 7)
4. interop の不調で ssh.exe が返ってこない → 待つのをやめ、手で打つコマンドを出して exit 0 にし、setup を止めない (Task 3 のテスト 19)
5. dotfiles-private の `ssh/` に `*.ssh_config` 以外・サブディレクトリ・symlink が混ざる → 直下の通常のファイルの `*.ssh_config` だけを配る (Task 2 のテスト 1、Task 3 のテスト 5)

---

## File Structure

| ファイル | 種類 | 役目 |
| --- | --- | --- |
| `pollenjp/dotfiles-private` の `ssh/*.ssh_config` | 新規 (別の repo) | 接続先の正本。`.ssh` submodule の 4 ファイルを写す |
| `pollenjp/dotfiles-private` の `README.md` | 変更 (別の repo) | `ssh/` の行と、直し方の段落 |
| `nix/scripts/bootstrap-ssh-config.sh` | 新規 | order 60。dotfiles-private の `ssh/` を `~/.ssh/config.d/` へ symlink で張る |
| `nix/tests/bootstrap-ssh-config.test.sh` | 新規 | 上の振る舞いを使い捨ての HOME で確かめる |
| `nix/scripts/bootstrap-windows-ssh-config.sh` | 新規 | order 91。Windows の `config` と `config.d` へコピーし、記録と確かめを持つ |
| `nix/tests/bootstrap-windows-ssh-config.test.sh` | 新規 | 上の振る舞いを偽の Windows のホームと偽の `ssh.exe` で確かめる |
| `nix/flake.nix` | 変更 | `checks` に 2 本のテストを足す |
| `nix/scripts/setup.sh` | 変更 | `ssh-config` 手順を外し、self-update の `--ignore-submodules=all` を外す |
| `nix/scripts/setup-ssh-config.sh` | 削除 | `bootstrap-ssh-config.sh` に置き換わる |
| `.gitmodules`・`.ssh` (gitlink) | 削除 | submodule をやめる |
| `nix/home/modules/ssh.nix` | 変更 | コメントの「.ssh submodule」「setup-ssh-config.sh」を直す |
| `nix/scripts/bootstrap-dotfiles-private.sh` | 変更 | 説明と取れないときの文に ssh を足す |
| `nix/files/claude/skills/pjp-dotfiles-update/SKILL.md` | 変更 | 走る手順から `ssh-config` を外す |
| `nix/README.md`・`README.md`・`win/README.md` | 変更 | 手順表・order の表・「ssh について」・「ssh の設定」・ディレクトリの一覧 |
| ADR 003 / 013 / 015 の `README.md` | 変更 | 冒頭に後続 ADR (016) のポインタだけ足す |
| ADR 016 の `README.md` | 変更 | 一時ファイルの名前を実装に合わせ、§6 に検証の結果を書く |

---

### Task 1: dotfiles-private に ssh/ を足す

**Files:**
- Create: `$(ghq root)/github.com/pollenjp/dotfiles-private/ssh/*.ssh_config` (4 ファイル。名前は submodule と同じ)
- Modify: `$(ghq root)/github.com/pollenjp/dotfiles-private/README.md`

**Interfaces:**
- Produces: `dotfiles-private/ssh/<名前>.ssh_config` (Task 2・3 の script が読む正本。Task 6 の実機の確かめで使う)

- [ ] **Step 1: 写す元と写す先が手付かずかを確かめる**

```bash
src="$(ghq root)/github.com/pollenjp/dotfiles/.ssh"
dst="$(ghq root)/github.com/pollenjp/dotfiles-private"
git -C "${src}" rev-parse --short HEAD   # 期待: 83211b3
git -C "${src}" status --porcelain       # 期待: 何も出ない
git -C "${dst}" status --porcelain       # 期待: 何も出ない
git -C "${dst}" pull --ff-only
```

- [ ] **Step 2: 4 ファイルを写し、中身が同じことを確かめる**

```bash
mkdir -p "${dst}/ssh"
cp -p "${src}"/*.ssh_config "${dst}/ssh/"
ls "${dst}/ssh" | wc -l                  # 期待: 4
for f in "${src}"/*.ssh_config; do cmp "${f}" "${dst}/ssh/$(basename "${f}")" && echo "same: $(basename "${f}")"; done
```

Expected: `same:` の行が 4 つ出る。`Makefile` は写さない。

- [ ] **Step 3: README に `ssh/` の行と段落を足す**

`README.md` の表の、Google 日本語入力の行の下に足す:

```markdown
| `ssh/<名前>.ssh_config` | ssh の接続先 (Host ブロック)。WSL・Linux・macOS では `~/.ssh/config.d/` へ symlink、Windows では `%USERPROFILE%\.ssh\config.d\` へコピーされる | dotfiles の `nix/scripts/bootstrap-ssh-config.sh`・`nix/scripts/bootstrap-windows-ssh-config.sh` |
```

末尾の段落の後ろに足す:

```markdown
接続先を足す・直すときは `ssh/` のファイルを直して commit・push し、各マシンで `~/dotfiles/setup --update` を流す。
`config.d` はファイル名の順に読まれ、同じキーは先に読んだ値が効く。経緯は dotfiles の ADR 016
(もとは dotfiles の `.ssh` submodule (pollenjp/dotfiles-ssh) にあった)。
```

- [ ] **Step 4: commit する (push は Task 7 でユーザーに確かめてから)**

```bash
git -C "${dst}" add ssh README.md
git -C "${dst}" commit -F - <<'EOF'
ssh の接続先を ssh/ に置く (pollenjp/dotfiles の TKT-145)

pollenjp/dotfiles-ssh@83211b3 の *.ssh_config 4 ファイルをそのまま写した。履歴は持ってこない。
dotfiles の bootstrap-ssh-config.sh が ~/.ssh/config.d/ へ張り、bootstrap-windows-ssh-config.sh が
Windows の %USERPROFILE%\.ssh\config.d\ へコピーする (dotfiles の ADR 016)。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
git -C "${dst}" log --oneline -1
```

---

### Task 2: bootstrap-ssh-config.sh (order 60) とテスト

**Files:**
- Create: `nix/scripts/bootstrap-ssh-config.sh`
- Create: `nix/tests/bootstrap-ssh-config.test.sh`
- Modify: `nix/flake.nix` (`checks` の `bootstrap-dotfiles-private-test` の行の下)

**Interfaces:**
- Consumes: `DOTFILES_PRIVATE_DIR` (無ければ `$(ghq root)/github.com/pollenjp/dotfiles-private` → `~/ghq/github.com/pollenjp/dotfiles-private`) の `ssh/*.ssh_config`
- Produces: `~/.ssh/config.d/<名前>.ssh_config` → `<dotfiles-private>/ssh/<名前>.ssh_config` の symlink。終了コードは 0 (正本が無い・空でも) / 2 (知らない引数)。setup の手順 id は `bootstrap-ssh-config` (Task 4 が `ssh-config` を外したあとの代わり)

- [ ] **Step 1: 失敗するテストを書く**

`nix/tests/bootstrap-ssh-config.test.sh` を次の中身で作る:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-ssh-config.sh の振る舞いを、使い捨ての HOME・dotfiles-private・
# dotfiles の checkout で確かめる。
#
#   bash nix/tests/bootstrap-ssh-config.test.sh [<script のパス>]
#
# flake の checks (bootstrap-ssh-config-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash と coreutils・grep だけ。
#
# ## 確かめること
#
#   - ssh/*.ssh_config だけを ~/.ssh/config.d/ へ張り、~/.ssh と config.d を 700 にする
#   - 2 回目も同じ結果になる。正本から消えたファイルを指す symlink は外す
#   - 旧 .ssh submodule を指す symlink は外して張り替える
#   - 同じ名前の通常のファイル・ほかを指す symlink は上書きせず警告する。名前の違う手置きには触らない
#   - ssh/ が無い・空なら何も外さず張らずに exit 0
#   - 旧 submodule の作業ツリーが残っていれば知らせる。知らない引数は exit 2
#
# ## script の置き場所
#
# script は自分の場所から dotfiles の checkout (2 つ上) を決め、その .ssh/ を旧 submodule と
# みなす。テストでは偽の checkout (<work>/<ケース>/repo/nix/scripts/) へ写してから流す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-ssh-config.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-ssh-config-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# 1 ケースぶんの環境を作る。$1: 名前。
#   <case>/home     HOME
#   <case>/private  dotfiles-private (ssh/ に a.ssh_config と "b c.ssh_config"、ほかに無関係なもの)
#   <case>/repo     dotfiles の checkout (nix/scripts/ に script を写す)
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home" "${c}/private/ssh/sub" "${c}/repo/nix/scripts"
  printf 'Host a\n  HostName a.example.test\n' >"${c}/private/ssh/a.ssh_config"
  printf 'Host b\n  HostName b.example.test\n' >"${c}/private/ssh/b c.ssh_config"
  printf '# not a config\n' >"${c}/private/ssh/README.md"
  printf 'Host sub\n' >"${c}/private/ssh/sub/x.ssh_config"
  ln -s "${c}/private/ssh/a.ssh_config" "${c}/private/ssh/link.ssh_config"
  cp "${script}" "${c}/repo/nix/scripts/bootstrap-ssh-config.sh"
  echo "${c}"
}

# $1: ケース、残り: script の引数
run() {
  local c=$1
  shift
  env HOME="${c}/home" DOTFILES_PRIVATE_DIR="${c}/private" \
    "${BASH}" "${c}/repo/nix/scripts/bootstrap-ssh-config.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
confd() { printf '%s' "$1/home/.ssh/config.d"; }
target() { readlink "$(confd "$1")/$2"; }
mode() { stat -c '%a' "$1"; }
listing() { find "$(confd "$1")" -mindepth 1 -printf '%f -> %l\n' | sort; }

echo "== bootstrap-ssh-config.sh: ${script}"

# 1. 初回: ssh/ 直下の *.ssh_config (通常のファイル) だけを張る
c=$(new_case t1)
run "${c}"
if [[ $(rc "${c}") == 0 ]] \
  && [[ $(target "${c}" a.ssh_config) == "${c}/private/ssh/a.ssh_config" ]] \
  && [[ $(target "${c}" "b c.ssh_config") == "${c}/private/ssh/b c.ssh_config" ]] \
  && [[ ! -e $(confd "${c}")/README.md && ! -e $(confd "${c}")/x.ssh_config && ! -e $(confd "${c}")/link.ssh_config ]] \
  && [[ $(mode "${c}/home/.ssh") == 700 && $(mode "$(confd "${c}")") == 700 ]]; then
  ok "ssh/ 直下の *.ssh_config だけを張り、~/.ssh と config.d を 700 にする"
else
  ng "初回" "rc=$(rc "${c}") $(outerr "${c}") $(listing "${c}" 2>&1)"
fi

# 2. 2 回目: 同じ結果
before=$(listing "${c}")
run "${c}"
after=$(listing "${c}")
if [[ $(rc "${c}") == 0 && ${before} == "${after}" ]] && outerr "${c}" | grep -q '2 個を張りました'; then
  ok "2 回目も同じ結果になる"
else
  ng "2 回目" "rc=$(rc "${c}") ${before} / ${after}"
fi

# 3. 正本から消えたファイルを指す symlink は外す
rm "${c}/private/ssh/b c.ssh_config"
run "${c}"
if [[ $(rc "${c}") == 0 && ! -e $(confd "${c}")/"b c.ssh_config" && ! -L $(confd "${c}")/"b c.ssh_config" ]] \
  && outerr "${c}" | grep -q '正本に無い symlink を 1 個外しました'; then
  ok "正本から消えたファイルを指す symlink を外す"
else
  ng "消えたファイル" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 4. 旧 submodule を指す symlink (この checkout の .ssh/ と ghq の場所の .ssh/) を外して張り替える
c=$(new_case t4)
mkdir -p "$(confd "${c}")" "${c}/repo/.ssh" "${c}/ghq/github.com/pollenjp/dotfiles/.ssh"
printf 'Host a\n' >"${c}/repo/.ssh/a.ssh_config"
printf 'Host old\n' >"${c}/ghq/github.com/pollenjp/dotfiles/.ssh/old.ssh_config"
ln -s "${c}/repo/.ssh/a.ssh_config" "$(confd "${c}")/a.ssh_config"
ln -s "${c}/ghq/github.com/pollenjp/dotfiles/.ssh/old.ssh_config" "$(confd "${c}")/old.ssh_config"
run "${c}"
if [[ $(rc "${c}") == 0 && $(target "${c}" a.ssh_config) == "${c}/private/ssh/a.ssh_config" ]] \
  && [[ ! -L $(confd "${c}")/old.ssh_config ]] \
  && outerr "${c}" | grep -q '正本に無い symlink を 1 個外しました'; then
  ok "旧 submodule を指す symlink を外し、同じ名前は dotfiles-private へ張り替える"
else
  ng "旧 submodule" "rc=$(rc "${c}") $(outerr "${c}") $(listing "${c}" 2>&1)"
fi

# 5. 同じ名前の通常のファイル・ほかを指す symlink は上書きしない。名前の違う手置きには触らない
c=$(new_case t5)
mkdir -p "$(confd "${c}")" "${c}/elsewhere"
printf 'Host mine\n' >"$(confd "${c}")/a.ssh_config"
printf 'Host other\n' >"${c}/elsewhere/b.ssh_config"
ln -s "${c}/elsewhere/b.ssh_config" "$(confd "${c}")/b c.ssh_config"
printf 'Host local\n' >"$(confd "${c}")/local.ssh_config"
ln -s "${c}/elsewhere/b.ssh_config" "$(confd "${c}")/other.ssh_config"
run "${c}"
if [[ $(rc "${c}") == 0 && ! -L $(confd "${c}")/a.ssh_config ]] \
  && grep -q 'Host mine' "$(confd "${c}")/a.ssh_config" \
  && [[ $(target "${c}" "b c.ssh_config") == "${c}/elsewhere/b.ssh_config" ]] \
  && grep -q 'Host local' "$(confd "${c}")/local.ssh_config" \
  && [[ $(target "${c}" other.ssh_config) == "${c}/elsewhere/b.ssh_config" ]] \
  && [[ $(grep -c '同じ名前のものがあるので張りません' "${c}/err") == 2 ]]; then
  ok "同じ名前の通常のファイル・ほかを指す symlink は上書きせず警告し、名前の違う手置きには触らない"
else
  ng "手置き" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 6. ssh/ が無い: 今ある symlink を外さずに exit 0
c=$(new_case t6)
run "${c}"
rm -rf "${c}/private/ssh"
run "${c}"
if [[ $(rc "${c}") == 0 && -L $(confd "${c}")/a.ssh_config ]] && grep -q '張る \*.ssh_config がありません' "${c}/err"; then
  ok "ssh/ が無ければ今ある symlink を外さずに exit 0"
else
  ng "ssh/ が無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 7. ssh/ が空: 同じく何もしない
mkdir -p "${c}/private/ssh"
run "${c}"
if [[ $(rc "${c}") == 0 && -L $(confd "${c}")/a.ssh_config ]] && grep -q '張る \*.ssh_config がありません' "${c}/err"; then
  ok "ssh/ が空でも今ある symlink を外さずに exit 0"
else
  ng "ssh/ が空" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 8. 旧 submodule の作業ツリーが残っていれば知らせる (消さない)
c=$(new_case t8)
mkdir -p "${c}/repo/.ssh" "${c}/repo/.git/modules/.ssh"
printf 'gitdir: ../.git/modules/.ssh\n' >"${c}/repo/.ssh/.git"
run "${c}"
if [[ $(rc "${c}") == 0 && -e ${c}/repo/.ssh/.git ]] \
  && grep -qF "rm -rf '${c}/repo/.ssh' '${c}/repo/.git/modules/.ssh'" "${c}/out"; then
  ok "旧 submodule の作業ツリーが残っていれば、消すコマンドを出す (自分では消さない)"
else
  ng "作業ツリーの残り" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 9. 知らない引数: exit 2
c=$(new_case t9)
run "${c}" --bogus
if [[ $(rc "${c}") == 2 && ! -e $(confd "${c}") ]]; then
  ok "知らない引数は何もせず exit 2"
else
  ng "知らない引数" "rc=$(rc "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-ssh-config.test.sh`
Expected: script が無いので `cp: cannot stat` が出て、`== 0 passed, 9 failed` で終わる (終了コード 1)

- [ ] **Step 3: script を書く**

`nix/scripts/bootstrap-ssh-config.sh` を次の中身で作り、`chmod +x nix/scripts/bootstrap-ssh-config.sh` する:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ張る (冪等。更新時も毎回走る。取れていなければ何もしない)。
#
# order: 60
#
# ^ setup.sh が読む実行順。張る元を取る bootstrap-dotfiles-private.sh (order: 50) より後に
#   走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# ssh の接続先 (ホスト名・ユーザー名・踏み台の構成) は公開したくないので、public なこの
# repo にも /nix/store にも置かず、private な dotfiles-private の ssh/ に置く
# (docs/adr/016_ssh_config_from_dotfiles_private_*)。Nix (home/modules/ssh.nix) が生成する
# ~/.ssh/config は Include の骨組みだけなので、ここで config.d/ へ張れば効く:
#
#     Include config.d/*.ssh_config
#
# Windows 側 (%USERPROFILE%\.ssh) へは bootstrap-windows-ssh-config.sh (order: 91) がコピーする。
#
# ## 何をするか
#
# 1. 張り直す前に、dotfiles-private の ssh/ を指す symlink と、旧 .ssh submodule
#    (<dotfiles の checkout>/.ssh/) を指す symlink を外す。消えたファイルを指す symlink が
#    残って Include され続けるのを防ぐ。手で置いたファイルと、ほかを指す symlink には触らない
# 2. ssh/ 直下の *.ssh_config (通常のファイルだけ) を同じ名前で張る。同じ名前の通常の
#    ファイルや、ほかを指す symlink があれば上書きせずに警告する
#
# ssh/ が無い・空なら 1 もしない (取り損ねで接続先を全部外さない)。警告して exit 0。
# ~/.ssh/config には触らない (Nix が置く)。状態だけ報告する。
#
# dotfiles-private の場所は bootstrap-dotfiles-private.sh と同じ決め方
# ($DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
# ~/ghq/github.com/pollenjp/dotfiles-private)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ symlink で張る (冪等)。

使い方:
  bootstrap-ssh-config.sh

dotfiles-private の場所: $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
                         ~/ghq/github.com/pollenjp/dotfiles-private
EOS
}

for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

warn() {
  printf '!! %s\n' "$*" >&2
}

# $0 が symlink 経由でも実体の場所を返す。
# macOS の readlink には -f が無いので手で辿る。
resolve_dir() {
  local src=$1 dir
  while [[ -L ${src} ]]; do
    dir=$(
      cd -P -- "$(dirname -- "${src}")" &>/dev/null
      pwd
    )
    src=$(readlink -- "${src}")
    case ${src} in
      /*) ;;
      *) src="${dir}/${src}" ;;
    esac
  done
  cd -P -- "$(dirname -- "${src}")" &>/dev/null
  pwd
}

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

script_dir=$(resolve_dir "$0")
repo_dir=$(dirname "$(dirname "${script_dir}")")
ssh_dir="${HOME}/.ssh"
conf="${ssh_dir}/config"
conf_d="${ssh_dir}/config.d"
src_dir="$(private_dir)/ssh"

# 張り直す対象 (正本か旧 submodule を指す symlink) か。$1 = symlink の張り先。
# 旧 submodule は、この checkout の .ssh/ と、ghq の決める場所の .ssh/ の両方を見る
# (worktree から流しても、本体の checkout を指す古い symlink を拾うため)。
ours() {
  case $1 in
    "${src_dir}"/* | "${repo_dir}"/.ssh/* | */pollenjp/dotfiles/.ssh/*) return 0 ;;
  esac
  return 1
}

echo "==> ${conf_d}"
mkdir -p "${conf_d}"
# ssh は自分と親ディレクトリのパーミッションを見る。緩いと黙って設定を無視する。
chmod 700 "${ssh_dir}" "${conf_d}"

# ~/.ssh/config には触らない (Nix が置く)。状態だけ報告する。
if [[ -L ${conf} ]]; then
  if [[ $(readlink -f "${conf}" 2>/dev/null || true) == /nix/store/* ]]; then
    echo "  config: Nix 管理済み"
  else
    echo "  config: Nix 管理外の symlink です。preflight-unlink.sh が外します" >&2
  fi
elif [[ -f ${conf} ]]; then
  echo "  config: 実ファイルがあります。switch は退避が要ります (setup.sh の --backup)" >&2
  echo "          退避後、残したい Host は config.d/ へ手で移してください" >&2
else
  echo "  config: まだありません (switch が作ります)"
fi

echo "==> ${src_dir}"
srcs=()
if [[ -d ${src_dir} ]]; then
  for src in "${src_dir}"/*.ssh_config; do
    if [[ -f ${src} && ! -L ${src} ]]; then
      srcs+=("${src}")
    fi
  done
fi
if ((${#srcs[@]} == 0)); then
  warn "張る *.ssh_config がありません: ${src_dir}"
  echo "   dotfiles-private を取れていないか、ssh/ が空です。今ある symlink はそのまま残します。" >&2
  echo "   取るには: ${script_dir}/bootstrap-dotfiles-private.sh" >&2
  exit 0
fi

# 1. 正本と旧 submodule を指す symlink を外す
gone=0
for link in "${conf_d}"/*; do
  [[ -L ${link} ]] || continue
  ours "$(readlink -- "${link}")" || continue
  unlink "${link}"
  if [[ ! -f ${src_dir}/$(basename "${link}") ]]; then
    gone=$((gone + 1))
  fi
done
if ((gone > 0)); then
  echo "  正本に無い symlink を ${gone} 個外しました"
fi

# 2. 張る
linked=0
skipped=0
for src in "${srcs[@]}"; do
  dst="${conf_d}/$(basename "${src}")"
  if [[ -e ${dst} || -L ${dst} ]]; then
    # 1 で外した後に残っているのは、手で置いたファイルか、ほかを指す symlink
    warn "同じ名前のものがあるので張りません: ${dst}"
    skipped=$((skipped + 1))
    continue
  fi
  ln -s "${src}" "${dst}"
  linked=$((linked + 1))
done
echo "  ${linked} 個を張りました"
if ((skipped > 0)); then
  echo "   中身を見て、要らなければ消してから流し直してください (正本は ${src_dir})。" >&2
fi

# 旧 .ssh submodule の作業ツリーが残っていれば知らせる (自分では消さない)
if [[ -e ${repo_dir}/.ssh/.git ]]; then
  echo
  echo "旧 .ssh submodule の作業ツリーが残っています (もう使っていません)。消すなら:"
  if [[ -d ${repo_dir}/.git/modules/.ssh ]]; then
    echo "  rm -rf '${repo_dir}/.ssh' '${repo_dir}/.git/modules/.ssh'"
  else
    echo "  rm -rf '${repo_dir}/.ssh'"
  fi
fi

echo
echo "--- ${conf_d} ---"
ls -la "${conf_d}"
echo
echo "実際に読まれる設定の確認:"
echo "  ssh -G <ホスト名>"
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-ssh-config.test.sh`
Expected: `== 9 passed, 0 failed`

- [ ] **Step 5: flake の checks に載せ、サンドボックスでも通ることを確かめる**

`nix/flake.nix` の `bootstrap-dotfiles-private-test = scriptTest …;` の行の下に足す:

```nix
          bootstrap-ssh-config-test = scriptTest "bootstrap-ssh-config" ./scripts/bootstrap-ssh-config.sh;
```

```bash
git add nix/scripts/bootstrap-ssh-config.sh nix/tests/bootstrap-ssh-config.test.sh nix/flake.nix
nix build ./nix#checks.x86_64-linux.bootstrap-ssh-config-test -L --no-link
```

Expected: build が成功し、ログの最後に `== 9 passed, 0 failed` が出る

- [ ] **Step 6: lint を通す**

```bash
nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-ssh-config.sh nix/tests/bootstrap-ssh-config.test.sh && shellcheck nix/scripts/bootstrap-ssh-config.sh nix/tests/bootstrap-ssh-config.test.sh && nixfmt --check nix/flake.nix && echo lint-ok'
```

Expected: `lint-ok`

- [ ] **Step 7: commit する**

```bash
git commit -F - <<'EOF'
feat(nix): dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ張る bootstrap-ssh-config.sh を足す (TKT-145)

setup-ssh-config.sh の張り方を引き継ぎ、張る元を dotfiles-private の ssh/ にする (order 60)。
旧 .ssh submodule を指す symlink も外して張り替え、同じ名前の通常のファイルは上書きしない。
正本が無い・空なら何も外さない。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
```

---

### Task 3: bootstrap-windows-ssh-config.sh (order 91) とテスト

**Files:**
- Create: `nix/scripts/bootstrap-windows-ssh-config.sh`
- Create: `nix/tests/bootstrap-windows-ssh-config.test.sh`
- Modify: `nix/flake.nix` (`checks` の `bootstrap-ssh-config-test` の行の下)

**Interfaces:**
- Consumes: `~/.local/state/dotfiles/windows-files.json` (`enable`・`windowsHome`)、`DOTFILES_PRIVATE_DIR` の `ssh/*.ssh_config`、`BOOTSTRAP_SSH_CHECK_TIMEOUT` (確かめで ssh.exe を待つ秒数。既定 30)
- Produces: `<windowsHome>/.ssh/config` と `<windowsHome>/.ssh/config.d/<名前>.ssh_config`、記録 `~/.local/state/dotfiles/windows-ssh-config.deployed.json`。引数は `--dry-run` / `--force` / `-h`。終了コードは Global Constraints の通り

- [ ] **Step 1: 失敗するテストを書く**

`nix/tests/bootstrap-windows-ssh-config.test.sh` を次の中身で作る:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-ssh-config.sh の振る舞いを、使い捨ての HOME・Windows のホーム・
# dotfiles-private と、偽の ssh.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-ssh-config.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-ssh-config-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・diffutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・正本 (ssh/) が無い / 空のときは、何も書かず消さずに exit 0
#   - 初回に config と ssh/ 直下の *.ssh_config をコピーし、記録を相対パスで書く。2 回目は 1 行で済ませる
#   - 旧経路の Include の 1 行 (BOM・CRLF・空白・空行つき) は置き換える。ツールのファイルには触らない
#   - 手書きの config・Windows で変えたファイルは衝突 (exit 1・触らない)。--force は退避して上書きする
#   - 正本の更新は上書き、正本から消えたファイルは消す (Windows で変えていれば衝突、--force で退避して消す)
#   - 同じ名前のファイルは、中身が同じなら記録だけ、違えば衝突。--dry-run は何も書かない
#   - 確かめ: 揃っている / Bad owner / 読まれないファイル / 旧 clone / 呼べない・無い・固まる / 区切りと大小の違い
#   - 壊れた記録は exit 1、知らない引数は exit 2
#
# ## 本物の ssh.exe を見せない
#
# WSL では PATH に本物の ssh.exe がある。見えると本物の Windows の設定を読むので、要るコマンド
# だけを symlink で並べた PATH で流す。偽の ssh.exe はケースごとの bin に置き、shebang は $BASH から
# 作る (Nix のサンドボックスには /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-ssh-config.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-ssh-config-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# script が置く config の中身 (script 側と同じ文字列)
config_want='# dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
# マシン固有の Host は config.d\ に <名前>.ssh_config として置く。
# config.d はファイル名の順に読み、同じキーは先に読んだ値が効く。
Include config.d/*.ssh_config'

# 要るコマンドだけを並べた PATH (ssh.exe・wslpath・ghq は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat sort cut sha256sum mkdir mktemp mv rm cp dirname basename date diff timeout head sleep ls; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

# 1 ケースぶんの環境を作る。$1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先)
#   <case>/home     HOME
#   <case>/win      Windows のホームに見立てる (.ssh はまだ無い)
#   <case>/private  dotfiles-private (ssh/ に a.ssh_config と "b c.ssh_config"、ほかに無関係なもの)
#   <case>/bin      偽の ssh.exe
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/home/.local/state/dotfiles" "${c}/win" "${c}/private/ssh/sub" "${c}/bin"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${c}/win}" >"${c}/home/.local/state/dotfiles/windows-files.json"
  fi
  printf 'Host a\n  HostName a.example.test\n' >"${c}/private/ssh/a.ssh_config"
  printf 'Host b\n  HostName b.example.test\n' >"${c}/private/ssh/b c.ssh_config"
  printf '# not a config\n' >"${c}/private/ssh/README.md"
  printf 'Host sub\n' >"${c}/private/ssh/sub/x.ssh_config"
  ln -s "${c}/private/ssh/a.ssh_config" "${c}/private/ssh/link.ssh_config"
  # 偽の ssh.exe。ssh -v -G と同じく、読んだファイルを stderr に出す (FAKE_SSH_MODE で崩す)
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
echo "user tester"
mode=${FAKE_SSH_MODE:-ok}
case ${mode} in
  broken)
    echo "ssh.exe: cannot execute binary file: Exec format error" >&2
    exit 126
    ;;
  hang)
    sleep 5
    exit 0
    ;;
esac
echo "debug1: OpenSSH_for_Windows_10.0p2 Win32-OpenSSH-GitHub, LibreSSL 4.2.0" >&2
echo 'debug1: Reading configuration data C:\\Users\\tester/.ssh/config' >&2
first=1
for f in "${FAKE_WIN_HOME}"/.ssh/config.d/*.ssh_config; do
  [[ -f ${f} ]] || continue
  name=${f##*/}
  if [[ ${mode} == missing && ${first} == 1 ]]; then
    first=0
    continue
  fi
  first=0
  if [[ ${mode} == backslash ]]; then
    echo "debug1: Reading configuration data c:\\\\users\\\\TESTER\\\\.SSH\\\\config.d\\\\${name}" >&2
  else
    echo "debug1: Reading configuration data C:\\\\Users\\\\tester/.ssh/config.d/${name}" >&2
  fi
  if [[ ${mode} == badowner ]]; then
    echo "Bad owner or permissions on C:\\\\Users\\\\tester/.ssh/config.d/${name}" >&2
    exit 255
  fi
done
if [[ ${mode} == legacy ]]; then
  echo 'debug1: Reading configuration data C:\\Users\\tester/dotfiles/ssh_config' >&2
fi
exit 0
EOF
  } >"${c}/bin/ssh.exe"
  chmod +x "${c}/bin/ssh.exe"
  echo "${c}"
}

# $1: ケース、$2: 1 なら偽の ssh.exe を PATH に置かない、残り: script の引数。
# FAKE_SSH_MODE・BOOTSTRAP_SSH_CHECK_TIMEOUT は呼び出し側で付ける。
run() {
  local c=$1 nossh=$2
  shift 2
  local path="${c}/bin:${sys_bin}"
  if [[ ${nossh} == 1 ]]; then
    path="${sys_bin}"
  fi
  env HOME="${c}/home" PATH="${path}" DOTFILES_PRIVATE_DIR="${c}/private" FAKE_WIN_HOME="${c}/win" \
    "${BASH}" "${script}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
wssh() { printf '%s' "$1/win/.ssh"; }
record() { cat "$1/home/.local/state/dotfiles/windows-ssh-config.deployed.json" 2>/dev/null; }
same_file() { cmp -s "$1" "$2"; }
baks() { find "$(wssh "$1")" -name '*.dotfiles-bak-*' | wc -l; }

# 配って、1 回目の結果を確かめずに進める (2 回目以降のケースの下ごしらえ)
deploy() {
  run "$1" 0
}

echo "== bootstrap-windows-ssh-config.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
c=$(new_case t1 "")
run "${c}" 0
if [[ $(rc "${c}") == 0 && ! -e $(wssh "${c}") ]] && outerr "${c}" | grep -q '飛ばします'; then
  ok "windows-files.json が無ければ何も書かずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 2. enable = false: 飛ばす
c=$(new_case t2 "${state_off}")
run "${c}" 0
if [[ $(rc "${c}") == 0 && ! -e $(wssh "${c}") ]] && outerr "${c}" | grep -q '配りません'; then
  ok "enable = false なら何も書かない"
else
  ng "enable = false" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 3. 正本 (ssh/) が無い: 今ある config に触らず exit 0
c=$(new_case t3 "${state_on}")
mkdir -p "$(wssh "${c}")"
printf 'Include ~/dotfiles/ssh_config\n' >"$(wssh "${c}")/config"
rm -rf "${c}/private/ssh"
run "${c}" 0
if [[ $(rc "${c}") == 0 && $(cat "$(wssh "${c}")/config") == 'Include ~/dotfiles/ssh_config' && -z $(record "${c}") ]] \
  && grep -q '正本の \*.ssh_config がありません' "${c}/err"; then
  ok "正本が無ければ今ある config に触らず exit 0"
else
  ng "正本が無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 4. 正本が空: 同じ
mkdir -p "${c}/private/ssh"
run "${c}" 0
if [[ $(rc "${c}") == 0 && $(cat "$(wssh "${c}")/config") == 'Include ~/dotfiles/ssh_config' && -z $(record "${c}") ]]; then
  ok "正本が空でも今ある config に触らず exit 0"
else
  ng "正本が空" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 5. 初回: config と *.ssh_config (通常のファイル) だけをコピーし、記録を相対パスで書く
c=$(new_case t5 "${state_on}")
run "${c}" 0
if [[ $(rc "${c}") == 0 && $(cat "$(wssh "${c}")/config") == "${config_want}" ]] \
  && same_file "$(wssh "${c}")/config.d/a.ssh_config" "${c}/private/ssh/a.ssh_config" \
  && same_file "$(wssh "${c}")/config.d/b c.ssh_config" "${c}/private/ssh/b c.ssh_config" \
  && [[ ! -e $(wssh "${c}")/config.d/README.md && ! -e $(wssh "${c}")/config.d/x.ssh_config && ! -e $(wssh "${c}")/config.d/link.ssh_config ]] \
  && [[ $(record "${c}" | jq -r '.version') == 1 ]] \
  && [[ $(record "${c}" | jq -r '.files | keys | join(",")') == 'config,config.d/a.ssh_config,config.d/b c.ssh_config' ]] \
  && grep -q '確かめ: ssh.exe が config と config.d の 2 件を読んだ' "${c}/out"; then
  ok "初回に config と ssh/ 直下の *.ssh_config をコピーし、記録を相対パスで書いて確かめる"
else
  ng "初回" "rc=$(rc "${c}") $(outerr "${c}") $(record "${c}")"
fi

# 6. 2 回目: 1 行で済ませる
run "${c}" 0
if [[ $(rc "${c}") == 0 && $(wc -l <"${c}/out") == 1 && ! -s ${c}/err ]] \
  && grep -q '揃っています (config と config.d の 2 件。ssh.exe が読むことも確かめた)' "${c}/out"; then
  ok "揃っていれば 1 行で済ませる"
else
  ng "2 回目" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 7. 旧経路の Include の 1 行 (BOM・CRLF・空白・空行つき) は置き換え、ツールのファイルには触らない
c=$(new_case t7 "${state_on}")
mkdir -p "$(wssh "${c}")/config.d"
printf '\xEF\xBB\xBF\r\n  Include ~/dotfiles/ssh_config  \r\n\r\n' >"$(wssh "${c}")/config"
printf 'Host tool\n' >"$(wssh "${c}")/config.d/gcp-tool.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 0 && $(cat "$(wssh "${c}")/config") == "${config_want}" ]] \
  && [[ $(cat "$(wssh "${c}")/config.d/gcp-tool.ssh_config") == 'Host tool' ]] \
  && [[ $(record "${c}" | jq -r '.files | has("config.d/gcp-tool.ssh_config")') == false ]] \
  && grep -q 'config: 置き換え (旧経路の Include' "${c}/out" && [[ $(baks "${c}") == 0 ]]; then
  ok "旧経路の Include の 1 行は置き換え、ツールのファイルには触らない"
else
  ng "旧経路の Include" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 8. 手書きの config は衝突。--force で退避して上書きする
c=$(new_case t8 "${state_on}")
mkdir -p "$(wssh "${c}")"
printf 'Include ~/dotfiles/ssh_config\nHost mine\n  User me\n' >"$(wssh "${c}")/config"
run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q 'Host mine' "$(wssh "${c}")/config" \
  && grep -q '⚠️' "${c}/err" && grep -q -- '+Include config.d/\*.ssh_config' "${c}/err" \
  && [[ $(record "${c}" | jq -r '.files | has("config")') == false ]]; then
  ok "手書きの config は衝突として触らず、diff と ⚠ の枠を出して exit 1"
else
  ng "手書きの config" "rc=$(rc "${c}") $(outerr "${c}")"
fi
run "${c}" 0 --force
bak=$(find "$(wssh "${c}")" -name 'config.dotfiles-bak-*' | head -1)
if [[ $(rc "${c}") == 0 && $(cat "$(wssh "${c}")/config") == "${config_want}" && -n ${bak} ]] && grep -q 'Host mine' "${bak}"; then
  ok "--force は元を config.dotfiles-bak-<日時> に退避して上書きする"
else
  ng "--force" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 9. 正本の更新は上書きする
c=$(new_case t9 "${state_on}")
deploy "${c}"
printf 'Host a\n  HostName a2.example.test\n' >"${c}/private/ssh/a.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 0 ]] && same_file "$(wssh "${c}")/config.d/a.ssh_config" "${c}/private/ssh/a.ssh_config" \
  && grep -q 'config.d/a.ssh_config: 上書き (正本が更新された)' "${c}/out"; then
  ok "正本が更新されたら上書きする"
else
  ng "正本の更新" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 10. Windows で変えたファイルは衝突。--force で退避して上書きする
printf 'Host a\n  User edited\n' >"$(wssh "${c}")/config.d/a.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q 'User edited' "$(wssh "${c}")/config.d/a.ssh_config"; then
  ok "Windows で変えたファイルは衝突として触らない"
else
  ng "Windows での変更" "rc=$(rc "${c}") $(outerr "${c}")"
fi
run "${c}" 0 --force
if [[ $(rc "${c}") == 0 ]] && same_file "$(wssh "${c}")/config.d/a.ssh_config" "${c}/private/ssh/a.ssh_config" \
  && [[ $(find "$(wssh "${c}")/config.d" -name 'a.ssh_config.dotfiles-bak-*' | wc -l) == 1 ]]; then
  ok "--force は Windows で変えたファイルを退避して上書きする"
else
  ng "--force (Windows での変更)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 11. 正本から消えたファイルは消す。Windows で変えていれば衝突、--force で退避して消す
c=$(new_case t11 "${state_on}")
deploy "${c}"
rm "${c}/private/ssh/b c.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 0 && ! -e "$(wssh "${c}")/config.d/b c.ssh_config" ]] \
  && [[ $(record "${c}" | jq -r '.files | has("config.d/b c.ssh_config")') == false ]] \
  && grep -q 'config.d/b c.ssh_config: 削除 (正本から消えた)' "${c}/out"; then
  ok "正本から消えたファイルを消し、記録から外す"
else
  ng "正本から消えた" "rc=$(rc "${c}") $(outerr "${c}")"
fi
printf 'Host b\n' >"${c}/private/ssh/b c.ssh_config"
deploy "${c}"
printf 'Host b\n  User edited\n' >"$(wssh "${c}")/config.d/b c.ssh_config"
rm "${c}/private/ssh/b c.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 1 && -e "$(wssh "${c}")/config.d/b c.ssh_config" ]]; then
  ok "正本から消えても Windows で変えていれば衝突として消さない"
else
  ng "消えた + 変えた" "rc=$(rc "${c}") $(outerr "${c}")"
fi
run "${c}" 0 --force
if [[ $(rc "${c}") == 0 && ! -e "$(wssh "${c}")/config.d/b c.ssh_config" ]] \
  && [[ $(find "$(wssh "${c}")/config.d" -name 'b c.ssh_config.dotfiles-bak-*' | wc -l) == 1 ]]; then
  ok "--force は退避してから消す"
else
  ng "--force (消えた + 変えた)" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 12. 同じ名前のファイル: 中身が同じなら記録だけ、違えば衝突
c=$(new_case t12 "${state_on}")
mkdir -p "$(wssh "${c}")/config.d"
cp "${c}/private/ssh/a.ssh_config" "$(wssh "${c}")/config.d/a.ssh_config"
printf 'Host other\n' >"$(wssh "${c}")/config.d/b c.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && [[ $(record "${c}" | jq -r '.files | has("config.d/a.ssh_config")') == true ]] \
  && [[ $(cat "$(wssh "${c}")/config.d/b c.ssh_config") == 'Host other' ]] \
  && [[ $(record "${c}" | jq -r '.files | has("config.d/b c.ssh_config")') == false ]]; then
  ok "同じ名前のファイルは、中身が同じなら記録だけ、違えば衝突にする"
else
  ng "同じ名前" "rc=$(rc "${c}") $(outerr "${c}") $(record "${c}")"
fi

# 13. --dry-run は何も書かない
c=$(new_case t13 "${state_on}")
run "${c}" 0 --dry-run
if [[ $(rc "${c}") == 0 && ! -e $(wssh "${c}") && -z $(record "${c}") ]] && grep -q '\[dry-run\]' "${c}/out"; then
  ok "--dry-run は判定だけ出して何も書かない"
else
  ng "--dry-run" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 14. 確かめ: Bad owner or permissions は exit 1
c=$(new_case t14 "${state_on}")
FAKE_SSH_MODE=badowner run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q 'アクセス権' "${c}/err" && grep -q 'icacls.exe' "${c}/err"; then
  ok "確かめで Bad owner or permissions が出たら ⚠ の枠で出して exit 1"
else
  ng "Bad owner" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 15. 確かめ: 読まれないファイルがあれば exit 1
c=$(new_case t15 "${state_on}")
FAKE_SSH_MODE=missing run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q '読まなかったファイル' "${c}/err" && grep -q 'config.d/a.ssh_config' "${c}/err"; then
  ok "確かめで読まれないファイルがあれば exit 1"
else
  ng "読まれないファイル" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 16. 確かめ: 旧 clone の ssh_config を読んでいれば exit 1
c=$(new_case t16 "${state_on}")
FAKE_SSH_MODE=legacy run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q '旧 clone の ssh_config' "${c}/err"; then
  ok "確かめで旧 clone の ssh_config を読んでいれば exit 1"
else
  ng "旧 clone" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 17. 確かめ: ssh.exe を呼べない (Exec format error) は手で打つコマンドを出して exit 0
c=$(new_case t17 "${state_on}")
FAKE_SSH_MODE=broken run "${c}" 0
if [[ $(rc "${c}") == 0 ]] && grep -q "Select-String 'Reading configuration'" "${c}/err" \
  && [[ $(cat "$(wssh "${c}")/config") == "${config_want}" ]]; then
  ok "ssh.exe を呼べなければ、書いたうえで手で打つコマンドを出して exit 0"
else
  ng "呼べない" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 18. 確かめ: ssh.exe が無い
c=$(new_case t18 "${state_on}")
run "${c}" 1
if [[ $(rc "${c}") == 0 ]] && grep -q 'ssh.exe が見つからない' "${c}/err" && grep -q "Select-String" "${c}/err"; then
  ok "ssh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "ssh.exe が無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 19. 確かめ: ssh.exe が固まったら待つのをやめる
c=$(new_case t19 "${state_on}")
FAKE_SSH_MODE=hang BOOTSTRAP_SSH_CHECK_TIMEOUT=1 run "${c}" 0
if [[ $(rc "${c}") == 0 ]] && grep -q '確かめられませんでした (終了コード 124' "${c}/err"; then
  ok "ssh.exe が固まったら待つのをやめ、手で打つコマンドを出して exit 0"
else
  ng "固まる" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 20. 確かめ: ssh.exe の出すパスの区切り (\ と /) と大文字小文字の違いは同じとみなす
c=$(new_case t20 "${state_on}")
FAKE_SSH_MODE=backslash run "${c}" 0
if [[ $(rc "${c}") == 0 ]] && grep -q '確かめ: ssh.exe が config と config.d の 2 件を読んだ' "${c}/out"; then
  ok "ssh.exe の出すパスの区切りと大文字小文字の違いは同じとみなす"
else
  ng "区切りと大小" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 21. 記録が壊れている: 書かずに exit 1
c=$(new_case t21 "${state_on}")
printf 'not json\n' >"${c}/home/.local/state/dotfiles/windows-ssh-config.deployed.json"
run "${c}" 0
if [[ $(rc "${c}") == 1 && ! -e $(wssh "${c}") ]]; then
  ok "記録が壊れていれば書かずに exit 1"
else
  ng "壊れた記録" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 22. 知らない引数: exit 2
c=$(new_case t22 "${state_on}")
run "${c}" 0 --bogus
if [[ $(rc "${c}") == 2 && ! -e $(wssh "${c}") ]]; then
  ok "知らない引数は何もせず exit 2"
else
  ng "知らない引数" "rc=$(rc "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `bash nix/tests/bootstrap-windows-ssh-config.test.sh`
Expected: script が無いので `== 0 passed, 26 failed` で終わる (終了コード 1)

- [ ] **Step 3: script を書く**

`nix/scripts/bootstrap-windows-ssh-config.sh` を次の中身で作り、`chmod +x nix/scripts/bootstrap-windows-ssh-config.sh` する:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh\config.d へコピーし、config を置く (冪等。更新時も毎回走る)。
#
# order: 91
#
# ^ setup.sh が読む実行順。コピー元を取る bootstrap-dotfiles-private.sh (order: 50) より後に
#   走ればよい。衝突や確かめの失敗で exit 1 すると setup はここで止まる (後ろの 95〜98 と
#   exe-exec-trace は、直して流し直すまで走らない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# 1Password を使う WSL のマシンでは、WSL の ssh は Windows の ssh.exe を呼ぶラッパーで
# (ADR 004)、ssh.exe は Windows 側の %USERPROFILE%\.ssh\config を読む。そこにも WSL と同じ形
# (config は Include の 1 行、接続先は config.d) を作る (docs/adr/016_ssh_config_from_dotfiles_private_*)。
# 優先順位も WSL と同じく、config.d のファイル名の順になる。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く)。bootstrap-windows-files.sh
#   と同じく、無ければ飛ばし、enable が false なら何もしない
# - dotfiles-private の ssh/ 直下の *.ssh_config (通常のファイルだけ)。場所の決め方は
#   bootstrap-dotfiles-private.sh と同じ。無い・空なら、何も書かず消さずに警告して exit 0
# - ~/.local/state/dotfiles/windows-ssh-config.deployed.json (前回置いた中身の sha256)。
#   {"version":1,"files":{"<.ssh からの相対パス>":"<sha256>"}} の形
#
# ## 何をするか
#
# config と config.d/<名前>.ssh_config の 1 つずつを、置き先の中身と記録で判定する:
#
#   置き先が無い                            コピーする
#   置き先が正本と同じ中身                  何もしない (記録が無ければ記録だけする)
#   置き先が記録と同じ中身 (正本とは違う)   正本が更新された。上書きする
#   config が旧経路の Include の 1 行だけ  置き換える (ADR 013 で消した旧経路からの移行)
#   それ以外                                衝突。diff を出して触らない (--force なら退避して上書き)
#
# 記録にあって正本から消えたファイルは、置き先が記録と同じなら消す。違えば衝突 (--force なら
# 退避して消す)。記録に無いファイル (my-cloud などが書いたもの) には触らない。
# 退避は <名前>.dotfiles-bak-<日時>、一時ファイルは <名前>.dotfiles-tmp.XXXXXX で、どちらも
# *.ssh_config で終わらないので Include されない。
#
# 書いたあとに ssh.exe -v -G nonexistent.invalid を流して、読んだファイルを確かめる (TKT-147)。
# Bad owner or permissions が出た・置いたファイルが読まれない・旧 clone の ssh_config を読んだ、
# のどれかなら、衝突と同じく ⚠ の枠で出して exit 1。ssh.exe を呼べない (interop が外れている
# など) ときは、手で打つコマンドを出して exit 0。

set -eu -o pipefail

usage() {
  cat <<'EOS'
dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh へコピーし、config を置く。

使い方:
  bootstrap-windows-ssh-config.sh            配る (書いたあとに ssh.exe で読ませて確かめる)
  bootstrap-windows-ssh-config.sh --dry-run  判定だけ出して何も書かない (確かめも流さない)
  bootstrap-windows-ssh-config.sh --force    衝突も、元を <名前>.dotfiles-bak-<日時> に退避して上書き・削除する
EOS
}

force=0
dry_run=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-ssh-config.deployed.json"
legacy_line='Include ~/dotfiles/ssh_config'
# 確かめで ssh.exe を待つ秒数 (テストで縮める)
check_timeout=${BOOTSTRAP_SSH_CHECK_TIMEOUT:-30}

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

warn() {
  printf '!! %s\n' "$*" >&2
}

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

# Windows の config の中身。WSL の Nix 管理の ~/.ssh/config (home/modules/ssh.nix の
# programs.ssh.includes) と同じ Include の 1 行に、持ち主を示すコメントを添える。
config_body() {
  cat <<'EOF'
# dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
# マシン固有の Host は config.d\ に <名前>.ssh_config として置く。
# config.d はファイル名の順に読み、同じキーは先に読んだ値が効く。
Include config.d/*.ssh_config
EOF
}

# ssh.exe で確かめられなかったときに、同じことを手で確かめるコマンドを出す
manual_check() {
  echo "   Windows の PowerShell で次を打つと、読んだファイルを確かめられます:" >&2
  echo "     ssh -v -G nonexistent.invalid 2>&1 | Select-String 'Reading configuration'" >&2
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${state_file} ]]; then
  echo "!! 配り先の設定がありません: ${state_file}" >&2
  echo "   dotfiles.wsl.windowsFiles を持つ世代へ先に home-manager switch してください。" >&2
  echo "   この手順は飛ばします。" >&2
  exit 0
fi
if ! jq -e 'type == "object"' "${state_file}" >/dev/null 2>&1; then
  echo "${state_file} が JSON の object ではありません。" >&2
  exit 1
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  echo "  /mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。" >&2
  exit 1
fi
if ! command -v sha256sum &>/dev/null; then
  echo "sha256sum が見つかりません (coreutils)。置き先の中身を比べられないので配れません。" >&2
  exit 1
fi

src_dir="$(private_dir)/ssh"
win_ssh="${windows_home}/.ssh"

srcs=()
if [[ -d ${src_dir} ]]; then
  for src in "${src_dir}"/*.ssh_config; do
    if [[ -f ${src} && ! -L ${src} ]]; then
      srcs+=("${src}")
    fi
  done
fi
if ((${#srcs[@]} == 0)); then
  warn "Windows の ssh の設定を配りません: 正本の *.ssh_config がありません (${src_dir})。"
  echo "   dotfiles-private を取れていないか、ssh/ が空です。Windows 側のファイルはそのまま残します。" >&2
  echo "   取るには: ${script_dir}/bootstrap-dotfiles-private.sh" >&2
  exit 0
fi

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object" and (.files | type == "object")' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (files を持つ JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます" >&2
    echo "   (中身を確かめて、dotfiles-private へ取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{"version":1,"files":{}}'
fi

work=$(mktemp -d)
tmp_file=""
trap 'rm -rf "${work}"; if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT
config_body >"${work}/config"

# 計画: .ssh からの相対パスと、そのコピー元
plan_rel=(config)
plan_src=("${work}/config")
for src in "${srcs[@]}"; do
  plan_rel+=("config.d/$(basename "${src}")")
  plan_src+=("${src}")
done

sha() {
  sha256sum <"$1" | cut -d' ' -f1
}
recorded() {
  jq -r --arg k "$1" '.files[$k] // ""' <<<"${records}"
}
remember() {
  records=$(jq -c --arg k "$1" --arg v "$2" '.files[$k] = $v' <<<"${records}")
}
forget() {
  records=$(jq -c --arg k "$1" 'del(.files[$k])' <<<"${records}")
}
in_plan() {
  local p
  for p in "${plan_rel[@]}"; do
    if [[ ${p} == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# 置き先と同じディレクトリの一時ファイルに書いてから mv する。$1 = コピー元、$2 = 置き先。
place() {
  mkdir -p "$(dirname -- "$2")"
  tmp_file=$(mktemp "$2.dotfiles-tmp.XXXXXX")
  cp -- "$1" "${tmp_file}"
  mv -f -- "${tmp_file}" "$2"
  tmp_file=""
}

# --force で上書き・削除する前に、元を <名前>.dotfiles-bak-<日時> に残す
backup() {
  local bak
  bak="$1.dotfiles-bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$1" "${bak}"
  log+=("  退避した: ${bak}")
}

# config が旧経路の Include の 1 行だけか。BOM・CR・行の前後の空白・空行は無視する。
is_legacy_config() {
  local body
  body=$(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -- "$1" | grep -v '^$' || true)
  [[ ${body} == "${legacy_line}" ]]
}

log=()
conflicts=()
changed=0
pre=""
if ((dry_run)); then
  pre="[dry-run] "
fi

for i in "${!plan_rel[@]}"; do
  rel=${plan_rel[i]}
  src=${plan_src[i]}
  dst="${win_ssh}/${rel}"
  want=$(sha "${src}")
  rec=$(recorded "${rel}")

  if [[ -d ${dst} ]]; then
    warn "置き先がディレクトリです: ${dst}"
    conflicts+=("${rel} (ディレクトリ)")
    continue
  fi

  if [[ ! -e ${dst} ]]; then
    action=copy
  else
    have=$(sha "${dst}")
    if [[ ${have} == "${want}" ]]; then
      action=same
    elif [[ -n ${rec} && ${have} == "${rec}" ]]; then
      action=update
    elif [[ ${rel} == config ]] && is_legacy_config "${dst}"; then
      action=legacy
    elif ((force)); then
      action=force
    else
      action=conflict
    fi
  fi

  case ${action} in
    same)
      if [[ ${rec} != "${want}" ]] && ((! dry_run)); then
        remember "${rel}" "${want}"
      fi
      ;;
    conflict)
      conflicts+=("${rel}")
      {
        echo "!! 衝突: ${dst} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
        diff -u --label "${rel} (Windows 側)" --label "${rel} (dotfiles)" -- "${dst}" "${src}" || true
      } >&2
      ;;
    copy | update | legacy | force)
      case ${action} in
        copy) label="コピー" ;;
        update) label="上書き (正本が更新された)" ;;
        legacy) label="置き換え (旧経路の Include ~/dotfiles/ssh_config)" ;;
        force) label="上書き (--force)" ;;
      esac
      if ((! dry_run)); then
        if [[ ${action} == force ]]; then
          backup "${dst}"
        fi
        place "${src}" "${dst}"
        remember "${rel}" "${want}"
      fi
      log+=("  ${pre}${rel}: ${label}")
      changed=$((changed + 1))
      ;;
  esac
done

# 記録にあって、正本から消えたファイル
while IFS= read -r rel; do
  if [[ -z ${rel} ]] || in_plan "${rel}"; then
    continue
  fi
  dst="${win_ssh}/${rel}"
  rec=$(recorded "${rel}")
  if [[ ! -e ${dst} ]]; then
    if ((! dry_run)); then
      forget "${rel}"
    fi
    continue
  fi
  have=$(sha "${dst}")
  if [[ ${have} != "${rec}" ]] && ((! force)); then
    conflicts+=("${rel} (正本から消えた)")
    echo "!! 衝突: ${dst} は正本から消えましたが、Windows 側で変わっているので消していません。" >&2
    continue
  fi
  if ((! dry_run)); then
    if [[ ${have} != "${rec}" ]]; then
      backup "${dst}"
    fi
    rm -f -- "${dst}"
    forget "${rel}"
  fi
  log+=("  ${pre}${rel}: 削除 (正本から消えた)")
  changed=$((changed + 1))
done < <(jq -r '.files | keys[]' <<<"${records}")

# 記録を書く (変わったときだけ。--dry-run では書かない)
if ((! dry_run)); then
  new_records=$(jq -S '.version = 1' <<<"${records}")
  old_records=""
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  fi
  if [[ ${new_records} != "${old_records}" ]]; then
    mkdir -p "${state_dir}"
    tmp_file=$(mktemp "${record_file}.XXXXXX")
    printf '%s\n' "${new_records}" >"${tmp_file}"
    mv -f -- "${tmp_file}" "${record_file}"
    tmp_file=""
  fi
fi

# 書いたあとの確かめ (TKT-147): ssh.exe に読ませて、読んだファイルを見る
check_failed=()
checked=0
if ((! dry_run)); then
  expect=()
  for rel in "${plan_rel[@]}"; do
    if [[ -f ${win_ssh}/${rel} ]]; then
      expect+=("${rel}")
    fi
  done
  if ! command -v ssh.exe &>/dev/null; then
    warn "ssh.exe が見つからないので、Windows の ssh が読むファイルを確かめていません。"
    manual_check
  else
    rc=0
    out=$(timeout "${check_timeout}" ssh.exe -v -G nonexistent.invalid </dev/null 2>&1 >/dev/null) || rc=$?
    out=$(printf '%s\n' "${out}" | tr -d '\r')
    if grep -q 'Bad owner or permissions' <<<"${out}"; then
      check_failed+=("ssh.exe がアクセス権を理由に設定を読みませんでした (どの接続先でも exit 255 になります):")
      while IFS= read -r line; do
        check_failed+=("  ${line}")
      done < <(grep -E 'Bad (owner|permissions)' <<<"${out}")
      check_failed+=("  .ssh の ACL を見る: icacls.exe '$(wslpath -w "${win_ssh}" 2>/dev/null || printf '%s' "${win_ssh}")'")
    elif ! grep -q 'Reading configuration data' <<<"${out}"; then
      warn "ssh.exe で確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません)。"
      if [[ -n ${out} ]]; then
        printf '%s\n' "${out}" | head -5 | sed 's/^/   /' >&2
      fi
      manual_check
    else
      # ssh.exe は C:\\Users\\<名前>/.ssh/config のように出すので、/ 区切りの小文字に揃えて末尾で比べる
      read_paths=$(sed -n 's/^debug1: Reading configuration data //p' <<<"${out}" \
        | sed -e 's#\\#/#g' -e 's#//*#/#g' | tr '[:upper:]' '[:lower:]')
      missing=()
      for rel in "${expect[@]}"; do
        suffix=$(printf '/.ssh/%s' "${rel}" | tr '[:upper:]' '[:lower:]')
        found=0
        while IFS= read -r p; do
          if [[ ${p} == *"${suffix}" ]]; then
            found=1
            break
          fi
        done <<<"${read_paths}"
        if ((! found)); then
          missing+=("${rel}")
        fi
      done
      if ((${#missing[@]} > 0)); then
        check_failed+=("ssh.exe が読まなかったファイルがあります (Include されていない):")
        for rel in "${missing[@]}"; do
          check_failed+=("  ${win_ssh}/${rel}")
        done
      fi
      if grep -q '/dotfiles/ssh_config$' <<<"${read_paths}"; then
        check_failed+=("ssh.exe が旧 clone の ssh_config を読んでいます (config が旧経路の Include のまま)。")
      fi
      checked=1
    fi
  fi
fi

n=$((${#plan_rel[@]} - 1))
if ((changed == 0 && ${#conflicts[@]} == 0 && ${#check_failed[@]} == 0)); then
  if ((checked)); then
    echo "Windows の ssh の設定は揃っています (config と config.d の ${n} 件。ssh.exe が読むことも確かめた)。"
  else
    echo "Windows の ssh の設定は揃っています (config と config.d の ${n} 件)。"
  fi
  exit 0
fi

echo "==> ${pre}Windows の ssh の設定 (${win_ssh})"
if ((${#log[@]} > 0)); then
  printf '%s\n' "${log[@]}"
fi
if ((checked && ${#check_failed[@]} == 0)); then
  echo "  確かめ: ssh.exe が config と config.d の ${n} 件を読んだ (旧 clone の ssh_config は読んでいない)"
fi

if ((${#conflicts[@]} == 0 && ${#check_failed[@]} == 0)); then
  exit 0
fi

rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
{
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  printf '%s⚠️  Windows の ssh の設定に、手で直すことがあります%s\n' "${c_warn}" "${c_reset}"
  if ((${#conflicts[@]} > 0)); then
    printf '%s⚠️  Windows 側で変わっていたので、次のファイルには触っていません (diff は上):%s\n' "${c_warn}" "${c_reset}"
    for rel in "${conflicts[@]}"; do
      printf '%s⚠️    %s%s\n' "${c_warn}" "${rel}" "${c_reset}"
    done
    printf '%s⚠️  解き方 (どちらか):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    1. Windows で直した中身を dotfiles-private の ssh/ へ取り込み、commit して push する%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       (config に手で書いた Host は config.d\\<名前>.ssh_config へ移す)%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    2. 上書きする (元は <名前>.dotfiles-bak-<日時> に残る):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-ssh-config.sh --force%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
  fi
  for line in "${check_failed[@]}"; do
    printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
  done
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
} >&2
exit 1
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `bash nix/tests/bootstrap-windows-ssh-config.test.sh`
Expected: `== 26 passed, 0 failed`

- [ ] **Step 5: flake の checks に載せ、サンドボックスでも通ることを確かめる**

`nix/flake.nix` の `bootstrap-ssh-config-test = scriptTest …;` の行の下に足す:

```nix
          bootstrap-windows-ssh-config-test = scriptTest "bootstrap-windows-ssh-config" ./scripts/bootstrap-windows-ssh-config.sh;
```

```bash
git add nix/scripts/bootstrap-windows-ssh-config.sh nix/tests/bootstrap-windows-ssh-config.test.sh nix/flake.nix
nix build ./nix#checks.x86_64-linux.bootstrap-windows-ssh-config-test -L --no-link
```

Expected: build が成功し、ログの最後に `== 26 passed, 0 failed` が出る

- [ ] **Step 6: lint を通す**

```bash
nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-ssh-config.sh nix/tests/bootstrap-windows-ssh-config.test.sh && shellcheck nix/scripts/bootstrap-windows-ssh-config.sh nix/tests/bootstrap-windows-ssh-config.test.sh && nixfmt --check nix/flake.nix && echo lint-ok'
```

Expected: `lint-ok`

- [ ] **Step 7: commit する**

```bash
git commit -F - <<'EOF'
feat(nix): dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh へ配る bootstrap-windows-ssh-config.sh を足す (TKT-145)

config を WSL と同じ Include config.d/*.ssh_config の 1 行にし、config.d へコピーして、置いた中身を
windows-ssh-config.deployed.json に覚える (order 91)。判定は bootstrap-windows-files.sh と同じで、
旧経路の Include の 1 行は置き換え、正本から消えたファイルは消し、--force は退避してから上書きする。
書いたあとに ssh.exe -v -G で読んだファイルを確かめる。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
```

---

### Task 4: setup の ssh-config 手順と .ssh submodule を外し、説明を直す

**Files:**
- Modify: `nix/scripts/setup.sh` (`add_step ssh-config` の塊・preset 2 つ・`run_step`・`pull_repo`)
- Delete: `nix/scripts/setup-ssh-config.sh`、`.gitmodules`、`.ssh` (gitlink)
- Modify: `nix/home/modules/ssh.nix` (コメント)、`nix/scripts/bootstrap-dotfiles-private.sh` (説明と文)、`nix/files/claude/skills/pjp-dotfiles-update/SKILL.md`

**Interfaces:**
- Consumes: Task 2 の `bootstrap-ssh-config.sh` (setup が `bootstrap-*` として自動で並べる)
- Produces: setup の手順 id から `ssh-config` が消える。`--list` の並びは `… bootstrap-claude-accounts → bootstrap-ssh-config → bootstrap-windows-files → bootstrap-windows-powertoys → bootstrap-windows-ssh-config → bootstrap-windows-powershell-profile …`

- [ ] **Step 1: 今の setup の手順を控える**

Run: `bash nix/scripts/setup.sh --list > /tmp/setup-list-before.txt; grep -c 'ssh-config' /tmp/setup-list-before.txt`
Expected: `1` (`ssh-config  ./nix/scripts/setup-ssh-config.sh` の行)

- [ ] **Step 2: `add_step ssh-config` の塊を消す**

`nix/scripts/setup.sh` から次の 5 行 (末尾の空行を含む) を消す:

```bash
add_step ssh-config \
  './nix/scripts/setup-ssh-config.sh' \
  '.ssh submodule を ~/.ssh/config.d/ へ張る。submodule 更新後の張り直しにも使う。' \
  step 0

```

- [ ] **Step 3: preset の `ids` から `ssh-config` を外す**

```diff
-      ids=(nix-install preflight-unlink local-flake ssh-config switch)
+      ids=(nix-install preflight-unlink local-flake switch)
```

```diff
       # 「何が増えたか」を人間が覚えている必要があった。
-      # ssh-config も同じ理由で入っている (.ssh submodule を更新したら張り直す)。
       #
```

```diff
-      ids=(ssh-config switch)
+      ids=(switch)
```

- [ ] **Step 4: `run_step` の対応を消す**

```diff
     local-flake) step_local_flake ;;
-    ssh-config) step_script setup-ssh-config.sh ;;
     flake-update) step_flake_update ;;
```

- [ ] **Step 5: `pull_repo` の `--ignore-submodules=all` を外す**

```diff
-  # --ignore-submodules=all: .ssh は別リポジトリで nix 経路とは関係が無く、
-  # そちらの状態で更新を止めたくない。
-  if ! git -C "${repo_dir}" diff --quiet --ignore-submodules=all \
-    || ! git -C "${repo_dir}" diff --cached --quiet --ignore-submodules=all; then
+  if ! git -C "${repo_dir}" diff --quiet \
+    || ! git -C "${repo_dir}" diff --cached --quiet; then
```

- [ ] **Step 6: setup-ssh-config.sh と submodule を消す**

```bash
git rm -q nix/scripts/setup-ssh-config.sh
git rm -q .ssh
git rm -q -f .gitmodules
git status --short
```

Expected: `D  .gitmodules`、`D  .ssh`、`D  nix/scripts/setup-ssh-config.sh` が並ぶ (`git rm .ssh` で `.gitmodules` が空の変更として stage されるので、`.gitmodules` は `-f` で消す)

- [ ] **Step 7: ssh.nix のコメントを直す**

`nix/home/modules/ssh.nix`:

```diff
-# 2. 実体は `.ssh` submodule にあり、**flake root (`nix/`) の外**なので
-#    そもそも flake から読めない。
+# 2. 実体は private な dotfiles-private (別の repo) の `ssh/` にあり、
+#    そもそも flake から読めない (docs/adr/016_ssh_config_from_dotfiles_private_*)。
 #
 # そこでここでは **Include の骨組みだけ**を生成し、中身は
-# `scripts/setup-ssh-config.sh` が `~/.ssh/config.d/` へ symlink する。
+# `scripts/bootstrap-ssh-config.sh` が `~/.ssh/config.d/` へ symlink する。
```

```diff
     # ここに置かれるもの:
-    #   - .ssh submodule の *.ssh_config (setup-ssh-config.sh が symlink)
+    #   - dotfiles-private の ssh/*.ssh_config (bootstrap-ssh-config.sh が symlink)
     #   - マシン固有の設定 (手で置く。git 管理外)
```

- [ ] **Step 8: bootstrap-dotfiles-private.sh の説明と文に ssh を足す**

`nix/scripts/bootstrap-dotfiles-private.sh`:

```diff
-# ^ setup.sh が読む実行順 (既定と同じ)。中身を読む bootstrap-windows-google-ime.sh (order: 98) より
-#   先に走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
+# ^ setup.sh が読む実行順 (既定と同じ)。中身を読む bootstrap-ssh-config.sh (order: 60)・
+#   bootstrap-windows-ssh-config.sh (order: 91)・bootstrap-windows-google-ime.sh (order: 98) より
+#   先に走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
```

```diff
-# 公開したくない設定 (今は Google 日本語入力のユーザー辞書) を、public なこの repo と分けて
-# private repo に置く (docs/adr/015_win_google_ime_powertoys_*)。flake input や submodule に
+# 公開したくない設定 (ssh の接続先と、Google 日本語入力のユーザー辞書) を、public なこの repo と分けて
+# private repo に置く (docs/adr/015_win_google_ime_powertoys_*・docs/adr/016_ssh_config_from_dotfiles_private_*)。flake input や submodule に
```

```diff
-  printf '   取れないあいだ、Google 日本語入力の辞書は配られません。\n' >&2
+  printf '   取れないあいだ、ssh の接続先と Google 日本語入力の辞書は配られません。\n' >&2
```

- [ ] **Step 9: pjp-dotfiles-update の skill の手順を直す**

`nix/files/claude/skills/pjp-dotfiles-update/SKILL.md`:

```diff
-- 走る手順は `ssh-config` → `flake-update` → `switch` → `bootstrap-*`
+- 走る手順は `flake-update` → `switch` → `bootstrap-*`
```

- [ ] **Step 10: setup の並びと既存のテストを確かめる**

```bash
bash nix/scripts/setup.sh --list > /tmp/setup-list-after.txt
grep -c '^  ssh-config' /tmp/setup-list-after.txt                       # 期待: 0
grep -n -E 'bootstrap-(claude-accounts|ssh-config|windows-files|windows-powertoys|windows-ssh-config|windows-powershell-profile) ' /tmp/setup-list-after.txt
grep -rn -E 'ssh-config\b|setup-ssh-config|ignore-submodules' nix/scripts nix/home nix/files nix/tests | grep -v -E 'bootstrap-(windows-)?ssh-config' || echo none
git add -A nix/scripts nix/home nix/files
nix build ./nix#checks.x86_64-linux.setup-post-notes-test ./nix#checks.x86_64-linux.bootstrap-dotfiles-private-test -L --no-link
```

Expected: 1 行目は `0`。2 行目は claude-accounts → ssh-config → windows-files → windows-powertoys → windows-ssh-config → windows-powershell-profile の順に行番号が増える。3 行目は `none`。build は 2 つとも成功する

- [ ] **Step 11: lint を通して commit する**

```bash
nix develop ./nix --command bash -c 'shfmt -d nix/scripts/setup.sh nix/scripts/bootstrap-dotfiles-private.sh && shellcheck nix/scripts/setup.sh nix/scripts/bootstrap-dotfiles-private.sh && nixfmt --check nix/home/modules/ssh.nix && echo lint-ok'
git commit -F - <<'EOF'
refactor(nix): setup の ssh-config 手順と .ssh submodule を外し、bootstrap-ssh-config.sh に任せる (TKT-145)

ssh-config 手順は switch より前、つまり dotfiles-private (order 50) を取る前に走るので外し、
order 60 の bootstrap-ssh-config.sh に置き換える。接続先は dotfiles-private の ssh/ へ移したので、
.ssh submodule・.gitmodules・setup-ssh-config.sh を消し、self-update の --ignore-submodules=all も外す。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
```

---

### Task 5: 文書を直す (nix/README.md・README.md・win/README.md・ADR)

**Files:**
- Modify: `nix/README.md` (自己更新の表・preset の表・「既存マシン更新」の段落 2 か所・order の表・新規マシンの手順表・「ssh について」・ディレクトリの一覧)
- Modify: `README.md` (ディレクトリの表)
- Modify: `win/README.md` (冒頭の表・「ssh の設定」の節)
- Modify: ADR 003 / 013 / 015 / 016 の `README.md`

**Interfaces:**
- Consumes: Task 2〜4 の script 名・order・振る舞い
- Produces: アンカー `win/README.md#ssh-の設定` (nix/README.md と ADR 016 から指す)

- [ ] **Step 1: nix/README.md の自己更新の表**

```diff
-| 未 commit の変更がある | 作業中の変更を巻き込みたくない（`.ssh` submodule の状態は見ない） |
+| 未 commit の変更がある | 作業中の変更を巻き込みたくない |
```

- [ ] **Step 2: nix/README.md の preset の表と段落**

```diff
-| 新しいマシン適用 | 1 → 2 → 2.5 → 2.6 → 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 |
-| 既存マシン更新 | 2.6 → 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 → 8（**冪等な手順は全部走る**。下記） |
+| 新しいマシン適用 | 1 → 2 → 2.5 → 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 |
+| 既存マシン更新 | 3 → 4 → 4.1 → 6 → 6.1 → 6.2 → 6.3 → 6.5 → 6.6 → 6.7 → 6.8 → 6.9 → 8（**冪等な手順は全部走る**。下記） |
```

```diff
-「既存マシン更新」は `switch` に加えて `ssh-config` と `bootstrap-*`、`exe-exec-trace` を
+「既存マシン更新」は `switch` に加えて `bootstrap-*` と `exe-exec-trace` を
```

```diff
-`ssh-config` と `bootstrap-*`、`exe-exec-trace` も走らせる（[前述](#まとめて実行する)。どれも冪等）。ホスト名を
+`bootstrap-*` と `exe-exec-trace` も走らせる（[前述](#まとめて実行する)。どれも冪等）。ホスト名を
```

- [ ] **Step 3: nix/README.md の order の表**

```diff
-| `bootstrap-dotfiles-private.sh` | 50 | private な dotfiles-private を取る。中身を読む `bootstrap-windows-google-ime.sh` (98) より先ならよい (既定と同じ値を書いてある) |
+| `bootstrap-dotfiles-private.sh` | 50 | private な dotfiles-private を取る。中身を読む `bootstrap-ssh-config.sh` (60)・`bootstrap-windows-ssh-config.sh` (91)・`bootstrap-windows-google-ime.sh` (98) より先ならよい (既定と同じ値を書いてある) |
 | `bootstrap-claude-accounts.sh` | 60 | `bootstrap-claude-skills.sh`（50）が `~/.claude/skills` へ張ったリンクを写す |
+| `bootstrap-ssh-config.sh` | 60 | dotfiles-private（50）の `ssh/*.ssh_config` を `~/.ssh/config.d/` へ張る（[後述](#ssh-について)） |
```

```diff
 | `bootstrap-windows-powertoys.sh` | 91 | `bootstrap-windows-files.sh` が置いた PowerToys の `default.json` を Keyboard Manager に読み直させる (exit 1 にしない) |
+| `bootstrap-windows-ssh-config.sh` | 91 | dotfiles-private（50）の `ssh/*.ssh_config` を Windows の `%USERPROFILE%\.ssh` へコピーし、`config` を置く。衝突や、書いたあとの確かめの失敗で exit 1 する（後ろの 95〜98 と exe-exec-trace は、直して流し直すまで走らない） |
```

- [ ] **Step 4: nix/README.md の新規マシンの手順表から 2.6 を外す**

```diff
-| 2.6 | `./nix/scripts/setup-ssh-config.sh` | `ssh-config` | `.ssh` submodule を `~/.ssh/config.d/` へ（[後述](#ssh-について)） |
```

- [ ] **Step 5: nix/README.md の「ssh について」を書き直す**

`## ssh について` から `### ⚠️ 既存の \`~/.ssh/config\` がある場合` の手前までを、次で置き換える:

````markdown
## ssh について

`programs.ssh` で `~/.ssh/config` を**生成**しているが、中身は Include の 1 行だけ。

```
Include config.d/*.ssh_config
```

（`ssh` は相対パスの `Include` を `~/.ssh/` 基準で解決する）

接続先の実体は private な [pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の
`ssh/*.ssh_config` にある（公開したくないので、この repo にも `/nix/store` にも置かない）。
`bootstrap-dotfiles-private.sh`（order 50）が clone / pull し、`bootstrap-ssh-config.sh`（order 60）が
`~/.ssh/config.d/` へ symlink する。どちらも `setup --update` で毎回走る。

```sh
./nix/scripts/bootstrap-ssh-config.sh
```

冪等。dotfiles-private を取れていない・`ssh/` が空なら、今ある symlink を外さずに警告だけ出す（処理は止めない）。

| `~/.ssh/config.d/` の中身 | 出所 |
| --- | --- |
| `*.ssh_config` (symlink) | dotfiles-private の `ssh/`。スクリプトが張る |
| それ以外 | 手で置いたマシン固有の設定や、ほかのツール（my-cloud など）が書いた設定。スクリプトは触らない |

正本からファイルが消えた場合、それを指す symlink はスクリプトが外す（以前の `.ssh` submodule を指す
symlink も外して張り替える）。手で置いたファイルや、ほかを指す symlink には触らず、同じ名前のものが
あれば上書きせずに警告する。

マシン固有の設定を足すときは `~/.ssh/config.d/` にファイルを置く。
`ssh` は同じキーワードについて**最初に得た値**を採るので、**ファイル名の順序が
優先順位**になる。実効値は `ssh -G <ホスト名>`、読んだファイルは `ssh -v -G <ホスト名>` の
`Reading configuration data` の行で確認できる。

Windows 側（`%USERPROFILE%\.ssh`）へは `bootstrap-windows-ssh-config.sh`（order 91）が同じ形で
コピーする。[`win/README.md`「ssh の設定」](../win/README.md#ssh-の設定) を参照。

````

- [ ] **Step 6: nix/README.md の ADR の参照と、WSL の ssh の節に 1 段落足す**

```diff
 > 設計の経緯（中身を Nix で配らない理由、退避を `--backup` に一本化した理由、
 > `config.d` へ移す案を棄却した実測）は
 > [ADR 003](../docs/adr/003_nix_ssh_config_20260810T210714JST/README.md) を参照。
+> 接続先を `.ssh` submodule から dotfiles-private へ移し、Windows へも配るようにした経緯は
+> [ADR 016](../docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)。
```

`### WSL では ssh 自体を Windows 側に差し替える` の、`USE_LINUX_SSH=1 ssh <ホスト名>` のコードブロックの直後に足す:

```markdown
このため、WSL の `ssh` が読む設定は Windows 側の `%USERPROFILE%\.ssh\config` になる（WSL 側の
`~/.ssh/config` が効くのは `USE_LINUX_SSH=1` のときだけ）。Windows 側の設定は
`bootstrap-windows-ssh-config.sh` が置く（[`win/README.md`「ssh の設定」](../win/README.md#ssh-の設定)）。
```

- [ ] **Step 7: nix/README.md のディレクトリの一覧**

```diff
     ├── setup-local-flake.sh        ~/dotfiles にローカル flake と setup の symlink を置く
-    ├── setup-ssh-config.sh         ~/.ssh/config.d/ を整える (switch より前)
     ├── verify.sh                   検証を一括実行する
```

```diff
     ├── bootstrap-dotfiles-private.sh  private な dotfiles-private を取得する (冪等。更新時も毎回走る。取れなくても止めない)
+    ├── bootstrap-ssh-config.sh     dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ張る (冪等。更新時も毎回走る。取れていなければ何もしない)
     ├── bootstrap-claude-accounts.sh  claude-personal / claude-work が使う ~/.claude-<名前>/ を用意する (冪等。更新時も毎回走る)
```

```diff
     ├── bootstrap-windows-powertoys.sh  win/ から配った PowerToys の割り当てを Keyboard Manager に読み直させる (冪等。更新時も毎回走る)
+    ├── bootstrap-windows-ssh-config.sh  dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh へコピーし、config を置く (冪等。更新時も毎回走る)
     ├── bootstrap-windows-powershell-profile.sh  win/ から配った dotfiles.ps1 を PowerShell 7 の $PROFILE から読ませる (冪等。更新時も毎回走る)
```

- [ ] **Step 8: README.md のディレクトリの表**

```diff
-| `.ssh` | ssh の接続先（private な submodule）。`setup` が `~/.ssh/config.d/` へ張る |
 | [`docs/adr/`](./docs/adr/README.md) | 決めたことと、その理由の記録 |
+
+ssh の接続先は private な [pollenjp/dotfiles-private](https://github.com/pollenjp/dotfiles-private) の `ssh/` に置き、
+`setup` が `~/.ssh/config.d/` へ張り、Windows の `%USERPROFILE%\.ssh` へはコピーする
+（[ADR 016](./docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)）。
```

- [ ] **Step 9: win/README.md の冒頭の表に 1 行、`## PowerToys` の手前に節を足す**

冒頭の表の `google-japanese-input/` の行の下に足す:

```markdown
| (dotfiles-private の `ssh/*.ssh_config`) | `%USERPROFILE%\.ssh\config` と `config.d\` | ssh の接続先。manifest では配らず、`bootstrap-windows-ssh-config.sh` がコピーする ([後述](#ssh-の設定)、[TKT-145](https://app.notion.com/p/Windows-OS-Windows-ssh-3f779149a66f81c4a2cff0233027c26e)) |
```

`## PowerToys` の見出しの直前に足す:

````markdown
## ssh の設定

1Password を使う WSL のマシンでは、WSL の `ssh` は Windows の `ssh.exe` を呼ぶ ([OpenSSH](#openssh))。
`ssh.exe` が読むのは Windows 側の `%USERPROFILE%\.ssh\config` なので、そこにも WSL と同じ形を置く
(経緯は [ADR 016](../docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md))。
`manifest.toml` では配らず、`nix/scripts/bootstrap-windows-ssh-config.sh` (order 91) が
`setup --update` のたびにコピーする。

| Windows 側 | 中身 | 出所 |
| --- | --- | --- |
| `%USERPROFILE%\.ssh\config` | `Include config.d/*.ssh_config` の 1 行と説明のコメント | script が置く |
| `%USERPROFILE%\.ssh\config.d\<名前>.ssh_config` | 接続先 | private な dotfiles-private の `ssh/` からコピー |
| `%USERPROFILE%\.ssh\config.d\` のほかのファイル | マシン固有の接続先 | my-cloud の `ssh-config.sh` などが書く。script は触らない |

- `config.d` はファイル名の順に読まれ、同じキーは先に読んだ値が効く (WSL と同じ)
- 置いたファイルは、中身の sha256 を WSL の `~/.local/state/dotfiles/windows-ssh-config.deployed.json` に覚える。
  正本が変われば上書きし、正本から消えれば消す
- 旧経路が置いた `Include ~/dotfiles/ssh_config` の 1 行だけの `config` は、衝突にせず置き換える
- 書いたあとに `ssh.exe -v -G nonexistent.invalid` を流し、`config` と置いたファイルが読まれること、
  旧 clone (`C:\Users\<名前>\dotfiles`) の `ssh_config` を読んでいないことを確かめる。アクセス権で弾かれる
  (`Bad owner or permissions`) などがあれば ⚠ の枠で出して止まる。ssh.exe を呼べないときは、手で打つ
  コマンドを出して進む

### ssh の設定が衝突したら

Windows で `config` や dotfiles のファイルを直していたら、触らずに diff を出して止まる。どちらかで解く。

1. 直した中身を dotfiles-private の `ssh/` へ取り込み、commit して push する。`config` に手で書いた
   `Host` は `config.d\<名前>.ssh_config` へ移す
2. 上書きする。元は `<名前>.dotfiles-bak-<日時>` に退避される (`*.ssh_config` で終わらないので読まれない)

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/bootstrap-windows-ssh-config.sh --force
```

判定だけ見るなら `--dry-run` を付ける。

````

- [ ] **Step 10: ADR 003 / 013 / 015 に後続 ADR のポインタを足す**

ADR 003 (`docs/adr/003_nix_ssh_config_20260810T210714JST/README.md`) の、2 つ目の `| 後続 ADR |` の行の下に足す:

```markdown
| 後続 ADR | [016_ssh_config_from_dotfiles_private](../016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)（接続先の正本を `.ssh` submodule から dotfiles-private の `ssh/` へ移し、`setup-ssh-config.sh` を `bootstrap-ssh-config.sh` に置き換えた。Windows の `%USERPROFILE%\.ssh` へも配る。本文はそのまま） |
```

ADR 013 (`docs/adr/013_remove_legacy_tree_20261007T015646JST/README.md`) の `| 運用手順 |` の行の直前に足す:

```markdown
| 後続 ADR | [016_ssh_config_from_dotfiles_private](../016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)（「C. 残すもの」の `.ssh` submodule と `.gitmodules` を外した。接続先は dotfiles-private の `ssh/` へ移した。本文はそのまま） |
```

ADR 015 (`docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md`) の `| 運用手順 |` の行の直前に足す:

```markdown
| 後続 ADR | [016_ssh_config_from_dotfiles_private](../016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md)（dotfiles-private に ssh の接続先 (`ssh/`) も置くようにした。本文はそのまま） |
```

- [ ] **Step 11: ADR 016 の一時ファイルの名前を実装に合わせる**

`docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md`:

```diff
-- 一時ファイルの名前 (`.<名前>.tmp`) も `*.ssh_config` で終わらないので、書いている途中に
-  ssh.exe が読んでも `Include` されない
+- 一時ファイルの名前 (`<名前>.dotfiles-tmp.XXXXXX`、bootstrap-windows-files.sh と同じ) も
+  `*.ssh_config` で終わらないので、書いている途中に ssh.exe が読んでも `Include` されない
```

- [ ] **Step 12: リンクとアンカーを確かめて commit する**

```bash
grep -rn -E '\.ssh` submodule|setup-ssh-config|ssh-config` と|2\.6' README.md nix/README.md win/README.md || echo none
grep -n '^## ssh の設定' win/README.md
for f in docs/adr/003_*/README.md docs/adr/013_*/README.md docs/adr/015_*/README.md; do grep -c '016_ssh_config_from_dotfiles_private' "${f}"; done
git add README.md nix/README.md win/README.md docs/adr
git commit -F - <<'EOF'
docs: ssh の接続先を dotfiles-private から配る形に、README・win/README.md・ADR のポインタを合わせる (TKT-145)

nix/README.md の手順表・order の表・「ssh について」、README のディレクトリの表、win/README.md の
「ssh の設定」を直し、ADR 003 / 013 / 015 に後続 ADR (016) のポインタを足す。ADR 016 の一時ファイルの
名前を実装に合わせる。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
```

Expected: 1 行目は `none` (「ssh について」の中の「以前の `.ssh` submodule を指す symlink」の 1 か所だけは残ってよいので、出たら中身を見て判断する)。2 行目は見出しの行番号が 1 つ出る。ADR 3 つはどれも `1`

---

### Task 6: まとめて確かめ、この PC で流して ADR 016 の検証を書く

**Files:**
- Modify: `docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md` (§6 検証)

**Interfaces:**
- Consumes: Task 1〜5 のすべて。Task 1 の commit が入ったローカルの dotfiles-private (push 前でよい)

- [ ] **Step 1: flake の checks と lint を全部流す**

```bash
nix flake check ./nix -L 2>&1 | tail -20
nix develop ./nix --command bash -c 'mapfile -t files < <(find nix -type f -name "*.sh" | sort); shfmt -d "${files[@]}" && shellcheck "${files[@]}" && find nix -name "*.nix" -print0 | xargs -0 nixfmt --check && echo lint-ok'
./nix/scripts/bootstrap-windows-files.sh --check
```

Expected: `nix flake check` が成功する。`lint-ok`。`win/manifest.toml: OK (7 件)`

- [ ] **Step 2: 実機の前の状態を控える (書き換えない)**

```bash
ssh.exe -v -G nonexistent.invalid 2>&1 | grep 'Reading configuration' > /tmp/tkt145-read-before.txt
cat /tmp/tkt145-read-before.txt | sed -E 's#(config\.d|\.ssh)/[^/ ]+\.ssh_config#\1/<name>.ssh_config#'
# my-cloud などのツールが書いた Host の実効値を、中身を出さずに sha256 で控える
for f in /mnt/c/Users/polle/.ssh/config.d/*.ssh_config; do
  awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if ($i !~ /[*?]/) print $i}' "${f}"
done | sort -u > /tmp/tkt145-tool-hosts.txt
while read -r h; do printf '%s %s\n' "$(ssh.exe -G "${h}" 2>/dev/null | sha256sum | cut -c1-16)" "${h}"; done < /tmp/tkt145-tool-hosts.txt > /tmp/tkt145-tool-hosts-before.txt
wc -l /tmp/tkt145-tool-hosts-before.txt
```

Expected: 読み順に旧 clone の `dotfiles/ssh_config` が出る。ツールの Host の数が出る (ホスト名は画面に出さなくてよい)

- [ ] **Step 3: Windows 側を --dry-run で流して判定を見る**

```bash
./nix/scripts/bootstrap-windows-ssh-config.sh --dry-run
```

Expected: `config: 置き換え (旧経路の Include ~/dotfiles/ssh_config)` と、`config.d/<名前>.ssh_config: コピー` が 4 行出て、衝突は無い (exit 0)。違う判定が出たら止めてユーザーに見せる

- [ ] **Step 4: ユーザーに確かめてから、WSL 側と Windows 側を本番で流す**

ユーザーに「この PC の `~/.ssh/config.d/` の symlink と `%USERPROFILE%\.ssh\config` を書き換える」ことを確かめてから流す:

```bash
./nix/scripts/bootstrap-ssh-config.sh
./nix/scripts/bootstrap-windows-ssh-config.sh
```

Expected: 1 本目は `4 個を張りました` (旧 submodule を指していた symlink は張り替わる)。2 本目は `確かめ: ssh.exe が config と config.d の 7 件を読んだ (旧 clone の ssh_config は読んでいない)` で exit 0

- [ ] **Step 5: 実機で振る舞いを確かめる**

```bash
ssh.exe -v -G nonexistent.invalid 2>&1 | grep 'Reading configuration' | sed -E 's#(config\.d)/[^/ ]+\.ssh_config#\1/<name>.ssh_config#'
while read -r h; do printf '%s %s\n' "$(ssh.exe -G "${h}" 2>/dev/null | sha256sum | cut -c1-16)" "${h}"; done < /tmp/tkt145-tool-hosts.txt > /tmp/tkt145-tool-hosts-after.txt
diff /tmp/tkt145-tool-hosts-before.txt /tmp/tkt145-tool-hosts-after.txt && echo tool-hosts-same
USE_LINUX_SSH=1 ssh -v -G github.com 2>&1 | grep 'Reading configuration' | sed -E 's#(config\.d)/[^/ ]+\.ssh_config#\1/<name>.ssh_config#'
ls -l ~/.ssh/config.d/ | awk '{print $9, $10, $11}' | sed -E 's#/[^/ ]+\.ssh_config$#/<name>.ssh_config#'
./nix/scripts/bootstrap-windows-ssh-config.sh
```

Expected:
- 1 本目: `config` のあとに `config.d/<name>.ssh_config` が 7 行並び、`dotfiles/ssh_config` は出ない
- `tool-hosts-same` (my-cloud などの Host の実効値は変わらない)
- `USE_LINUX_SSH=1` の行には `~/.ssh/config.d/<name>.ssh_config` が並び、`ls -l` では dotfiles-private の `ssh/` を指している
- 最後は `Windows の ssh の設定は揃っています (config と config.d の 4 件。ssh.exe が読むことも確かめた)。` の 1 行
- `ssh -T git@github.com` は 1Password の承認が出るので、打つかどうかはユーザーに任せる (打つなら `Hi pollenjp!` が出ること)

- [ ] **Step 6: ADR 016 の §6 に結果を書いて commit する**

`## 6. 検証 (Verification)` の「実装のあとに結果を書く。予定は次のとおり。」から表の終わりまでを、次の形で書き直す (数と結果は実際に出たものにする):

```markdown
<確かめた日 (YYYY-MM-DD)> に確かめた。

| 何を | どうやって | 結果 |
| --- | --- | --- |
| WSL 側の bootstrap | `nix/tests/bootstrap-ssh-config.test.sh` (使い捨ての HOME・dotfiles-private・checkout)。flake の checks で流す | 9 件すべて通過 |
| Windows 側の bootstrap | `nix/tests/bootstrap-windows-ssh-config.test.sh` (偽の Windows のホームと `ssh.exe`) | 26 件すべて通過 |
| この PC での初回 | `--dry-run` の判定を見てから本番を流した | `config` は旧経路の Include を置き換え、`config.d` へ 4 件をコピー。衝突なし |
| 読むファイル | `ssh.exe -v -G nonexistent.invalid` | `config` と `config.d` の 7 件を読み、旧 clone の `ssh_config` は読まない |
| ツールの Host | my-cloud などが書いた Host の `ssh.exe -G` を前後で比べた | 変わらない |
| WSL 側 | `USE_LINUX_SSH=1 ssh -v -G github.com` | `~/.ssh/config.d/` の dotfiles-private を指す symlink を読む |
```

```bash
git add docs/adr/016_ssh_config_from_dotfiles_private_20261012T131912JST/README.md
git commit -F - <<'EOF'
docs(adr): ADR 016 の検証に、テストとこの PC で確かめたことを書く (TKT-145)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
```

---

### Task 7: push して PR を出す

**Files:** なし (remote と Dev Tracker への操作)

**Interfaces:**
- Consumes: Task 1 の dotfiles-private の commit、Task 2〜6 の dotfiles の commit

- [ ] **Step 1: ユーザーに確かめてから、dotfiles-private を push する**

```bash
git -C "$(ghq root)/github.com/pollenjp/dotfiles-private" push origin main
```

- [ ] **Step 2: ユーザーに確かめてから、branch を push して PR を出す**

```bash
git push -u origin feat/TKT-145-windows-ssh-config
url=$(~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh show TKT-145 --url)
gh pr create --base main --head feat/TKT-145-windows-ssh-config \
  --title "TKT-145 ssh の接続先を dotfiles-private へ移し、Windows の ~/.ssh へも配る" \
  --body "$(printf '%s\n\n' "${url}"; cat <<'EOF'
## 変更

- `nix/scripts/bootstrap-ssh-config.sh` (order 60): dotfiles-private の `ssh/*.ssh_config` を `~/.ssh/config.d/` へ張る (`setup-ssh-config.sh` を置き換える)
- `nix/scripts/bootstrap-windows-ssh-config.sh` (order 91): Windows の `%USERPROFILE%\.ssh` に `config` (Include 1 行) を置き、`config.d` へコピーして記録で管理する。書いたあとに `ssh.exe -v -G` で確かめる
- setup の `ssh-config` 手順と `.ssh` submodule を外す
- ADR 016、nix/README.md・README.md・win/README.md

## 確かめたこと

- `nix flake check ./nix` (新しいテスト 2 本: 9 件 / 26 件)
- この PC で `--dry-run` → 本番。ssh.exe は旧 clone を読まなくなり、my-cloud などの Host の実効値は変わらない

## merge のあと

- 先に pollenjp/dotfiles-private に `ssh/` が入っている (push 済み)
- 各マシンで `~/dotfiles/setup --self-update --update`。残った `.ssh/` は setup が出すコマンドで消す
- 全マシンが移ったら pollenjp/dotfiles-ssh を archive する

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01QrjuxvcYzYukMz5yGxfFTj
EOF
)"
```

- [ ] **Step 3: チケットに PR を結ぶ**

```bash
~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh pr TKT-145
~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh link TKT-145 "$(gh pr view --json url --jq .url)" "PR: ssh の接続先を dotfiles-private へ移し、Windows の ~/.ssh へも配る"
```

Expected: TKT-145 の Status が In Review になる

---

## この計画の外 (merge のあとに手で)

- 各マシン (この PC・会社の PC) で `~/dotfiles/setup --self-update --update` を流し、残った `.ssh/` を消す。会社の PC で Windows の `config` に手書きの Host があれば、衝突の解き方 (win/README.md「ssh の設定が衝突したら」) に従う
- 全マシンが移ったら、GitHub で pollenjp/dotfiles-ssh を archive する
- my-cloud の `gcp-sdbx-v2/ansible/playbook.yaml` などのコメントにある「dotfiles の .ssh submodule」を直す (別の repo の小さい PR)
