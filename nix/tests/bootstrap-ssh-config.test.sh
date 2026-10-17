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
#   - 旧 submodule の作業ツリーが手付かずなら消すコマンドを出し、変更・未 push の commit があるか
#     確かめられないなら警告だけにする。知らない引数は exit 2
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告を続きの行ごと setup の最後の
#     まとめ用のファイルにも残す
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
# 判定の grep -q はパイプで受けず、ファイルを直に読む。outerr を grep -q へパイプでつなぐと、grep が
# out で合って先に抜けたあと cat が err を書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」
# に見える (check-test-grep-q.sh が CI の lint で落とす)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
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
if [[ $(rc "${c}") == 0 && ${before} == "${after}" ]] && seen "${c}" '2 個を張りました'; then
  ok "2 回目も同じ結果になる"
else
  ng "2 回目" "rc=$(rc "${c}") ${before} / ${after}"
fi

# 3. 正本から消えたファイルを指す symlink は外す
rm "${c}/private/ssh/b c.ssh_config"
run "${c}"
if [[ $(rc "${c}") == 0 && ! -e $(confd "${c}")/"b c.ssh_config" && ! -L $(confd "${c}")/"b c.ssh_config" ]] \
  && seen "${c}" '正本に無い symlink を 1 個外しました'; then
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
  && seen "${c}" '正本に無い symlink を 1 個外しました'; then
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

# 旧 submodule の作業ツリーに見立てた git の repo を作る。$1: ケース
legacy_repo() {
  git -c init.defaultBranch=main init -q "$1/repo/.ssh"
  mkdir -p "$1/repo/.git/modules/.ssh"
}
legacy_commit() {
  git -C "$1/repo/.ssh" -c user.name=tester -c user.email=tester@example.test commit -q --allow-empty -m local
}

# 8. 旧 submodule の作業ツリーが手付かずで残っていれば、消すコマンドを出す (消さない)
c=$(new_case t8)
legacy_repo "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 && -e ${c}/repo/.ssh/.git ]] \
  && grep -qF "rm -rf '${c}/repo/.ssh' '${c}/repo/.git/modules/.ssh'" "${c}/out"; then
  ok "旧 submodule の作業ツリーが手付かずで残っていれば、消すコマンドを出す (自分では消さない)"
else
  ng "作業ツリーの残り" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 8b. commit していないファイルがあれば、消すコマンドは出さずに警告する
c=$(new_case t8b)
legacy_repo "${c}"
printf 'Host local\n' >"${c}/repo/.ssh/local.ssh_config"
run "${c}"
if [[ $(rc "${c}") == 0 && -e ${c}/repo/.ssh/local.ssh_config ]] && ! grep -q 'rm -rf' "${c}/out" \
  && grep -q '旧 .ssh submodule の作業ツリーに' "${c}/err"; then
  ok "旧 submodule に commit していない変更があれば、消すコマンドを出さずに警告する"
else
  ng "commit していない変更" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 8c. push していない commit があれば、消すコマンドは出さずに警告する
c=$(new_case t8c)
legacy_repo "${c}"
legacy_commit "${c}"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && ! grep -q 'rm -rf' "${c}/out" && grep -q '旧 .ssh submodule の作業ツリーに' "${c}/err"; then
  ok "旧 submodule に push していない commit があれば、消すコマンドを出さずに警告する"
else
  ng "push していない commit" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 8d. 状態を確かめられない (.git が壊れている) ときも、消すコマンドは出さない
c=$(new_case t8d)
mkdir -p "${c}/repo/.ssh" "${c}/repo/.git/modules/.ssh"
printf 'gitdir: ../.git/modules/.ssh\n' >"${c}/repo/.ssh/.git"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && ! grep -q 'rm -rf' "${c}/out" && grep -q '旧 .ssh submodule の作業ツリーに' "${c}/err"; then
  ok "旧 submodule の状態を確かめられなければ、消すコマンドを出さない"
else
  ng "確かめられない" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 10. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): ssh/ が無い警告と、旧 submodule の警告を、
#     続きの行 (取り方・確かめるコマンド) ごとまとめ用に残す
c=$(new_case t10)
rm -rf "${c}/private/ssh"
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}"
c2=$(new_case t10b)
legacy_repo "${c2}"
legacy_commit "${c2}"
DOTFILES_SETUP_WARNINGS="${c2}/warnings" run "${c2}"
if [[ $(rc "${c}") == 0 && $(head -n 1 "${c}/warnings" 2>/dev/null) == '張る *.ssh_config がありません: '* ]] \
  && grep -qE '^[[:space:]]+取るには: .*/bootstrap-dotfiles-private\.sh$' "${c}/warnings" \
  && [[ $(rc "${c2}") == 0 && $(head -n 1 "${c2}/warnings" 2>/dev/null) == '旧 .ssh submodule の作業ツリーに'* ]] \
  && grep -qE "^[[:space:]]+git -C '.*' status && git -C" "${c2}/warnings"; then
  ok "setup から走るとき、警告を続きの行ごとまとめ用に残す"
else
  ng "警告のまとめ" "$(cat "${c}/warnings" 2>/dev/null) / $(cat "${c2}/warnings" 2>/dev/null)"
fi
if grep -qx "     git -C '${c2}/repo/.ssh' status && git -C '${c2}/repo/.ssh' log --branches --not --remotes" "${c2}/err"; then
  ok "その場の続きの行は今のまま (確かめるコマンドは 5 文字字下げ)"
else
  ng "その場の続きの行が変わった" "$(cat "${c2}/err")"
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
