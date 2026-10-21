#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/setup-local-flake.sh (~/dotfiles にローカル専用の flake を用意する) を、使い捨ての checkout と
# HOME で確かめる。
#
#   bash nix/tests/setup-local-flake.test.sh [<nix/scripts のパス> [<tmp の例の fixture のパス>]]
#
# flake の checks (setup-local-flake-test) が Nix のサンドボックスで流す。fixture の既定は
# nix/tests/fixtures/local-flake-tmp/tmp.nix (評価は local-flake-tmp-state が見る)。
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

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
tmp_fixture=${2:-${here}/fixtures/local-flake-tmp/tmp.nix}
work=$(mktemp -d "${TMPDIR:-/tmp}/setup-local-flake-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

for f in "${dir}/setup-local-flake.sh" "${dir}/local-flake-migrate.sh" "${tmp_fixture}"; do
  if [[ ! -f ${f} ]]; then
    echo "見つからない: ${f}" >&2
    exit 1
  fi
done

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

# $1: ケース、残り: setup-local-flake.sh の引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す
run() {
  local c=$1
  shift
  # dotfiles-private の clone は、渡さなければ無い場所にする (手元の本物の clone を見せない)
  HOME="${c}/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    DOTFILES_LOCAL_DIR="${c}/local" DOTFILES_ALLOW_ANY_PATH=1 \
    DOTFILES_PRIVATE_DIR="${DOTFILES_PRIVATE_DIR:-${c}/no-private}" \
    env ${DOTFILES_SETUP_WARNINGS+"DOTFILES_SETUP_WARNINGS=${DOTFILES_SETUP_WARNINGS}"} \
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

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
