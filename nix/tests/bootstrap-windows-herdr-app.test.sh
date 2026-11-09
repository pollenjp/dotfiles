#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-herdr-app.sh の振る舞いを、使い捨ての HOME と
# 偽の pwsh.exe / wslpath で確かめる。
#
#   bash nix/tests/bootstrap-windows-herdr-app.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-herdr-app-test) が Nix のサンドボックスで流す。
# CI の `nix flake check` もこれを通る。使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Install-HerdrApp.ps1 が無いときは pwsh.exe を呼ばずに飛ばす
#   - pwsh.exe が無い・失敗する・こちらの出力を返さないときは、手で打つコマンドを出して exit 0
#   - -Check が 0 なら 1 行だけ (※ の行は添える)
#   - -Check が 1 (揃っていない) か 3 (app が入っていない) なら -IfMissing で揃える。揃えば ⚠ を出さず、揃いきらなければ
#     (固定より新しい版が入っている・入れられない) ⚠ で囲んだ注意・状態・揃えるコマンドを出す
#   - どれも exit 0。--apply は -Check を付けずに流し、失敗なら exit 1。端末でなければ色を付けない
#   - -Uninstall はどの場合も打たない (外すのは人が打つときだけ)
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、⚠ の見出しと揃えるコマンド
#     (確かめられないときは手で打つコマンド) を setup の最後のまとめ用のファイルにも残す
#
# ## 本物の pwsh.exe を見せない
#
# WSL では PATH に本物の pwsh.exe と wslpath がある。見えると本物の Windows に herdr-app を入れうるので、
# 要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-herdr.test.sh と同じ作り)。
# 偽の pwsh.exe と wslpath の shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-herdr-app.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-herdr-app-test.XXXXXX")
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

app='C:\Users\u\AppData\Local\Programs\herdr-app'
core='C:\Users\u\AppData\Local\Programs\herdr-core'
feed='C:\Users\u\AppData\Local\dotfiles\herdr-releases'
feed_url='file:///C:/Users/u/AppData/Local/dotfiles/herdr-releases'
header='herdr-app (公式と同じ置き場所。版は dotfiles が決める: 0.1.12)'
core_header='herdr-core (無ければ入れる。版は dotfiles が決めた 0.1.17 以上)'
feed_header='更新の取得元 (HERDR_RELEASES_URL。app と core は、ここに載った版にだけ上がる)'
sig='Valid (CN=herdr, O=herdr。発行元 Microsoft ID Verified CS AOC CA 04)'

# Install-HerdrApp.ps1 -Check の出力 (揃っているとき)
check_out="${header}
  置き場所         : ${app}
  入っている版     : 0.1.12 (固定した版)
  署名             : ${sig}
  スタートメニュー : Herdr.lnk
  ユーザーの PATH  : あり
${core_header}
  置き場所         : ${core}
  入っている版     : 0.1.17 (固定した版 0.1.17 以上)
  署名             : ${sig}
  ユーザーの PATH  : あり
${feed_header}
  フィード         : ${feed} (app 0.1.12・core 0.1.17)
  環境変数         : ${feed_url}
入っている (固定した版・フィード・環境変数も揃っている)"

# Install-HerdrApp.ps1 -Check の出力 (フィードが固定と違うとき。固定した版を上げる PR を merge した後など)
partial_out="${header}
  置き場所         : ${app}
  入っている版     : 0.1.12 (固定した版)
  署名             : ${sig}
  スタートメニュー : Herdr.lnk
  ユーザーの PATH  : あり
${core_header}
  置き場所         : ${core}
  入っている版     : 0.1.17 (固定した版 0.1.17 以上)
  署名             : ${sig}
  ユーザーの PATH  : あり
${feed_header}
⚠ フィード         : ${feed} (無い・固定と違う: app\latest.json) → 書く
  環境変数         : ${feed_url}
⚠️ herdr-app に揃っていないものがある → Install-HerdrApp で揃える ⚠️"

# Install-HerdrApp.ps1 -IfMissing がフィードを書き直したときの出力
synced_out="フィード ${feed} を固定どおりに書いた (app 0.1.12・core 0.1.17)

${check_out%$'\n'*}
揃った"

# Install-HerdrApp.ps1 -IfMissing の出力 (固定より新しい app が入っていて、揃いきらないとき)
newer_out="${header}
  置き場所         : ${app}
⚠ 入っている版     : 0.1.14 (固定した版 0.1.12 より新しい。下げはしない)
  署名             : ${sig}
※ 入っている app は固定した版より新しい。取得元の変数を置く前に上がったか、変数が効いていない (公式から上がった)。dotfiles は下げない。
⚠️ まだ揃っていないものがある (上の ⚠ の行) ⚠️"

# Install-HerdrApp.ps1 -Check の出力 (app が入っていないとき)
missing_out="${header}
⚠ 置き場所         : ${app} → 入っていない (0.1.12 を入れる)
  スタートメニュー : Herdr.lnk が無い
  ユーザーの PATH  : 無し
${core_header}
⚠ 置き場所         : ${core} → 入っていない (0.1.17 を入れる)
${feed_header}
  フィード         : ${feed} (無い・固定と違う: app\latest.json・core\latest.json・core\0.1.17\manifest.json)
  環境変数         : 無し (公式の releases.herdr.dev から上がる)
⚠️ herdr-app が入っていない → Install-HerdrApp で入れる ⚠️"

# Install-HerdrApp.ps1 -IfMissing が入れ終えたときの出力
installed_out="${missing_out%$'\n'*}
フィード ${feed} を固定どおりに書いた (app 0.1.12・core 0.1.17)
ユーザーの環境変数 HERDR_RELEASES_URL を ${feed_url} にした (このあと開く app と core から効く。開いている app は閉じて開き直す)
herdr-app 0.1.12 を落とす: https://releases.herdr.dev/app/0.1.12/herdr-app-windows-x86_64.tar.gz
herdr-app 0.1.12 を ${app} に置いた (署名と sha256 を確かめた)
スタートメニューに C:\Users\u\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Herdr.lnk を作った
ユーザーの PATH に ${app} を足した (新しく開くシェルから効く)
herdr-core 0.1.17 を落とす: https://releases.herdr.dev/core/0.1.17/herdr-core-windows-x86_64.zip
hc.exe を herdr-core.exe への hard link で作った
herdr-core 0.1.17 を ${core} に置いた (署名と sha256 を確かめた)
ユーザーの PATH に ${core} を足した (新しく開くシェルから効く)

${check_out%$'\n'*}
揃った"

# 要るコマンドだけを並べた PATH (pwsh.exe と wslpath は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail od mkdir mktemp mv rm dirname basename chmod timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Install-HerdrApp.ps1 を配った状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/.config/powershell"
    printf '# Install-HerdrApp.ps1\n' >"${h}/win/.config/powershell/Install-HerdrApp.ps1"
  fi
  # 偽の pwsh.exe。引数を記録し、出力を行ごとに CRLF で出して終わる。
  # -IfMissing の呼び出しは FAKE_PWSH_OUT2 / FAKE_PWSH_RC2、ほかは FAKE_PWSH_OUT / FAKE_PWSH_RC を使う
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/pwsh-calls"
case "$*" in
  *-IfMissing*)
    text=${FAKE_PWSH_OUT2-}
    rc=${FAKE_PWSH_RC2:-0}
    ;;
  *)
    text=${FAKE_PWSH_OUT-}
    rc=${FAKE_PWSH_RC:-0}
    ;;
esac
if [[ -n ${text} ]]; then
  while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${text}"
fi
exit "${rc}"
EOF
  } >"${h}/bin/pwsh.exe"
  # 偽の wslpath。-w <パス> を C:\fake\<ファイル名> にする
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
EOF
  } >"${h}/bin/wslpath"
  chmod +x "${h}/bin/pwsh.exe" "${h}/bin/wslpath"
  echo "${h}"
}

# $1: HOME、$2: 1 なら偽の pwsh.exe を PATH に置かない、残り: script の引数。
# 環境変数 (FAKE_PWSH_*) は呼び出し側で付ける。
run() {
  local h=$1 nopwsh=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nopwsh} == 1 ]]; then
    path="${h}/bin-nopwsh:${sys_bin}"
    mkdir -p "${h}/bin-nopwsh"
    ln -sf "${h}/bin/wslpath" "${h}/bin-nopwsh/wslpath"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む (pipefail の下で SIGPIPE を拾わない。
# check-test-grep-q.sh が CI の lint で見る)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}
pwsh_called() { [[ -s $1/pwsh-calls ]]; }
calls() { cat "$1/pwsh-calls" 2>/dev/null; }
# pwsh.exe の呼び出しの記録 (1 回 1 行) に、grep の引数で合う行があるか。記録が無ければ合わない
called() {
  local h=$1
  shift
  grep -qs "$@" "${h}/pwsh-calls"
}
# 最後の pwsh.exe の呼び出しが、grep の引数で合うか
called_last() {
  local h=$1
  shift
  grep -q "$@" <<<"$(tail -n 1 "${h}/pwsh-calls" 2>/dev/null)"
}
ncalls() {
  local n
  n=$(calls "$1" | grep -c '')
  echo "${n}"
}
warn_lines() {
  local n
  n=$(outerr "$1" | grep -c '⚠️')
  echo "${n}"
}

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-herdr-app.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '飛ばします'; then
  ok "windows-files.json が無ければ pwsh.exe を呼ばずに飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" '配りません'; then
  ok "enable = false なら pwsh.exe を呼ばずに飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Install-HerdrApp.ps1 が配られていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! pwsh_called "${h}" && seen "${h}" 'まだ配られていません'; then
  ok "Install-HerdrApp.ps1 が配られていなければ飛ばす"
else
  ng "Install-HerdrApp.ps1 が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. pwsh.exe が無い: 手で打つコマンドを出して exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-HerdrApp -Check'; then
  ok "pwsh.exe が無ければ手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. pwsh.exe が失敗する (interop が落ちている): 手で打つコマンドを出して exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_PWSH_RC=126 FAKE_PWSH_OUT='' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && seen "${h}" -F 'Install-HerdrApp -Check' && seen "${h}" '確かめられませんでした'; then
  ok "pwsh.exe が失敗したら手で打つコマンドを出して exit 0"
else
  ng "pwsh.exe が失敗する" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 揃っている (-Check が 0): 1 行だけで ⚠ は出さない。pwsh.exe は -NoProfile と -Check で、配った場所を渡す
h=$(new_home t6 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${check_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '揃っています' \
  && called "${h}" -- '-NoProfile' && called "${h}" -- '-Check' \
  && called "${h}" -F 'C:\fake\Install-HerdrApp.ps1' && [[ $(ncalls "${h}") == 1 ]]; then
  ok "揃っていれば 1 行だけ出して exit 0 (pwsh.exe は -NoProfile -Check、配った場所を渡す)"
else
  ng "揃っている" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 6b. スクリプトが exit まで届かずに終わっても成功扱いにしない: 呼ぶ前に $LASTEXITCODE を 2 にしておく
# shellcheck disable=SC2016 # PowerShell の $global:… を文字のまま探す
if called "${h}" -F '$global:LASTEXITCODE = 2; &'; then
  ok "pwsh.exe には、スクリプトを呼ぶ前に \$LASTEXITCODE を 2 にするコマンドを渡す"
else
  ng "\$LASTEXITCODE を先に 2 にしていない" "calls=$(calls "${h}")"
fi

# 7. 揃っていない (-Check が 1。フィードが古い): -IfMissing で揃える。揃えば ⚠ は出さない
h=$(new_home t7 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${partial_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${synced_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" '揃えました' \
  && seen "${h}" -F '固定どおりに書いた' && called_last "${h}" -- '-IfMissing' && ! called_last "${h}" -- '-Check'; then
  ok "揃っていなければ -IfMissing で揃え、揃えば ⚠ を出さずに exit 0"
else
  ng "揃っていない → 揃える" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 7b. 揃いきらない (固定より新しい app が入っていて -IfMissing も 1): ⚠ で上下を囲み、状態と揃えるコマンドを出す
h=$(new_home t7b "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${partial_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="${newer_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '揃っていません (終了コード 1)' \
  && seen "${h}" -F '0.1.14 (固定した版 0.1.12 より新しい。下げはしない)' && seen "${h}" -F '※ 入っている app は固定した版より新しい' \
  && seen "${h}" -F -- 'bootstrap-windows-herdr-app.sh --apply' && seen "${h}" -F 'PowerShell: Install-HerdrApp' \
  && [[ $(ncalls "${h}") == 2 ]]; then
  ok "揃いきらなければ ⚠ で囲んだ注意と状態と揃えるコマンドを出して exit 0"
else
  ng "揃いきらない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi
if ! seen "${h}" -F 'まだ揃っていないものがある (上の ⚠ の行)'; then
  ok "PowerShell の締めの 1 行は、枠の揃えるコマンドと重なるので出さない"
else
  ng "締めの 1 行が重なっている" "$(outerr "${h}")"
fi
if ! seen "${h}" $'\e\['; then
  ok "端末でなければ色 (エスケープ) を付けない"
else
  ng "端末でないのに色が付いている" "$(outerr "${h}" | od -c | head -5)"
fi
if ! seen "${h}" $'\r'; then
  ok "pwsh.exe の CRLF は落として出す"
else
  ng "CR が残っている" "$(outerr "${h}" | od -c | head -5)"
fi

# 8. -Check が 1 でも、こちらの出力が無い (スクリプトが壊れている等): 差とは扱わず、手で打つコマンドを出す
h=$(new_home t8 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT='The term is not recognized as a name of a cmdlet' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-HerdrApp -Check'; then
  ok "-Check の出力が来なければ差とは扱わず、手で打つコマンドを出して exit 0"
else
  ng "出力が来ない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 9. app が入っていない (-Check が 3): -IfMissing で入れる。入ったら ⚠ は出さない
h=$(new_home t9 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 && $(ncalls "${h}") == 2 ]] && seen "${h}" '入れました' \
  && seen "${h}" -F 'herdr-core 0.1.17 を' && called_last "${h}" -- '-IfMissing' && ! called_last "${h}" -- '-Check'; then
  ok "app が入っていなければ -IfMissing で入れて exit 0"
else
  ng "入っていない → 入れる" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 10. 入っていないので入れようとしたが失敗: ⚠ で囲んで知らせる。setup は止めない
h=$(new_home t10 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2='herdr-app を入れられなかった: https://releases.herdr.dev/app/0.1.12/herdr-app-windows-x86_64.tar.gz?src=install を落とせない (curl.exe の終了コード 6)' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" '入れきれませんでした' \
  && seen "${h}" -F 'curl.exe の終了コード 6' && seen "${h}" -F -- 'bootstrap-windows-herdr-app.sh --apply'; then
  ok "入れられなければ ⚠ で囲んで知らせて exit 0"
else
  ng "入れられない" "rc=$(rc "${h}") warn_lines=$(warn_lines "${h}") $(outerr "${h}")"
fi

# 10b. app は入ったが core だけ入らなかった (-IfMissing が 1): 「入れきれなかった」の枠で、何が入らなかったかを出す
h=$(new_home t10b "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="herdr-app 0.1.12 を ${app} に置いた (署名と sha256 を確かめた)
herdr-core を入れられなかった: 落とした herdr-core.exe の署名が Valid でない (NotSigned)。入れない" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") -ge 2 ]] && seen "${h}" 'herdr-core を入れきれませんでした (終了コード 1)' \
  && seen "${h}" -F 'herdr-core を入れられなかった' && seen "${h}" -F 'herdr-app 0.1.12 を'; then
  ok "app は入って core だけ入らなかったときも、何が入らなかったかを ⚠ の枠で出す"
else
  ng "core だけ入らなかった" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 11. -Check が 3 でも、こちらの出力が無い: 入れには行かず、手で打つコマンドを出す
h=$(new_home t11 "${state_on}" 1)
FAKE_PWSH_RC=3 FAKE_PWSH_OUT='Exec format error' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && seen "${h}" '確かめられませんでした' \
  && seen "${h}" -F 'Install-HerdrApp -Check'; then
  ok "-Check が 3 でも出力が来なければ、入れずに手で打つコマンドを出す"
else
  ng "3 だが出力が来ない" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 12. --apply: -Check も -IfMissing も付けずに流す。成功なら exit 0
h=$(new_home t12 "${state_on}" 1)
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="揃った" run "${h}" 0 --apply
if [[ $(rc "${h}") == 0 ]] && pwsh_called "${h}" && ! called "${h}" -- '-Check' \
  && ! called "${h}" -- '-IfMissing' && called "${h}" -F 'C:\fake\Install-HerdrApp.ps1' \
  && seen "${h}" '揃いました'; then
  ok "--apply は -Check を付けずに流し、成功なら exit 0"
else
  ng "--apply 成功" "rc=$(rc "${h}") calls=$(calls "${h}") $(outerr "${h}")"
fi

# 13. --apply が失敗: exit 1 (手で流すものなので失敗を返す)
h=$(new_home t13 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="herdr-core を入れられなかった: sha256 が違う" run "${h}" 0 --apply
if [[ $(rc "${h}") == 1 ]] && seen "${h}" '揃いませんでした'; then
  ok "--apply が失敗したら exit 1"
else
  ng "--apply 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 14. 揃っていて、core が公式と違う置き場所にある: 1 行に加えて ※ の行も出す (ずれではないので ⚠ にはしない)
h=$(new_home t14 "${state_on}" 1)
note='※ herdr-core は公式と違う置き場所にある (winget など)。dotfiles は入れず、-Uninstall も触らない'
FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${check_out%$'\n'*}"$'\n'"${note}"$'\n入っている' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(warn_lines "${h}") == 0 ]] && seen "${h}" '揃っています' \
  && seen "${h}" -F "${note}"; then
  ok "揃っていても、※ の行は出す"
else
  ng "※ の行" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. pwsh.exe の出力に色のエスケープが混ざっていても、取り除いてから枠に入れる
h=$(new_home t15 "${state_on}" 1)
FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${partial_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="${header}"$'\n\e[33m⚠ スタートメニュー : Herdr.lnk が無い → 作る\e[0m' run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! seen "${h}" $'\e' && seen "${h}" -F '⚠ スタートメニュー : Herdr.lnk が無い → 作る'; then
  ok "pwsh.exe の色のエスケープは取り除いて出す"
else
  ng "エスケープが残る" "rc=$(rc "${h}") $(outerr "${h}" | od -c | head -8)"
fi

# 16. 知らない引数: exit 2
h=$(new_home t16 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! pwsh_called "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): 揃いきらなければ、⚠ の見出しと揃えるコマンドを
#     まとめ用に残す (状態の表は残さない。その場の ⚠ の枠には出ている)
h=$(new_home t17 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${partial_out}" FAKE_PWSH_RC2=1 FAKE_PWSH_OUT2="${newer_out}" run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows の herdr-app が揃っていません (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-herdr-app\.sh --apply$' "${h}/warnings" \
  && grep -qE '^[[:space:]]+PowerShell: Install-HerdrApp$' "${h}/warnings" \
  && ! grep -q '入っている版' "${h}/warnings"; then
  ok "setup から走るとき、揃いきらなければ ⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "揃いきらないものをまとめ用に残す" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 18. 入れられなかったときも、⚠ の見出し (終了コードつき) と揃えるコマンドを残す
h=$(new_home t18 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=1 \
  FAKE_PWSH_OUT2='herdr-app を入れられなかった: sha256 が違う' run "${h}" 0
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'Windows に herdr-app と herdr-core を入れきれませんでした (終了コード 1)' ]] \
  && grep -qE '^[[:space:]]+WSL: .*/bootstrap-windows-herdr-app\.sh --apply$' "${h}/warnings"; then
  ok "入れられなければ、⚠ の見出しと揃えるコマンドをまとめ用に残す"
else
  ng "入れられないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 19. 揃っている・入れられた・揃えられたときは、まとめ用には何も残さない
h=$(new_home t19 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" FAKE_PWSH_RC=3 FAKE_PWSH_OUT="${missing_out}" FAKE_PWSH_RC2=0 \
  FAKE_PWSH_OUT2="${installed_out}" run "${h}" 0
h2=$(new_home t19b "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h2}/warnings" FAKE_PWSH_RC=0 FAKE_PWSH_OUT="${check_out}" run "${h2}" 0
h3=$(new_home t19c "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h3}/warnings" FAKE_PWSH_RC=1 FAKE_PWSH_OUT="${partial_out}" FAKE_PWSH_RC2=0 \
  FAKE_PWSH_OUT2="${synced_out}" run "${h3}" 0
if [[ $(rc "${h}") == 0 && ! -s ${h}/warnings && $(rc "${h2}") == 0 && ! -s ${h2}/warnings && $(rc "${h3}") == 0 && ! -s ${h3}/warnings ]]; then
  ok "揃っている・入れられた・揃えられたときは、まとめ用には何も残さない"
else
  ng "警告が無いのにまとめ用に残した" "$(cat "${h}/warnings" "${h2}/warnings" "${h3}/warnings" 2>/dev/null)"
fi

# 20. pwsh.exe が無いときも、見出しと手で打つコマンドをまとめ用に残す
h=$(new_home t20 "${state_on}" 1)
DOTFILES_SETUP_WARNINGS="${h}/warnings" run "${h}" 1
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'pwsh.exe が見つかりません'* ]] \
  && grep -qE '^[[:space:]]+Install-HerdrApp -Check$' "${h}/warnings"; then
  ok "pwsh.exe が無ければ、見出しと手で打つコマンドをまとめ用に残す"
else
  ng "pwsh.exe が無いときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 21. -Uninstall はどの場合も打たない (外すのは人が PowerShell で打つときだけ)
uninstalled=0
for d in "${work}"/t*; do
  if called "${d}" -- '-Uninstall'; then
    uninstalled=1
  fi
done
if ((uninstalled == 0)); then
  ok "どのケースでも -Uninstall は打たない"
else
  ng "-Uninstall を打った" "$(cat "${work}"/t*/pwsh-calls 2>/dev/null)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
