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
#   - config は Include の後ろに Host * と SetEnv PJP_SSH_CLIENT=%u@%L を持つ。前の版 (SetEnv の無い config) を
#     置いたままのマシンでは、正本の更新として上書きする
#   - 同じ名前のファイルは、中身が同じなら記録だけ、違えば衝突。--dry-run は何も書かない
#   - 衝突の 1 行目は、置いた記録があれば「前回ここへ置いた中身と違う」、無ければ置いた記録が無いと出す
#   - 確かめ: 揃っている / Bad owner / 読まれないファイル / 旧 clone / 呼べない・無い・固まる / 区切りと大小の違い
#   - 壊れた記録は exit 1、知らない引数は exit 2
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、exit 0 で続ける警告を続きの行
#     (取り方・手で打つコマンド) ごと setup の最後のまとめ用のファイルにも残す
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
Include config.d/*.ssh_config

# ssh 先の herdr が「同じマシンから来た接続」を見分けるのに、このマシンを名乗る (dotfiles の ADR 025)。
# 受け取る側の sshd に AcceptEnv PJP_SSH_CLIENT が要る。ssh は最初に当たった SetEnv の行だけを使うので、
# config.d の Host に SetEnv を書いたら、そこにも PJP_SSH_CLIENT=%u@%L を足す。
Host *
  SetEnv PJP_SSH_CLIENT=%u@%L'
# 前の版の config の中身 (SetEnv の無いもの。TKT-224 より前に置いた config)
config_before_setenv='# dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
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
  ignoreterm)
    # SIGTERM を無視して固まる (無視は exec した子の sleep にも引き継がれる)
    trap '' TERM
    sleep 20
    exit 0
    ;;
esac
echo "debug1: OpenSSH_for_Windows_10.0p2 Win32-OpenSSH-GitHub, LibreSSL 4.2.0" >&2
echo 'debug1: Reading configuration data C:\\Users\\tester/.ssh/config' >&2
if [[ ${mode} == partial ]]; then
  # 読み始めたところで固まる
  sleep 5
  exit 0
fi
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
if [[ ${mode} == badopt ]]; then
  # 全部読んでから、知らないオプションで止まる (どの接続先でも exit 255 になる)
  echo 'C:\\Users\\tester/.ssh/config.d/b c.ssh_config: line 2: Bad configuration option: nosuchoption' >&2
  echo 'C:\\Users\\tester/.ssh/config.d/b c.ssh_config: terminating, 1 bad configuration options' >&2
  exit 255
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
# 判定の grep -q はパイプで受けず、ファイルを直に読む。outerr を grep -q へパイプでつなぐと、grep が
# out で合って先に抜けたあと cat が err を書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」
# に見える (check-test-grep-q.sh が CI の lint で落とす)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
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
if [[ $(rc "${c}") == 0 && ! -e $(wssh "${c}") ]] && seen "${c}" '飛ばします'; then
  ok "windows-files.json が無ければ何も書かずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 2. enable = false: 飛ばす
c=$(new_case t2 "${state_off}")
run "${c}" 0
if [[ $(rc "${c}") == 0 && ! -e $(wssh "${c}") ]] && seen "${c}" '配りません'; then
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

# 9b. 前の版の config (SetEnv の無いもの) を置いたマシンは、正本の更新として上書きする
c2=$(new_case t9b "${state_on}")
deploy "${c2}"
printf '%s\n' "${config_before_setenv}" >"$(wssh "${c2}")/config"
old_sha=$(sha256sum <"$(wssh "${c2}")/config" | cut -d' ' -f1)
f2="${c2}/home/.local/state/dotfiles/windows-ssh-config.deployed.json"
jq --arg v "${old_sha}" '.files.config = $v' "${f2}" >"${f2}.tmp" && mv "${f2}.tmp" "${f2}"
run "${c2}" 0
if [[ $(rc "${c2}") == 0 && $(cat "$(wssh "${c2}")/config") == "${config_want}" ]] \
  && grep -q 'config: 上書き (正本が更新された)' "${c2}/out" \
  && grep -q '^  SetEnv PJP_SSH_CLIENT=%u@%L$' "$(wssh "${c2}")/config"; then
  ok "前の版の config (SetEnv の無いもの) は、正本の更新として Host * の SetEnv PJP_SSH_CLIENT=%u@%L つきに上書きする"
else
  ng "前の版の config の上書き" "rc=$(rc "${c2}") $(outerr "${c2}") config=$(cat "$(wssh "${c2}")/config")"
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

# 23. 確かめ: ssh.exe が読み始めたところで固まったら、時間切れとして手で打つコマンドを出して exit 0
c=$(new_case t23 "${state_on}")
FAKE_SSH_MODE=partial BOOTSTRAP_SSH_CHECK_TIMEOUT=1 run "${c}" 0
if [[ $(rc "${c}") == 0 ]] && grep -q '確かめられませんでした (終了コード 124' "${c}/err" \
  && ! grep -q '読まなかったファイル' "${c}/err"; then
  ok "ssh.exe が途中まで出して固まっても、時間切れとして exit 0 (読まれないとは言わない)"
else
  ng "途中で固まる" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 24. 確かめ: ssh.exe が全部読んでから設定の誤りで exit 255 なら、⚠ の枠で出して exit 1
c=$(new_case t24 "${state_on}")
FAKE_SSH_MODE=badopt run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -q '設定を読み終えられませんでした (終了コード 255' "${c}/err" \
  && grep -q 'Bad configuration option: nosuchoption' "${c}/err" && ! grep -q '確かめ: ssh.exe が' "${c}/out"; then
  ok "ssh.exe が設定の誤りで exit 255 なら、エラーの行を添えて exit 1"
else
  ng "設定の誤り" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 25. 確かめ: SIGTERM を無視する ssh.exe も、少し待ってから KILL して先へ進む
c=$(new_case t25 "${state_on}")
start=${SECONDS}
FAKE_SSH_MODE=ignoreterm BOOTSTRAP_SSH_CHECK_TIMEOUT=1 run "${c}" 0
elapsed=$((SECONDS - start))
if [[ $(rc "${c}") == 0 ]] && ((elapsed < 15)) && grep -q '確かめられませんでした (終了コード 137' "${c}/err"; then
  ok "SIGTERM を無視する ssh.exe も KILL して、手で打つコマンドを出して exit 0"
else
  ng "SIGTERM を無視" "rc=$(rc "${c}") elapsed=${elapsed}s $(outerr "${c}")"
fi

# 26. 衝突の 1 行目は、置いた記録の有無で分ける。記録が無い (この script が置く前から Windows 側にあった) なら、
#     一度も置いていないので「前回ここへ置いた中身と違う」とは出さず、置いた記録が無いと出す
c=$(new_case t26 "${state_on}")
mkdir -p "$(wssh "${c}")/config.d"
printf 'Host b\n  User mine\n' >"$(wssh "${c}")/config.d/b c.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -qF 'config.d/b c.ssh_config は、置いた記録が無く' "${c}/err" \
  && ! grep -qF '前回ここへ置いた中身と違う' "${c}/err"; then
  ok "置いた記録の無い衝突は、記録が無いと出し、前回置いた中身と違うとは出さない"
else
  ng "記録の無い衝突" "rc=$(rc "${c}") $(outerr "${c}")"
fi
run "${c}" 0 --force
printf 'Host a\n  User edited\n' >"$(wssh "${c}")/config.d/a.ssh_config"
run "${c}" 0
if [[ $(rc "${c}") == 1 ]] && grep -qF 'config.d/a.ssh_config は Windows 側で変わっています (前回ここへ置いた中身と違う)' "${c}/err" \
  && ! grep -qF '置いた記録が無く' "${c}/err"; then
  ok "置いた記録がある衝突は、前回ここへ置いた中身と違うと出す"
else
  ng "記録がある衝突" "rc=$(rc "${c}") $(outerr "${c}")"
fi

# 27. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 正本が無い・ssh.exe が無いときの警告を、
#     続きの行 (取り方・手で打つコマンド) ごとまとめ用に残す
c=$(new_case t27 "${state_on}")
rm -rf "${c}/private/ssh"
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}" 0
c2=$(new_case t27b "${state_on}")
DOTFILES_SETUP_WARNINGS="${c2}/warnings" run "${c2}" 1
if [[ $(rc "${c}") == 0 && $(head -n 1 "${c}/warnings" 2>/dev/null) == 'Windows の ssh の設定を配りません: 正本の *.ssh_config がありません'* ]] \
  && grep -qE '^[[:space:]]+取るには: .*/bootstrap-dotfiles-private\.sh$' "${c}/warnings" \
  && [[ $(rc "${c2}") == 0 && $(head -n 1 "${c2}/warnings" 2>/dev/null) == 'ssh.exe が見つからない'* ]] \
  && grep -qE "^[[:space:]]+ssh -v -G nonexistent\.invalid 2>&1 \| Select-String 'Reading configuration'$" "${c2}/warnings"; then
  ok "setup から走るとき、正本が無い・ssh.exe が無いときの警告を続きの行ごとまとめ用に残す"
else
  ng "警告のまとめ" "$(cat "${c}/warnings" 2>/dev/null) / $(cat "${c2}/warnings" 2>/dev/null)"
fi

# 28. 確かめられない (ssh.exe が固まる) ときは、見出しと手で打つコマンドを 1 件として残す。揃っていれば残さない
c=$(new_case t28 "${state_on}")
DOTFILES_SETUP_WARNINGS="${c}/warnings" FAKE_SSH_MODE=hang BOOTSTRAP_SSH_CHECK_TIMEOUT=1 run "${c}" 0
if [[ $(rc "${c}") == 0 && $(head -n 1 "${c}/warnings" 2>/dev/null) == 'ssh.exe で確かめられませんでした (終了コード 124'* ]] \
  && grep -qE "^[[:space:]]+ssh -v -G nonexistent\.invalid" "${c}/warnings" \
  && [[ $(grep -c '^[^[:space:]]' "${c}/warnings") == 1 ]]; then
  ok "確かめられなければ、見出しと手で打つコマンドを 1 件としてまとめ用に残す"
else
  ng "確かめられないときのまとめ" "rc=$(rc "${c}") warnings=$(cat "${c}/warnings" 2>/dev/null)"
fi
c=$(new_case t28b "${state_on}")
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}" 0
if [[ $(rc "${c}") == 0 && ! -s ${c}/warnings ]]; then
  ok "揃っていれば、まとめ用には何も残さない"
else
  ng "揃っているのにまとめ用に残した" "rc=$(rc "${c}") warnings=$(cat "${c}/warnings" 2>/dev/null)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
