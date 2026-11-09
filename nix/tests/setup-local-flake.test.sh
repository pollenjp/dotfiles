#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup-local-flake.sh (~/dotfiles にローカル専用の flake を用意する) を、使い捨ての checkout と
# HOME で確かめる。
#
#   bash nix/tests/setup-local-flake.test.sh [<nix/scripts のパス> [<tmp の例の fixture のパス> [<initial の fixture のパス>]]]
#
# flake の checks (setup-local-flake-test) が Nix のサンドボックスで流す。fixture の既定は
# nix/tests/fixtures/local-flake-tmp/tmp.nix (評価は local-flake-tmp-state が見る) と
# nix/tests/fixtures/local-flake-initial/initial.nix (評価は local-flake-initial-state が見る)。
#
# ## 確かめること
#
#   - 新しく作る flake.nix の先頭に「# 雛形の版: <印>」があり、印は local-flake-migrate.sh id が heredoc の原文から
#     出すものと同じ。作った flake.nix は local-flake-migrate.sh render --file の出力と 1 バイトも違わない
#     (local-flake-migrate.sh が雛形の各版を描くやり方が、本物の heredoc の展開と合っている)。setup の symlink も張る
#   - dotfiles-private の入力 (inputs.dotfiles-private.url の path: と flake = false) は、clone の nix/ が無ければ本体の
#     stub (<本体>/nix/private-stub) を、あればその nix/ を指し、どちらを指したかを出す。どちらも render --file
#     (同じ --private-dir) と 1 バイトも違わない
#   - 雛形は local と hostsWith を持たず、homeConfigurations は dotfiles.homeConfigurations // privateHosts // { … }。
#     先頭のコメントの switch の例は ~/dotfiles#<ホスト> (消えたホストの名前を書かない。ADR 027)
#   - tmp の例 (「# tmp = dotfiles.lib.mkHome {」から「# };」まで) のコメントを 1 段外したものが、fixture の tmp と
#     同じ (fixture を mkForce なしで評価できることは local-flake-tmp-state が見る)
#   - 既にあり、印が今の雛形と同じなら「既にあります」で、雛形の版の警告は出さない (中身は変えない)
#   - 印が前の版・印の行が無いなら、「flake.nix は前の雛形から作られています」と、移し方
#     (local-flake-migrate.sh prepare と pjp-dotfiles-local-flake-migrate skill) と、--force で値が消えることを
#     警告する。ファイルは変えない。DOTFILES_SETUP_WARNINGS があれば同じ行をそこにも足す
#   - --force で作り直すと、印が今の値になる
#   - hostsWith・notion.profile の語が無い flake.nix (今の雛形は持たない) に、それの警告 (古い雛形のまま・
#     notion.profile が無い) を出さない。印が無ければ「前の雛形」の警告だけを出す
#   - 別のパスを指す flake.nix には今の警告を出し、雛形の版は見ない
#   - --initial は、雛形を描いたあと tmp の例の終わり (「        # };」) の後ろに、初期用のホスト initial の塊 (空行・
#     コメント・mkHome) を差し込む。塊は fixture の initial と同じ (username は $USER、system は uname、Windows のユーザー名は
#     偽の pwsh.exe が返す値)。差し込んだ所を除くと render --file と 1 バイトも違わない (雛形の版の印も変えない)。出力に
#     Windows のユーザー名と、次に打つ ~/dotfiles/setup --new-machine を出す
#   - --initial で本体の stub を指したときは、clone を読ませる道に、登録して merge したら --force で作り直す (initial も外れる)
#     を出す (local-flake-migrate.sh prepare は出さない。prepare は initial を残すため)
#   - --windows-user <名前> は名前を引かずに使い (pwsh.exe を呼ばない)、--initial なしでは 1。WSL でなければ 1
#   - initial が既にあれば「既にあります」で中身を変えず、値を引きも確かめもしない (pwsh.exe が別の名前を返しても 0)。
#     --windows-user が今の値と違えば、使っていないことと --force --initial --windows-user での変え方を出す。
#     今の雛形のまま (clone の nix/ を指す雛形も) なら差し込む。
#     手を入れた flake.nix には書かずに 1 で、手で足す塊と --force --initial を出す。--force --initial は作り直して差し込む
#   - WSL でない・Windows のユーザー名を引けない・<DOTFILES_WINDOWS_USERS_DIR (既定 /mnt/c/Users)>/<名前> が無い
#     (候補を出す。Public などは出さない)・名前に " \ $ がある、なら書かずに 1 (flake.nix を作らない)
#   - pwsh.exe (PowerShell 7) が無ければ、書いたうえで警告する (DOTFILES_SETUP_WARNINGS にも)。日本語と空白を含む名前も書ける
#   - tmp の例の Windows のユーザー名: WSL の PC で雛形を描くと (flake.nix が無い・--force)、tmp の例 (コメント) の
#     windowsUserName の行の名前を、引いた名前 (偽の pwsh.exe が返す値) にする。行はコメントのまま、ほかは render --file と
#     同じで、ファイル全体が render --file --windows-user <名前> と 1 バイトも違わない (雛形の版の印も変えない)。入れた名前を出す
#   - WSL の PC で名前が決まらない (pwsh.exe も powershell.exe も無い・<DOTFILES_WINDOWS_USERS_DIR>/<名前> が無い・名前に " が
#     ある) なら、止めずに作り物の名前のまま書き、わけを 1 行出す (stderr の警告と DOTFILES_SETUP_WARNINGS には出さない)。
#     WSL でない PC では pwsh.exe を呼ばず、何も言わない。既にある flake.nix を触らないときも pwsh.exe を呼ばない
#   - --initial は、tmp の例にも initial と同じ名前 (--windows-user の名前も) を入れ、引き直さない。差し込んだ所を除くと
#     render --file --windows-user <その名前> と 1 バイトも違わない。名前の入った例 (WSL の PC で描いたまま) は手を入れたと
#     見ず、initial を差し込む (例の名前は initial の名前になる)。名前の入った例に別の手を入れたものには書かずに 1
#   - WSL の PC のケース (--initial も) は、本物の pwsh.exe を見せないよう、要るコマンドだけを並べた PATH と env -i で流す。
#     ほかのケースは WSL でない PC として流す (WSL_DISTRO_NAME を外し、/proc/version は WSL でない中身。WSL の上でテストを
#     流しても、本物の pwsh.exe を呼ばない)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
tmp_fixture=${2:-${here}/fixtures/local-flake-tmp/tmp.nix}
initial_fixture=${3:-${here}/fixtures/local-flake-initial/initial.nix}
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-local-flake-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

for f in "${dir}/setup-local-flake.sh" "${dir}/local-flake-migrate.sh" "${tmp_fixture}" "${initial_fixture}"; do
  if [[ ! -f ${f} ]]; then
    echo "見つからない: ${f}" >&2
    exit 1
  fi
done
# WSL でない /proc/version の中身 (private-host.sh の DOTFILES_PROC_VERSION に渡す。WSL の上でテストを流しても WSL と見せない)
printf 'Linux version 6.8.0-generic (buildd@example) #1 SMP\n' >"${work}/proc-version-linux"

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

# 1 ケースぶんの checkout と HOME を作り、その場所を出す。
#   <ケース>/repo/nix/scripts/   写した setup-local-flake.sh と local-flake-migrate.sh
#   <ケース>/home                HOME
#   <ケース>/local               DOTFILES_LOCAL_DIR (ローカル flake の置き場所)
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}/repo/nix/scripts" "${c}/home"
  cp "${dir}/setup-local-flake.sh" "${dir}/local-flake-migrate.sh" "${dir}/private-host.sh" "${c}/repo/nix/scripts/"
  echo "${c}"
}

# $1: ケース、残り: setup-local-flake.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す。
# WSL でない PC として流す (WSL_DISTRO_NAME を外し、/proc/version は WSL でない中身。手元の WSL で本物の pwsh.exe を呼ばない)
run() {
  local c=$1
  shift
  # dotfiles-private の clone は、渡さなければ無い場所にする (手元の本物の clone を見せない)
  HOME="${c}/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_ALLOW_ANY_PATH=1 \
    DOTFILES_PRIVATE_DIR="${DOTFILES_PRIVATE_DIR:-${c}/no-private}" \
    DOTFILES_PROC_VERSION="${work}/proc-version-linux" \
    env -u WSL_DISTRO_NAME ${DOTFILES_SETUP_WARNINGS+"DOTFILES_SETUP_WARNINGS=${DOTFILES_SETUP_WARNINGS}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup-local-flake.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }
# local-flake-migrate.sh をそのケースの checkout で流す
migrate() {
  local c=$1
  shift
  HOME="${c}/home" "${BASH}" "${c}/repo/nix/scripts/local-flake-migrate.sh" "$@"
}
# そのケースの checkout で今の雛形を描く (dotfiles-private の入力は本体の stub)。$1: ケース、残り: render に足す引数
render_case() {
  local c=$1
  shift
  migrate "${c}" render --file "${c}/repo/nix/scripts/setup-local-flake.sh" --nix-dir "${c}/repo/nix" \
    --private-dir "${c}/repo/nix/private-stub" "$@"
}
marker_of() { sed -n 's/^# 雛形の版: \([0-9a-f]*\).*/\1/p' "$1"; }
# 雛形の tmp の例 (「        # tmp = dotfiles.lib.mkHome {」から次の「        # };」まで) のコメントを 1 段外して出す
tmp_example() {
  awk '
    $0 == "        # tmp = dotfiles.lib.mkHome {" { f = 1 }
    f {
      line = $0
      if (line == "        #") line = ""
      else sub(/^        # /, "", line)
      print line
      if ($0 == "        # };") exit
    }
  ' "$1"
}
# fixture の tmp (「  tmp = dotfiles.lib.mkHome {」から次の「  };」まで) を 2 字戻して出す
fixture_example() {
  awk '
    $0 == "  tmp = dotfiles.lib.mkHome {" { f = 1 }
    f {
      line = $0
      sub(/^  /, "", line)
      print line
      if ($0 == "  };") exit
    }
  ' "$1"
}

# ---- WSL の PC (--initial と、tmp の例の Windows のユーザー名) のための道具 ----

# 要るコマンドだけを並べた PATH (uname・pwsh.exe・powershell.exe は入れない。手元の WSL で本物の pwsh.exe を呼ばないように)
isys_bin="${work}/isys-bin"
mkdir -p "${isys_bin}"
for cmd in env awk sed grep sort head tail tr cat dirname basename readlink mktemp mkdir rm cp mv ls chmod cmp diff cksum ln git id; do
  if ! p=$(command -v "${cmd}"); then
    echo "見つからない: ${cmd}" >&2
    exit 1
  fi
  ln -s "${p}" "${isys_bin}/${cmd}"
done
# 偽の uname (-s は Linux、-m は x86_64、-n は box)。shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)
uname_bin="${work}/uname-bin"
mkdir -p "${uname_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
case ${1-} in
  -m) echo x86_64 ;;
  -n) echo box ;;
  *) echo Linux ;;
esac
EOF
} >"${uname_bin}/uname"
chmod +x "${uname_bin}/uname"
# 偽の pwsh.exe と powershell.exe。呼ばれたら <HOME>/pwsh-calls に 1 行書き、FAKE_PWSH_USER (無ければ alice) を CRLF で出す。
# win_bin は両方、win_ps_bin は powershell.exe だけ
win_bin="${work}/win-bin"
win_ps_bin="${work}/win-ps-bin"
mkdir -p "${win_bin}" "${win_ps_bin}"
for exe in pwsh.exe powershell.exe; do
  {
    printf '#!%s\n' "${BASH}"
    # shellcheck disable=SC2016 # ${HOME} は偽の exe が走るときに展開させる
    printf 'printf "%%s\\n" %q >>"${HOME}/pwsh-calls"\n' "${exe}"
    cat <<'EOF'
printf '%s\r\n' "${FAKE_PWSH_USER:-alice}"
EOF
  } >"${win_bin}/${exe}"
  chmod +x "${win_bin}/${exe}"
done
cp -p "${win_bin}/powershell.exe" "${win_ps_bin}/powershell.exe"

# WSL の PC のケースを作る。new_case に、Windows のユーザーのフォルダ (<ケース>/Users/{alice,Public}) を足す
new_win_case() {
  local c
  c=$(new_case "$1")
  mkdir -p "${c}/Users/alice" "${c}/Users/Public"
  echo "${c}"
}

# WSL の PC として流す。$1: ケース、残り: setup-local-flake.sh の引数。env -i で、PATH は WIN_BIN (既定 win_bin。none なら
# 足さない)・偽の uname・isys_bin だけ。NOT_WSL=1 なら WSL でない PC として流す (WSL_DISTRO_NAME を付けず、/proc/version は
# WSL でない中身。偽の pwsh.exe は PATH にある)。
# 環境変数 (FAKE_PWSH_USER・DOTFILES_PRIVATE_DIR・DOTFILES_SETUP_WARNINGS) は呼び出し側で付ける
run_win() {
  local c=$1 wb=${WIN_BIN-${win_bin}} wsl=()
  shift
  [[ ${wb} != none ]] || wb=""
  [[ -n ${NOT_WSL-} ]] || wsl=(WSL_DISTRO_NAME=Ubuntu)
  env -i HOME="${c}/home" USER=pollenjp TMPDIR="${work}" \
    PATH="${wb:+${wb}:}${uname_bin}:${isys_bin}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_ALLOW_ANY_PATH=1 \
    DOTFILES_PRIVATE_DIR="${DOTFILES_PRIVATE_DIR:-${c}/no-private}" \
    DOTFILES_WINDOWS_USERS_DIR="${c}/Users" DOTFILES_PROC_VERSION="${work}/proc-version-linux" \
    ${wsl[@]+"${wsl[@]}"} \
    ${FAKE_PWSH_USER+"FAKE_PWSH_USER=${FAKE_PWSH_USER}"} \
    ${DOTFILES_SETUP_WARNINGS+"DOTFILES_SETUP_WARNINGS=${DOTFILES_SETUP_WARNINGS}"} \
    "${BASH}" "${c}/repo/nix/scripts/setup-local-flake.sh" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

# flake.nix の initial の塊 (「        initial = dotfiles.lib.mkHome {」から次の「        };」まで) を 8 桁戻して出す
initial_block() {
  awk '
    $0 == "        initial = dotfiles.lib.mkHome {" { f = 1 }
    f {
      line = $0
      sub(/^        /, "", line)
      print line
      if ($0 == "        };") exit
    }
  ' "$1"
}
# fixture の initial (「  initial = dotfiles.lib.mkHome {」から次の「  };」まで) を 2 桁戻して出す
fixture_initial() {
  awk '
    $0 == "  initial = dotfiles.lib.mkHome {" { f = 1 }
    f {
      line = $0
      sub(/^  /, "", line)
      print line
      if ($0 == "  };") exit
    }
  ' "$1"
}
# flake.nix から差し込んだ所 (直前の空行・「        # 初期用のホスト」で始まるコメント・塊) を除いて出す
strip_initial() {
  awk '
    held { held = 0; if ($0 ~ /^        # 初期用のホスト/) { skip = 1 } else { print "" } }
    skip { if ($0 == "        };") { skip = 0 } ; next }
    $0 == "" { held = 1; next }
    { print }
    END { if (held) print "" }
  ' "$1"
}

echo "== setup-local-flake.sh (${dir}/setup-local-flake.sh)"

# 1. 新しく作る: 印が id と同じで、ファイル全体が render --file と同じ。setup の symlink も張る
c=$(new_case t1)
run "${c}"
want_id=$(migrate "${c}" id "${c}/repo/nix/scripts/setup-local-flake.sh")
if [[ $(rc "${c}") == 0 && -n ${want_id} && $(marker_of "${c}/local/flake.nix") == "${want_id}" ]]; then
  ok "新しく作る flake.nix の「# 雛形の版:」は、local-flake-migrate.sh id の印と同じ"
else
  ng "印" "rc=$(rc "${c}") id=${want_id} file=$(marker_of "${c}/local/flake.nix" 2>/dev/null) $(err "${c}")"
fi
if migrate "${c}" render --file "${c}/repo/nix/scripts/setup-local-flake.sh" --nix-dir "${c}/repo/nix" \
  --private-dir "${c}/repo/nix/private-stub" >"${c}/rendered" \
  && cmp -s "${c}/rendered" "${c}/local/flake.nix"; then
  ok "作った flake.nix は local-flake-migrate.sh render --file の出力と同じ (描き方が本物の heredoc と合う)"
else
  ng "render と本物の heredoc が違う" "$(diff "${c}/rendered" "${c}/local/flake.nix" | head -20)"
fi
if grep -qxF "  inputs.dotfiles-private.url = \"path:${c}/repo/nix/private-stub\";" "${c}/local/flake.nix" \
  && grep -qxF '  inputs.dotfiles-private.flake = false;' "${c}/local/flake.nix" \
  && grep -qF "dotfiles-private: clone の nix/ が無いので、本体の空の stub を指しました (${c}/repo/nix/private-stub)" "${c}/out"; then
  ok "clone の nix/ が無ければ、dotfiles-private の入力は本体の stub を指し、そう出す"
else
  ng "dotfiles-private の入力 (stub)" "$(grep -n 'dotfiles-private' "${c}/local/flake.nix") $(out "${c}")"
fi

# 1a. 雛形は local と hostsWith を持たず、登録簿・dotfiles-private・このマシンだけのホストを重ねるだけ。tmp の例は fixture と同じ
if ! grep -q '^[[:space:]]*local[[:space:]]*=' "${c}/local/flake.nix" && ! grep -q 'hostsWith' "${c}/local/flake.nix" \
  && grep -qxF '      homeConfigurations = dotfiles.homeConfigurations // privateHosts // {' "${c}/local/flake.nix" \
  && grep -qxF '#   home-manager switch --flake ~/dotfiles#<ホスト>' "${c}/local/flake.nix"; then
  ok "雛形は local と hostsWith を持たず、homeConfigurations は dotfiles.homeConfigurations // privateHosts // { … }"
else
  ng "雛形の形 (local・hostsWith)" "$(grep -n 'local\|hostsWith\|homeConfigurations\|switch --flake' "${c}/local/flake.nix")"
fi
got_example=$(tmp_example "${c}/local/flake.nix")
want_example=$(fixture_example "${tmp_fixture}")
if [[ -n ${want_example} && ${got_example} == "${want_example}" ]]; then
  ok "tmp の例のコメントを 1 段外したものが、fixture (${tmp_fixture##*/}) の tmp と同じ"
else
  ng "tmp の例と fixture" "$(diff <(printf '%s\n' "${want_example}") <(printf '%s\n' "${got_example}") | head -20)"
fi

# 1b. clone の nix/ があれば、dotfiles-private の入力はそこを指す (render --file と同じ)
c=$(new_case t1b)
mkdir -p "${c}/private/nix/hosts"
DOTFILES_PRIVATE_DIR="${c}/private" run "${c}"
if [[ $(rc "${c}") == 0 ]] \
  && grep -qxF "  inputs.dotfiles-private.url = \"path:${c}/private/nix\";" "${c}/local/flake.nix" \
  && grep -qF "dotfiles-private: ${c}/private/nix を読みます" "${c}/out" \
  && migrate "${c}" render --file "${c}/repo/nix/scripts/setup-local-flake.sh" --nix-dir "${c}/repo/nix" \
    --private-dir "${c}/private/nix" >"${c}/rendered" \
  && cmp -s "${c}/rendered" "${c}/local/flake.nix"; then
  ok "clone の nix/ があれば、dotfiles-private の入力はそこを指し、render --file と同じ"
else
  ng "dotfiles-private の入力 (clone)" "rc=$(rc "${c}") $(grep -n 'dotfiles-private' "${c}/local/flake.nix") $(out "${c}") $(err "${c}")"
fi
c="${work}/t1"
if [[ -L ${c}/local/setup && $(readlink "${c}/local/setup") == "${c}/repo/nix/scripts/setup.sh" ]] \
  && grep -qF "${c}/repo/nix/scripts/local-flake-migrate.sh prepare" "${c}/local/flake.nix"; then
  ok "setup の symlink を張り、雛形の印の案内に local-flake-migrate.sh のパスを書く"
else
  ng "symlink と案内" "$(ls -l "${c}/local" 2>/dev/null)"
fi

# 2. もう一度流す (印が同じ): 警告なし、中身は変えない
cp -p "${c}/local/flake.nix" "${c}/before.nix"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && grep -q 'flake.nix: 既にあります' "${c}/out" && ! grep -q '前の雛形' "${c}/err" \
  && cmp -s "${c}/before.nix" "${c}/local/flake.nix"; then
  ok "印が今の雛形と同じなら「既にあります」で、雛形の版の警告は出さない"
else
  ng "同じ印でもう一度" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 3. 印が前の版: 移し方の警告。ファイルは変えない。DOTFILES_SETUP_WARNINGS にも残す
sed -i 's/^# 雛形の版: [0-9a-f]*/# 雛形の版: 0badf00d/' "${c}/local/flake.nix"
cp -p "${c}/local/flake.nix" "${c}/before.nix"
: >"${c}/warnings"
DOTFILES_SETUP_WARNINGS="${c}/warnings" run "${c}"
if [[ $(rc "${c}") == 0 ]] && grep -qF "!! flake.nix は前の雛形から作られています (雛形の版 0badf00d → ${want_id})。" "${c}/err" \
  && grep -qF "local-flake-migrate.sh prepare" "${c}/err" && grep -q 'pjp-dotfiles-local-flake-migrate' "${c}/err" \
  && grep -q -- '--force' "${c}/err" && cmp -s "${c}/before.nix" "${c}/local/flake.nix" \
  && grep -qF 'flake.nix は前の雛形から作られています' "${c}/warnings"; then
  ok "印が前の版なら、移し方と --force で値が消えることを警告し (まとめにも残す)、ファイルは変えない"
else
  ng "前の版の印" "rc=$(rc "${c}") $(err "${c}") warnings=$(cat "${c}/warnings")"
fi

# 4. 印の行が無い: 同じ警告 (印なし)
sed -i '/^# 雛形の版: /d' "${c}/local/flake.nix"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && grep -qF "!! flake.nix は前の雛形から作られています (雛形の版 印なし → ${want_id})。" "${c}/err"; then
  ok "印の行が無ければ、印なしとして同じ警告"
else
  ng "印なし" "rc=$(rc "${c}") $(err "${c}")"
fi

# 5. --force で作り直すと、印が今の値になる
run "${c}" --force
if [[ $(rc "${c}") == 0 && $(marker_of "${c}/local/flake.nix") == "${want_id}" ]] && grep -q 'flake.nix: 書きました' "${c}/out"; then
  ok "--force で作り直すと、印が今の値になる"
else
  ng "--force" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 6. hostsWith・notion.profile の語が無い形 (今の雛形も持たない): それの警告は出さず、印が無ければ前の雛形の警告だけ
c=$(new_case t6)
mkdir -p "${c}/local"
printf '{\n  inputs.dotfiles.url = "path:%s";\n  outputs = { dotfiles, ... }: { homeConfigurations = dotfiles.homeConfigurations; };\n}\n' \
  "${c}/repo/nix" >"${c}/local/flake.nix"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && ! grep -q '古い雛形のまま' "${c}/err" && ! grep -q 'notion.profile' "${c}/err" \
  && grep -q 'flake.nix は前の雛形から作られています (雛形の版 印なし' "${c}/err" \
  && [[ $(grep -c 'local-flake-migrate.sh prepare' "${c}/err") == 1 ]]; then
  ok "hostsWith・notion.profile の語が無くても、それの警告は出さず、印が無いことだけを知らせる"
else
  ng "hostsWith・notion.profile の無い形" "rc=$(rc "${c}") $(err "${c}")"
fi

# 7. 別のパスを指す flake.nix: 今の警告で、雛形の版は見ない
c=$(new_case t7)
mkdir -p "${c}/local"
printf '{\n  inputs.dotfiles.url = "path:/somewhere/else/nix";\n}\n' >"${c}/local/flake.nix"
run "${c}"
if [[ $(rc "${c}") == 0 ]] && grep -q '別のパスを指しています' "${c}/err" && ! grep -q '前の雛形' "${c}/err"; then
  ok "別のパスを指す flake.nix には今の警告を出し、雛形の版は見ない"
else
  ng "別のパス" "rc=$(rc "${c}") $(err "${c}")"
fi

# ---- --initial ----

# 8. flake.nix が無い: 雛形を描き、initial の塊を差し込む
c=$(new_win_case i1)
run_win "${c}" --initial
got=$(initial_block "${c}/local/flake.nix")
want=$(fixture_initial "${initial_fixture}")
if [[ $(rc "${c}") == 0 && -n ${want} && ${got} == "${want}" ]] \
  && grep -qF '        # 初期用のホスト (setup-local-flake.sh --initial が書いた)' "${c}/local/flake.nix"; then
  ok "--initial: 雛形に、fixture (${initial_fixture##*/}) と同じ initial の塊とコメントを差し込む"
else
  ng "--initial の塊" "rc=$(rc "${c}") $(err "${c}") $(diff <(printf '%s\n' "${want}") <(printf '%s\n' "${got}") | head -20)"
fi
if migrate "${c}" render --file "${c}/repo/nix/scripts/setup-local-flake.sh" --nix-dir "${c}/repo/nix" \
  --private-dir "${c}/repo/nix/private-stub" >"${c}/rendered" \
  && strip_initial "${c}/local/flake.nix" >"${c}/stripped" && cmp -s "${c}/rendered" "${c}/stripped"; then
  ok "--initial: 差し込んだ所を除くと render --file と 1 バイトも違わない (雛形の版の印も変えない)"
else
  ng "--initial の雛形" "$(diff "${c}/rendered" "${c}/stripped" | head -20)"
fi
if grep -qF 'alice' "${c}/out" && grep -qF -- '/dotfiles/setup --new-machine' "${c}/out" \
  && grep -qF 'setup-local-flake.sh --force で作り直す' "${c}/out" && ! grep -qF 'local-flake-migrate.sh prepare' "${c}/out"; then
  ok "--initial: Windows のユーザー名と次に打つ --new-machine、clone を読ませるのは登録して merge したあとの --force と出す"
else
  ng "--initial の出力" "$(out "${c}")"
fi

# 9. --windows-user: 名前を引かずに (pwsh.exe を呼ばない) initial と tmp の例に入れる。差し込んだ所を除くと
#    render --file --windows-user <その名前> と 1 バイトも違わない
c=$(new_win_case i2)
mkdir -p "${c}/Users/carol"
run_win "${c}" --initial --windows-user carol
render_case "${c}" --windows-user carol >"${c}/rendered" 2>"${c}/render-err"
strip_initial "${c}/local/flake.nix" >"${c}/stripped"
if [[ $(rc "${c}") == 0 && ! -e ${c}/home/pwsh-calls ]] \
  && grep -qxF '            windowsUserName = "carol";' "${c}/local/flake.nix" \
  && grep -qxF '        #     windowsUserName = "carol";' "${c}/local/flake.nix" \
  && cmp -s "${c}/rendered" "${c}/stripped" && grep -qF 'windowsUserName に carol を入れました' "${c}/out"; then
  ok "--windows-user: 名前を引かずに (pwsh.exe を呼ばない) initial と tmp の例に入れ、差し込んだ所を除くと render --windows-user と同じ"
else
  ng "--windows-user" "rc=$(rc "${c}") calls=$(cat "${c}/home/pwsh-calls" 2>/dev/null) $(err "${c}") $(cat "${c}/render-err") $(diff "${c}/rendered" "${c}/stripped" | head -20)"
fi

# 10. 2 回目の --initial: 既にあるので中身を変えない
c="${work}/i1"
cp -p "${c}/local/flake.nix" "${c}/before.nix"
run_win "${c}" --initial
if [[ $(rc "${c}") == 0 ]] && grep -qF '初期用のホスト initial は既にあります' "${c}/out" \
  && cmp -s "${c}/before.nix" "${c}/local/flake.nix"; then
  ok "--initial: initial が既にあれば「既にあります」で、中身を変えない"
else
  ng "--initial (2 回目)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 11. 今の雛形のまま (先に引数なしで作った・clone の nix/ を指す雛形も) なら差し込む
c=$(new_win_case i3)
run "${c}"
run_win "${c}" --initial
if [[ $(rc "${c}") == 0 ]] && cmp -s "${work}/i1/local/flake.nix" <(sed "s|${c}/|${work}/i1/|g" "${c}/local/flake.nix") \
  && grep -qF '今の雛形のままなので' "${c}/out"; then
  ok "--initial: 今の雛形のまま (引数なしで作ったもの) なら、initial を差し込む"
else
  ng "--initial (今の雛形)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi
c=$(new_win_case i3b)
mkdir -p "${c}/private/nix/hosts"
DOTFILES_PRIVATE_DIR="${c}/private" run "${c}"
DOTFILES_PRIVATE_DIR="${c}/private" run_win "${c}" --initial
if [[ $(rc "${c}") == 0 && $(initial_block "${c}/local/flake.nix") == "$(fixture_initial "${initial_fixture}")" ]] \
  && grep -qxF "  inputs.dotfiles-private.url = \"path:${c}/private/nix\";" "${c}/local/flake.nix"; then
  ok "--initial: clone の nix/ を指す今の雛形にも差し込む"
else
  ng "--initial (clone を指す雛形)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 12. 手を入れた flake.nix: 書かずに 1。手で足す塊と --force --initial を出す
c=$(new_win_case i4)
run "${c}"
sed -i 's|^        # tmp = dotfiles.lib.mkHome {$|        tmp = dotfiles.lib.mkHome { username = "pollenjp"; system = "x86_64-linux"; };\n&|' "${c}/local/flake.nix"
cp -p "${c}/local/flake.nix" "${c}/before.nix"
run_win "${c}" --initial
if [[ $(rc "${c}") == 1 ]] && cmp -s "${c}/before.nix" "${c}/local/flake.nix" \
  && grep -qF 'initial = dotfiles.lib.mkHome {' "${c}/err" && grep -qF -- '--force --initial' "${c}/err"; then
  ok "--initial: 手を入れた flake.nix には書かずに 1 で、手で足す塊と --force --initial を出す"
else
  ng "--initial (手を入れた)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 13. --force --initial: 作り直して差し込む (12 のファイルから)
run_win "${c}" --force --initial
if [[ $(rc "${c}") == 0 ]] && ! grep -q '^        tmp = ' "${c}/local/flake.nix" \
  && [[ $(initial_block "${c}/local/flake.nix") == "$(fixture_initial "${initial_fixture}")" ]]; then
  ok "--force --initial: 作り直して initial を差し込む (手で足した tmp は消える)"
else
  ng "--force --initial" "rc=$(rc "${c}") $(err "${c}")"
fi

# 14. WSL でない: 書かずに 1 (flake.nix を作らない)
c=$(new_win_case i5)
NOT_WSL=1 run_win "${c}" --initial
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF 'WSL ではありません' "${c}/err"; then
  ok "--initial: WSL でなければ書かずに 1"
else
  ng "--initial (WSL でない)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 15. Windows のユーザー名を引けない (pwsh.exe も powershell.exe も無い): 書かずに 1、--windows-user を案内する
c=$(new_win_case i6)
WIN_BIN=none run_win "${c}" --initial
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF -- '--windows-user' "${c}/err"; then
  ok "--initial: Windows のユーザー名を引けなければ書かずに 1 で、--windows-user を案内する"
else
  ng "--initial (引けない)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 16. <Users>/<名前> が無い: 候補 (Public などは除く) と --windows-user を出して 1
c=$(new_win_case i7)
FAKE_PWSH_USER=dave run_win "${c}" --initial
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF "${c}/Users/dave" "${c}/err" \
  && grep -qF 'alice' "${c}/err" && ! grep -qF 'Public' "${c}/err" && grep -qF -- '--windows-user' "${c}/err"; then
  ok "--initial: Windows のユーザーのフォルダが無ければ、候補 (Public などは除く) と --windows-user を出して 1"
else
  ng "--initial (フォルダが無い)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 17. Nix の文字列に書けない文字: 書かずに 1
c=$(new_win_case i8)
mkdir -p "${c}/Users/a\"b"
run_win "${c}" --initial --windows-user 'a"b'
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF 'Nix の文字列に書けない文字' "${c}/err"; then
  ok "--initial: 名前に \" があれば書かずに 1"
else
  ng "--initial (書けない文字)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 18. pwsh.exe が無く powershell.exe だけ: 書いたうえで PowerShell 7 の警告 (まとめにも)
c=$(new_win_case i9)
: >"${c}/warnings"
WIN_BIN=${win_ps_bin} DOTFILES_SETUP_WARNINGS="${c}/warnings" run_win "${c}" --initial
if [[ $(rc "${c}") == 0 && -f ${c}/local/flake.nix ]] && grep -qF 'PowerShell 7' "${c}/err" \
  && grep -qF 'PowerShell 7' "${c}/warnings"; then
  ok "--initial: pwsh.exe が無ければ、書いたうえで PowerShell 7 を入れるよう警告する (まとめにも)"
else
  ng "--initial (pwsh.exe が無い)" "rc=$(rc "${c}") $(err "${c}") warnings=$(cat "${c}/warnings")"
fi

# 19. --windows-user を --initial なしで: 1
c=$(new_win_case i10)
run_win "${c}" --windows-user alice
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF -- '--windows-user は --initial と一緒に' "${c}/err"; then
  ok "--windows-user を --initial なしで渡すと 1"
else
  ng "--windows-user (--initial なし)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 20. 日本語と空白を含む名前
c=$(new_win_case i11)
mkdir -p "${c}/Users/山田 太郎"
FAKE_PWSH_USER='山田 太郎' run_win "${c}" --initial
if [[ $(rc "${c}") == 0 ]] && grep -qxF '            windowsUserName = "山田 太郎";' "${c}/local/flake.nix"; then
  ok "--initial: 日本語と空白を含む名前もそのまま書く"
else
  ng "--initial (日本語)" "rc=$(rc "${c}") $(err "${c}")"
fi

# 21. initial が既にある: 値を引きも確かめもせず (pwsh.exe が別の名前を返しても) 0 で変えない。--windows-user が違えば、変え方を出す
c=$(new_win_case i12)
run_win "${c}" --initial
cp -p "${c}/local/flake.nix" "${c}/before.nix"
FAKE_PWSH_USER=dave run_win "${c}" --initial
r1=$(rc "${c}")
o1=$(out "${c}")
run_win "${c}" --initial --windows-user carol
if [[ ${r1} == 0 && ${o1} == *'初期用のホスト initial は既にあります'* && $(rc "${c}") == 0 ]] \
  && cmp -s "${c}/before.nix" "${c}/local/flake.nix" \
  && grep -qF -- '--force --initial --windows-user carol' "${c}/out"; then
  ok "--initial: initial が既にあれば値を引きも確かめもせず 0。--windows-user が違えば、使っていないことと変え方を出す"
else
  ng "--initial (既にある・値の確かめ)" "1 回目=${r1} (${o1}) / --windows-user: rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 22. --windows-user でも WSL でなければ 1 (/mnt/c/Users/<名前> があっても)
c=$(new_win_case i13)
mkdir -p "${c}/Users/carol"
NOT_WSL=1 run_win "${c}" --initial --windows-user carol
if [[ $(rc "${c}") == 1 && ! -e ${c}/local/flake.nix ]] && grep -qF 'WSL ではありません' "${c}/err"; then
  ok "--initial --windows-user: WSL でなければ、フォルダがあっても書かずに 1"
else
  ng "--windows-user (WSL でない)" "rc=$(rc "${c}") $(err "${c}")"
fi

# ---- tmp の例の Windows のユーザー名 (--initial なし) ----

# 23. WSL の PC で flake.nix が無いときに描く: tmp の例 (コメント) の windowsUserName に引いた名前を入れる。ファイル全体が
#     render --file --windows-user <名前> と同じ (行はコメントのまま・印は変えない)。入れた名前を出し、警告にもまとめにも出さない
c=$(new_win_case w1)
mkdir -p "${c}/Users/carol"
: >"${c}/warnings"
FAKE_PWSH_USER=carol DOTFILES_SETUP_WARNINGS="${c}/warnings" run_win "${c}"
render_case "${c}" --windows-user carol >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 && $(marker_of "${c}/local/flake.nix") == "${want_id}" ]] \
  && grep -qxF '        #     windowsUserName = "carol";' "${c}/local/flake.nix" \
  && ! grep -qF 'windowsUserName = "alice";' "${c}/local/flake.nix" && ! grep -q '^        initial = ' "${c}/local/flake.nix" \
  && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && grep -qF 'tmp の例 (コメント) の windowsUserName に carol を入れました' "${c}/out" \
  && ! grep -qF 'windowsUserName' "${c}/err" && ! grep -qF 'windowsUserName' "${c}/warnings"; then
  ok "WSL の PC で描くと、tmp の例の windowsUserName (コメント) に引いた名前を入れる (render --windows-user と同じ・印は同じ)"
else
  ng "tmp の例の名前 (新しく作る)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}") $(cat "${c}/render-err") $(diff "${c}/rendered" "${c}/local/flake.nix" | head -20)"
fi
# もう一度流す (--force なし): 触らず、pwsh.exe も呼ばない。名前の入った例でも印は今の雛形と同じ (前の雛形の警告を出さない)
cp -p "${c}/local/flake.nix" "${c}/before.nix"
calls_before=$(wc -l <"${c}/home/pwsh-calls")
FAKE_PWSH_USER=carol run_win "${c}"
if [[ $(rc "${c}") == 0 && ${calls_before} -eq 1 && $(wc -l <"${c}/home/pwsh-calls") -eq 1 ]] \
  && grep -qF 'flake.nix: 既にあります' "${c}/out" && ! grep -qF '前の雛形' "${c}/err" \
  && cmp -s "${c}/before.nix" "${c}/local/flake.nix"; then
  ok "名前の入った flake.nix は、もう一度流しても触らず (pwsh.exe を呼ばない)、前の雛形の警告も出さない"
else
  ng "tmp の例の名前 (2 回目)" "rc=$(rc "${c}") calls=${calls_before}→$(wc -l <"${c}/home/pwsh-calls") $(out "${c}") $(err "${c}")"
fi

# 24. --force で作り直すときも入れる (WSL でない PC として作り物の名前で描いたファイルから)
c=$(new_win_case w2)
mkdir -p "${c}/Users/carol"
run "${c}"
FAKE_PWSH_USER=carol run_win "${c}" --force
render_case "${c}" --windows-user carol >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 ]] && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && grep -qF 'windowsUserName に carol を入れました' "${c}/out"; then
  ok "--force で作り直すときも、WSL の PC なら tmp の例に引いた名前を入れる"
else
  ng "tmp の例の名前 (--force)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}") $(diff "${c}/rendered" "${c}/local/flake.nix" | head -20)"
fi

# 25. WSL の PC で名前が決まらない: 止めずに作り物の名前のまま書き (render --file と同じ)、わけを 1 行出す。
#     stderr の警告と、setup の警告のまとめ (DOTFILES_SETUP_WARNINGS) には出さない
#     (a) pwsh.exe も powershell.exe も無い (interop の不調と同じ)
c=$(new_win_case w3)
: >"${c}/warnings"
WIN_BIN=none DOTFILES_SETUP_WARNINGS="${c}/warnings" run_win "${c}"
render_case "${c}" >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 ]] && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && [[ $(grep -c 'windowsUserName は作り物の名前のままです' "${c}/out") == 1 ]] && grep -qF 'interop' "${c}/out" \
  && ! grep -qF 'windowsUserName' "${c}/err" && ! grep -qF 'windowsUserName' "${c}/warnings"; then
  ok "WSL の PC で名前を引けなければ、止めずに作り物の名前のまま書き、わけを 1 行出す (警告とまとめには出さない)"
else
  ng "tmp の例の名前 (引けない)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}") warnings=$(cat "${c}/warnings")"
fi
#     (b) <Users>/<名前> が無い
c=$(new_win_case w4)
FAKE_PWSH_USER=dave run_win "${c}"
render_case "${c}" >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 && -s ${c}/home/pwsh-calls ]] && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && grep -qF "${c}/Users/dave が無い" "${c}/out" && ! grep -qF 'windowsUserName' "${c}/err"; then
  ok "WSL の PC で <Users>/<名前> が無ければ、作り物の名前のまま書き、フォルダが無いと 1 行出す"
else
  ng "tmp の例の名前 (フォルダが無い)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi
#     (c) 名前に Nix の文字列に書けない文字 (")
c=$(new_win_case w5)
mkdir -p "${c}/Users/a\"b"
FAKE_PWSH_USER='a"b' run_win "${c}"
render_case "${c}" >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 ]] && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && grep -qF 'Nix の文字列に書けない文字' "${c}/out" && ! grep -qF 'windowsUserName' "${c}/err"; then
  ok "WSL の PC で名前に \" があれば、作り物の名前のまま書き、わけを 1 行出す"
else
  ng "tmp の例の名前 (書けない文字)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}")"
fi

# 26. WSL でない PC: pwsh.exe が PATH にあっても呼ばず、作り物の名前のまま書き、何も言わない
c=$(new_win_case w6)
NOT_WSL=1 run_win "${c}"
render_case "${c}" >"${c}/rendered" 2>"${c}/render-err"
if [[ $(rc "${c}") == 0 && ! -e ${c}/home/pwsh-calls ]] && cmp -s "${c}/rendered" "${c}/local/flake.nix" \
  && ! grep -qF 'windowsUserName' "${c}/out" && ! grep -qF 'windowsUserName' "${c}/err"; then
  ok "WSL でない PC では pwsh.exe を呼ばず、tmp の例は作り物の名前のままで、何も言わない"
else
  ng "tmp の例の名前 (WSL でない)" "rc=$(rc "${c}") calls=$(cat "${c}/home/pwsh-calls" 2>/dev/null) $(out "${c}") $(err "${c}")"
fi

# 27. 名前の入った例 (WSL の PC で描いたまま) は手を入れたと見ず、--initial が initial を差し込む (例は initial の名前になる)
c=$(new_win_case w7)
mkdir -p "${c}/Users/carol"
FAKE_PWSH_USER=carol run_win "${c}"
run_win "${c}" --initial
render_case "${c}" >"${c}/rendered" 2>"${c}/render-err"
strip_initial "${c}/local/flake.nix" >"${c}/stripped"
if [[ $(rc "${c}") == 0 ]] && grep -qF '今の雛形のままなので' "${c}/out" \
  && [[ $(initial_block "${c}/local/flake.nix") == "$(fixture_initial "${initial_fixture}")" ]] \
  && grep -qxF '        #     windowsUserName = "alice";' "${c}/local/flake.nix" && cmp -s "${c}/rendered" "${c}/stripped"; then
  ok "--initial: 名前の入った例 (WSL の PC で描いたまま) は手を入れたと見ず、initial を差し込む (例は initial の名前)"
else
  ng "--initial (名前の入った例)" "rc=$(rc "${c}") $(out "${c}") $(err "${c}") $(diff "${c}/rendered" "${c}/stripped" | head -20)"
fi
#     名前の入った例に、別の手を入れたもの (tmp を足した) には書かずに 1
c=$(new_win_case w8)
mkdir -p "${c}/Users/carol"
FAKE_PWSH_USER=carol run_win "${c}"
sed -i 's|^        # tmp = dotfiles.lib.mkHome {$|        tmp = dotfiles.lib.mkHome { username = "pollenjp"; system = "x86_64-linux"; };\n&|' "${c}/local/flake.nix"
cp -p "${c}/local/flake.nix" "${c}/before.nix"
run_win "${c}" --initial
if [[ $(rc "${c}") == 1 ]] && cmp -s "${c}/before.nix" "${c}/local/flake.nix" && grep -qF -- '--force --initial' "${c}/err"; then
  ok "--initial: 名前の入った例のほかに手を入れた flake.nix には、書かずに 1"
else
  ng "--initial (名前の入った例 + 手を入れた)" "rc=$(rc "${c}") $(err "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
