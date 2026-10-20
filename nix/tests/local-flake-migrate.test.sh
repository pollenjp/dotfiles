#!/usr/bin/env bash
# shellcheck shell=bash
# 雛形の原文 (展開する前の ${nix_dir} など) を文字のまま書く所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/scripts/local-flake-migrate.sh (旧いローカル flake を、値を引き継いで今の雛形へ移す) を、使い捨ての
# repo と偽の nix で確かめる。
#
#   bash nix/tests/local-flake-migrate.test.sh [<nix/scripts のパス>]
#
# flake の checks (local-flake-migrate-test) が Nix のサンドボックスで流す。
#
# ## 確かめること
#
#   - render は雛形の原文の ${nix_dir}・${template_id}・\$・\`・\\ を bash の heredoc と同じに描き、ほかの展開
#     ($NAME・${...}・$(...)・$[...]・`...`・特殊なパラメータ・行末の \) があれば描かずに 1 で終わる
#   - id は heredoc の原文から 8 桁の 16 進を出す。heredoc の中を変えると変わり、外を変えても変わらない。
#     開きの行 (`  cat >"${flake_file}" <<EOS`) が 1 つでない・閉じの EOS が無い script は、id も render も 1
#   - render --rev は、repo の履歴の setup-local-flake.sh の版を描く (古い版の script を実行しない)
#   - check は、ローカル flake の「# 雛形の版:」の印が今の雛形と同じなら何も出さず 0 (中身を利用者が書き換えて
#     いても)、違えば「旧い印 → 今の印」(印が無ければ「印なし → 今の印」) を出して 1、inputs.dotfiles.url の
#     path: が無い・flake.nix が無いなら 2。git も nix も無い PATH で動く
#   - status は、同じ版なら 0、印の版があればその commit を、印が無ければ履歴で最も近い版を出して 1
#   - prepare は、印があればその版を、無い・履歴に無い・印の行を消したなら差分の最も小さい版を元の雛形にし、
#     手元・元の雛形・今の雛形を 3-way merge して new/flake.nix に置く。利用者の値を残し、今の雛形の印・説明・
#     節・例を取り込む。元の flake.nix には触らず、old/ に同じ中身の写しを置く。prepare.env に元の版の決め方と
#     衝突の数を書き、次に打つもの (compare) を出す
#   - 衝突は、片側が元の行の前後に足しただけ (今が後ろ・前に足し、手元が直した・消した / 手元が足し、今が直した)
#     なら自動で解き、両側が同じ所に足した・同じ行を両側が直したなら diff3 の印のまま残して行番号を出す
#   - prepare は、元と今が同じ版なら「移すものはありません」と出して作業場所を作らない。url が script の repo と
#     別の checkout を指せば、そのパスで描いてそう出す。flake.lock が無くても進む。--out が空でなければ 2

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
dir=${1:-${here}/../scripts}
src=${dir}/local-flake-migrate.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/local-flake-migrate-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

if [[ ! -f ${src} ]]; then
  echo "見つからない: ${src}" >&2
  exit 1
fi

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

tgit() {
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git -c user.name=tester -c user.email=tester@example.test -c init.defaultBranch=main -c commit.gpgsign=false "$@"
}
mkdir -p "${work}/githome"

# 偽の setup-local-flake.sh を書く。$1: パス、$2: heredoc の中身、$3: heredoc の外に置く行 (省略可)。
# 開きの行は本物と同じく `  cat >"${flake_file}" <<EOS` (2 字下げ)
fake_slf() {
  mkdir -p "$(dirname "$1")"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# 偽の setup-local-flake.sh\n'
    printf '%s\n' "${3:-echo 前の処理}"
    printf 'if true; then\n'
    printf '  cat >"${flake_file}" <<EOS\n'
    printf '%s\n' "$2"
    printf 'EOS\n'
    printf 'fi\n'
  } >"$1"
}

# 使い捨ての repo を作り、写した local-flake-migrate.sh の場所を出す。script は 2 つ上を repo と見る
new_repo() {
  local r="${work}/$1"
  mkdir -p "${r}/nix/scripts"
  cp "${src}" "${r}/nix/scripts/local-flake-migrate.sh"
  tgit -C "${r}" init -q
  echo "${r}"
}

# $1: repo、残り: script の引数。stdout・stderr・終了コードを <repo>/{out,err,rc} に残す
run() {
  local r=$1
  shift
  HOME="${work}/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" "$@" >"${r}/out" 2>"${r}/err"
  echo $? >"${r}/rc"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

echo "== local-flake-migrate.sh (${src})"

# 1. render: 置き換える展開
r=$(new_repo r1)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '# 版: ${template_id}
  inputs.dotfiles.url = "path:${nix_dir}";
  # pwsh.exe -Command '"'"'\$env:USERNAME'"'"'
  a \`x\` b
  c\\d
  費用は $ 5 と $'"'"'x'"'"''
run "${r}" id "${r}/nix/scripts/setup-local-flake.sh"
id1=$(out "${r}")
run "${r}" render --file "${r}/nix/scripts/setup-local-flake.sh" --nix-dir /N
want="# 版: ${id1}
  inputs.dotfiles.url = \"path:/N\";
  # pwsh.exe -Command '\$env:USERNAME'
  a \`x\` b
  c\\d
  費用は \$ 5 と \$'x'"
if [[ $(rc "${r}") == 0 && $(out "${r}") == "${want}" ]]; then
  ok "render は \${nix_dir}・\${template_id}・\\\$・\\\`・\\\\ を heredoc と同じに描く"
else
  ng "render の置き換え" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
# 同じ偽の script を bash で流して heredoc を本当に展開させ、render と比べる (偽の script はこのテストが書いたもの)
flake_file="${r}/real.out" nix_dir=/N template_id="${id1}" "${BASH}" "${r}/nix/scripts/setup-local-flake.sh" >/dev/null
if [[ $(cat "${r}/real.out") == "$(out "${r}")" ]]; then
  ok "render の出力は、同じ heredoc を bash が展開したものと同じ"
else
  ng "render と bash の展開が違う" "bash=$(cat "${r}/real.out") render=$(out "${r}")"
fi
if [[ ${id1} =~ ^[0-9a-f]{8}$ ]]; then
  ok "id は 8 桁の 16 進"
else
  ng "id の形" "${id1}"
fi

# 2. render: 描けない展開
# shellcheck disable=SC1003 # 最後の 'x \' は、行末の \ を確かめる
for body in 'x $HOME y' 'x ${other} y' 'x $(date) y' 'x $[1+1] y' 'x `date` y' 'x $1 y' 'x $@ y' 'x \'; do
  fake_slf "${r}/nix/scripts/setup-local-flake.sh" "${body}"
  run "${r}" render --file "${r}/nix/scripts/setup-local-flake.sh" --nix-dir /N
  if [[ $(rc "${r}") == 1 ]] && grep -q '描けない' "${r}/err"; then
    ok "render は描けない展開で 1 を返す: ${body}"
  else
    ng "描けない展開: ${body}" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
  fi
done

# 3. id: heredoc の中を変えると変わり、外を変えても変わらない。stdin でも同じ
fake_slf "${r}/a.sh" 'line 1
line 2' 'echo 外 A'
fake_slf "${r}/b.sh" 'line 1
line 2' 'echo 外 B'
fake_slf "${r}/c.sh" 'line 1
line 3' 'echo 外 A'
run "${r}" id "${r}/a.sh"
id_a=$(out "${r}")
run "${r}" id "${r}/b.sh"
id_b=$(out "${r}")
run "${r}" id "${r}/c.sh"
id_c=$(out "${r}")
HOME="${work}/githome" "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" id - <"${r}/a.sh" >"${r}/out" 2>"${r}/err"
id_stdin=$(out "${r}")
if [[ -n ${id_a} && ${id_a} == "${id_b}" ]]; then
  ok "id は heredoc の外を変えても変わらない"
else
  ng "id が heredoc の外で変わる" "a=${id_a} b=${id_b}"
fi
if [[ -n ${id_a} && ${id_a} != "${id_c}" ]]; then
  ok "id は heredoc の中を変えると変わる"
else
  ng "id が heredoc の中で変わらない" "a=${id_a} c=${id_c}"
fi
if [[ ${id_stdin} == "${id_a}" ]]; then
  ok "id - は stdin の script の印を出す"
else
  ng "id - (stdin)" "a=${id_a} stdin=${id_stdin}"
fi

# 4. 開きの行が 1 つでない・閉じの EOS が無い
printf '#!/usr/bin/env bash\necho 雛形が無い\n' >"${r}/none.sh"
{
  cat "${r}/a.sh"
  printf '  cat >"${flake_file}" <<EOS\nもう 1 つ\nEOS\n'
} >"${r}/two.sh"
printf '#!/usr/bin/env bash\n  cat >"${flake_file}" <<EOS\n閉じない\n' >"${r}/open.sh"
for f in none two open; do
  run "${r}" id "${r}/${f}.sh"
  rc_id=$(rc "${r}")
  run "${r}" render --file "${r}/${f}.sh" --nix-dir /N
  if [[ ${rc_id} == 1 && $(rc "${r}") == 1 ]]; then
    ok "開きの行か閉じの行がおかしい script (${f}) は、id も render も 1"
  else
    ng "おかしい script (${f})" "id rc=${rc_id} render rc=$(rc "${r}") err=$(err "${r}")"
  fi
done

# 5. render --rev: repo の履歴の版を描く
r=$(new_repo r5)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '版 1: ${nix_dir}'
tgit -C "${r}" add -A
tgit -C "${r}" commit -qm v1
v1=$(tgit -C "${r}" rev-parse HEAD)
fake_slf "${r}/nix/scripts/setup-local-flake.sh" '版 2: ${nix_dir}'
tgit -C "${r}" commit -qam v2
run "${r}" render --rev "${v1}" --nix-dir /N
if [[ $(rc "${r}") == 0 && $(out "${r}") == '版 1: /N' ]]; then
  ok "render --rev は履歴の版を描く"
else
  ng "render --rev" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
run "${r}" render --rev HEAD --nix-dir /N
if [[ $(rc "${r}") == 0 && $(out "${r}") == '版 2: /N' ]]; then
  ok "render --rev HEAD は今の commit の版を描く"
else
  ng "render --rev HEAD" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi

# ---- status / check / prepare で使う版 ----
# v1: 印の無いころの雛形。v2: 印を入れ、説明を 1 行直した。v3 (今): 説明をさらに直し、port の例の直後に節を
# 足し、tmp の例の 1 行を書き換えた
tmpl_v1='# ローカル専用の flake。
{
  inputs.dotfiles.url = "path:${nix_dir}";
  outputs =
    { dotfiles, ... }:
    let
      local = {
        # Dev Tracker を使うか。
        # 反映は setup --update。
        dotfiles.claude.devTracker.enable = false;

        # 待ち受ける port。
        # dotfiles.ccPages.port = 7778;
      };
    in
    {
      homeConfigurations = dotfiles.lib.hostsWith [ local ] // {
        # tmp = dotfiles.lib.mkHome {
        #   wsl.onePassword.enable = true;
        # };
      };
    };
}'
tmpl_v2=${tmpl_v1/'# ローカル専用の flake。'/'# ローカル専用の flake。
# 雛形の版: ${template_id}'}
tmpl_v2=${tmpl_v2/'# Dev Tracker を使うか。'/'# Notion Dev Tracker を使うか。'}
tmpl_v3=${tmpl_v2/'# Notion Dev Tracker を使うか。'/'# Notion Dev Tracker (pjp-dev-tracker) を使うか。'}
tmpl_v3=${tmpl_v3/'        # dotfiles.ccPages.port = 7778;'/'        # dotfiles.ccPages.port = 7778;

        # 解説動画を作り始めるか。
        # dotfiles.claude.videoOffer.autoStart.enable = true;'}
tmpl_v3=${tmpl_v3/'#   wsl.onePassword.enable = true;'/'#   onePassword.enable = true;'}

# v1・v2・v3 を commit した repo を作り、その場所を出す。v3 は作業ツリーにも残る。
# 各版の commit は <repo>/rev-v1 などに書く
history_repo() {
  local r v
  r=$(new_repo "$1")
  for v in 1 2 3; do
    local -n body="tmpl_v${v}"
    fake_slf "${r}/nix/scripts/setup-local-flake.sh" "${body}"
    unset -n body
    tgit -C "${r}" add -A
    tgit -C "${r}" commit -qm "v${v}"
    tgit -C "${r}" rev-parse --short HEAD >"${r}/rev-v${v}"
  done
  echo "${r}"
}

# 版 ($2: v1・v2・v3) を描いて、利用者の直し (devTracker を true、port のコメントを外す) を当てた flake.nix を
# <repo>/local に置く。$3 を渡せば ${nix_dir} をそのパスで描く (既定 <repo>/nix)
user_flake() {
  local r=$1 rev
  rev=$(cat "${r}/rev-$2")
  mkdir -p "${r}/local"
  HOME="${work}/githome" "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" render --rev "${rev}" --nix-dir "${3:-${r}/nix}" \
    | sed -e 's/devTracker.enable = false;/devTracker.enable = true;/' \
      -e 's|# dotfiles.ccPages.port = 7778;|dotfiles.ccPages.port = 7778;|' >"${r}/local/flake.nix"
  printf '{ "nodes": {} }\n' >"${r}/local/flake.lock"
}

id_of() { HOME="${work}/githome" "${BASH}" "$1/nix/scripts/local-flake-migrate.sh" id; }

# 6. check: 印が今と同じ・前の版・無い・ローカル flake でない
r=$(history_repo r6)
id_v3=$(id_of "${r}")
user_flake "${r}" v3
run "${r}" check --flake "${r}/local"
if [[ $(rc "${r}") == 0 && -z $(out "${r}") ]]; then
  ok "check: 印が今の雛形と同じなら 0 で何も出さない (中身を利用者が書き換えていても)"
else
  ng "check (同じ版)" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
user_flake "${r}" v2
id_v2=$(sed -n 's/^# 雛形の版: \([0-9a-f]*\).*/\1/p' "${r}/local/flake.nix")
run "${r}" check --flake "${r}/local"
if [[ $(rc "${r}") == 1 && $(out "${r}") == "${id_v2} → ${id_v3}" ]]; then
  ok "check: 印が前の版なら 1 で「旧い印 → 今の印」の 1 行"
else
  ng "check (前の版)" "rc=$(rc "${r}") out=$(out "${r}") want=${id_v2} → ${id_v3}"
fi
user_flake "${r}" v1
run "${r}" check --flake "${r}/local"
if [[ $(rc "${r}") == 1 && $(out "${r}") == "印なし → ${id_v3}" ]]; then
  ok "check: 印が無ければ 1 で「印なし → 今の印」"
else
  ng "check (印なし)" "rc=$(rc "${r}") out=$(out "${r}")"
fi
# git も nix も無い PATH でも動く (setup が Nix を入れた直後にも呼ぶ)
min_bin="${work}/min-bin"
mkdir -p "${min_bin}"
for c in awk cksum dirname readlink mktemp rm cat; do
  ln -sf "$(command -v "${c}")" "${min_bin}/${c}"
done
user_flake "${r}" v2
env -i HOME="${work}/githome" PATH="${min_bin}" "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" check --flake "${r}/local" >"${r}/out" 2>"${r}/err"
echo $? >"${r}/rc"
if [[ $(rc "${r}") == 1 && $(out "${r}") == "${id_v2} → ${id_v3}" ]]; then
  ok "check は git も nix も無い PATH で動く"
else
  ng "check (道具の少ない PATH)" "rc=$(rc "${r}") out=$(out "${r}") err=$(err "${r}")"
fi
printf '{ outputs = _: { }; }\n' >"${r}/local/flake.nix"
run "${r}" check --flake "${r}/local"
rc_nourl=$(rc "${r}")
run "${r}" check --flake "${r}/無い"
if [[ ${rc_nourl} == 2 && $(rc "${r}") == 2 ]]; then
  ok "check: inputs.dotfiles.url の path: が無い・flake.nix が無いなら 2"
else
  ng "check (ローカル flake でない)" "url なし rc=${rc_nourl} 無い rc=$(rc "${r}")"
fi

# 7. status: 同じ版・印の版・印なし (最も近い版)
user_flake "${r}" v3
run "${r}" status --flake "${r}/local"
if [[ $(rc "${r}") == 0 ]] && grep -q '同じ版' "${r}/out"; then
  ok "status: 印が今と同じなら 0 で「同じ版」"
else
  ng "status (同じ版)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi
user_flake "${r}" v2
run "${r}" status --flake "${r}/local"
if [[ $(rc "${r}") == 1 ]] && grep -qF "印の版: $(cat "${r}/rev-v2")" "${r}/out"; then
  ok "status: 印が前の版なら 1 で、その版の commit を出す"
else
  ng "status (前の版)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi
user_flake "${r}" v1
run "${r}" status --flake "${r}/local"
if [[ $(rc "${r}") == 1 ]] && grep -q '印がありません' "${r}/out" \
  && grep -qF "最も近い版: $(cat "${r}/rev-v1")" "${r}/out"; then
  ok "status: 印が無ければ 1 で、履歴で最も近い版を出す"
else
  ng "status (印なし)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# prepare の作業場所の prepare.env から値を読む。$1: 作業場所、$2: 名前
env_of() { sed -n "s/^$2=//p" "$1/prepare.env"; }

# 8. prepare: 印の無い v1 から。元は差分の最小の v1、port の直後に節が足された衝突は自動で解く
r=$(history_repo r8)
user_flake "${r}" v1
cp -p "${r}/local/flake.nix" "${r}/before.nix"
run "${r}" prepare --flake "${r}/local" --out "${r}/w"
w="${r}/w"
new_ok=1
for want in '# 雛形の版: '"$(id_of "${r}")" \
  '# Notion Dev Tracker (pjp-dev-tracker) を使うか。' \
  'dotfiles.claude.devTracker.enable = true;' \
  '# dotfiles.claude.videoOffer.autoStart.enable = true;' \
  '#   onePassword.enable = true;'; do
  grep -qF -- "${want}" "${w}/new/flake.nix" || new_ok=0
done
if [[ $(rc "${r}") == 0 && ${new_ok} == 1 ]] && ! grep -q '^<<<<<<<' "${w}/new/flake.nix"; then
  ok "prepare: 利用者の値を残し、今の雛形の印・説明・節・例を取り込む"
else
  ng "prepare (v1 から)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}") new=$(cat "${w}/new/flake.nix" 2>/dev/null)"
fi
if [[ $(grep -A2 -F 'dotfiles.ccPages.port = 7778;' "${w}/new/flake.nix" | sed -n '3p') == '        # 解説動画を作り始めるか。' ]] \
  && ! grep -qF '# dotfiles.ccPages.port = 7778;' "${w}/new/flake.nix"; then
  ok "prepare: コメントを外した行の直後に雛形が節を足した衝突は、外した行 + 節に解く"
else
  ng "prepare (隣接の衝突)" "$(cat "${w}/new/flake.nix" 2>/dev/null)"
fi
if [[ $(env_of "${w}" base_how) == nearest && $(env_of "${w}" base_rev) == "$(cat "${r}/rev-v1")" ]] \
  && [[ $(env_of "${w}" resolved) == 1 && $(env_of "${w}" remaining) == 0 ]]; then
  ok "prepare: 印が無ければ、差分の最小の版を元にする (prepare.env に決め方と衝突の数)"
else
  ng "prepare.env (v1 から)" "$(cat "${w}/prepare.env" 2>/dev/null)"
fi
if cmp -s "${r}/before.nix" "${w}/old/flake.nix" && cmp -s "${r}/before.nix" "${r}/local/flake.nix" \
  && [[ -f ${w}/old/flake.lock && -f ${w}/base.nix && -f ${w}/template.nix ]] \
  && [[ $(sed 1d "${w}/candidates.tsv" | wc -l) -eq 3 ]]; then
  ok "prepare: 旧いファイルの写しは元と同じで、元のファイルには触らない (base・template・候補 3 版)"
else
  ng "prepare の作業場所" "$(ls -R "${w}" 2>/dev/null)"
fi
if grep -q '自動で解いた 1 件' "${r}/out" && grep -q 'compare' "${r}/out"; then
  ok "prepare: 衝突の数と、次に打つもの (compare) を出す"
else
  ng "prepare の出力" "$(out "${r}")"
fi

# 9. prepare: 印のある v2 から。元は印の版 (v2)
user_flake "${r}" v2
run "${r}" prepare --flake "${r}/local" --out "${r}/w9"
if [[ $(rc "${r}") == 0 && $(env_of "${r}/w9" base_how) == marker && $(env_of "${r}/w9" base_rev) == "$(cat "${r}/rev-v2")" ]]; then
  ok "prepare: 印があれば、その版を元にする"
else
  ng "prepare (v2 から)" "rc=$(rc "${r}") $(cat "${r}/w9/prepare.env" 2>/dev/null) $(err "${r}")"
fi

# 10. prepare: 印が履歴に無い値・印の行を消した → 差分の最小に落ちる (落ちない)
sed -i 's/^# 雛形の版: [0-9a-f]*/# 雛形の版: 0badf00d/' "${r}/local/flake.nix"
run "${r}" prepare --flake "${r}/local" --out "${r}/w10"
if [[ $(rc "${r}") == 0 && $(env_of "${r}/w10" base_how) == nearest ]] && grep -q '0badf00d' "${r}/out"; then
  ok "prepare: 印の版が履歴に無ければ、そう出して差分の最小の版を元にする"
else
  ng "prepare (履歴に無い印)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi
user_flake "${r}" v2
sed -i '/^# 雛形の版: /d' "${r}/local/flake.nix"
run "${r}" prepare --flake "${r}/local" --out "${r}/w10b"
if [[ $(rc "${r}") == 0 && $(env_of "${r}/w10b" base_how) == nearest && $(env_of "${r}/w10b" base_rev) == "$(cat "${r}/rev-v2")" ]]; then
  ok "prepare: 印の行を消したファイルも、差分の最小で元を決める"
else
  ng "prepare (印の行なし)" "rc=$(rc "${r}") $(cat "${r}/w10b/prepare.env" 2>/dev/null) $(err "${r}")"
fi

# 11. prepare: 元と今が同じ版なら「移すものは無い」。作業場所を作らない
user_flake "${r}" v3
run "${r}" prepare --flake "${r}/local" --out "${r}/w11"
if [[ $(rc "${r}") == 0 && ! -e ${r}/w11 ]] && grep -q '移すものはありません' "${r}/out"; then
  ok "prepare: 今の雛形と同じ版なら、移すものは無いと出して作業場所を作らない"
else
  ng "prepare (同じ版)" "rc=$(rc "${r}") $(out "${r}") $(ls -d "${r}/w11" 2>/dev/null)"
fi

# 12. prepare: url が script の repo と別のパス → そのパスで描き、そう出す。lock が無くても進む
user_flake "${r}" v1 /elsewhere/nix
rm -f "${r}/local/flake.lock"
run "${r}" prepare --flake "${r}/local" --out "${r}/w12"
if [[ $(rc "${r}") == 0 ]] && grep -qF 'path:/elsewhere/nix' "${r}/w12/new/flake.nix" \
  && grep -q '別の checkout' "${r}/out" && [[ ! -e ${r}/w12/old/flake.lock ]]; then
  ok "prepare: url が別の checkout を指せばそのパスで描いてそう出し、lock が無くても進む"
else
  ng "prepare (別のパス)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 13. prepare: --out が空でない → 2
mkdir -p "${r}/w13"
touch "${r}/w13/何か"
user_flake "${r}" v1
run "${r}" prepare --flake "${r}/local" --out "${r}/w13"
if [[ $(rc "${r}") == 2 ]] && grep -q '空でない' "${r}/err"; then
  ok "prepare: --out が空でないディレクトリなら 2"
else
  ng "prepare (空でない --out)" "rc=$(rc "${r}") $(err "${r}")"
fi

# 14. 衝突を自動で解く形と残す形 (小さな雛形の 2 版で 1 つずつ)。元の版 (commit) と今の版 (作業ツリー)、
#     手元 (元の版を描いて直したもの) を渡し、new/flake.nix の本文 (印と url の行を除く) を比べる
#     $1: 名前、$2: 元の本文、$3: 今の本文、$4: 手元の本文、$5: 期待する本文 (残すなら "残す")
merge_case() {
  local r w head='# 雛形の版: ${template_id}
inputs.dotfiles.url = "path:${nix_dir}";'
  r=$(new_repo "m-$1")
  fake_slf "${r}/nix/scripts/setup-local-flake.sh" "${head}
$2"
  tgit -C "${r}" add -A
  tgit -C "${r}" commit -qm base
  mkdir -p "${r}/local"
  {
    HOME="${work}/githome" "${BASH}" "${r}/nix/scripts/local-flake-migrate.sh" render --rev HEAD --nix-dir /N | sed -n '1,2p'
    printf '%s\n' "$4"
  } >"${r}/local/flake.nix"
  fake_slf "${r}/nix/scripts/setup-local-flake.sh" "${head}
$3"
  run "${r}" prepare --flake "${r}/local" --out "${r}/w"
  w="${r}/w"
  if [[ $5 == 残す ]]; then
    if [[ $(rc "${r}") == 0 && $(env_of "${w}" remaining) == 1 && $(env_of "${w}" resolved) == 0 ]] \
      && grep -q '^<<<<<<< 手元' "${w}/new/flake.nix" && grep -q '^>>>>>>> 今の雛形' "${w}/new/flake.nix" \
      && grep -qF "new/flake.nix の $(grep -n '^<<<<<<<' "${w}/new/flake.nix" | cut -d: -f1) 行目" "${r}/out"; then
      ok "衝突を残す: $1 (印のまま。prepare は行番号を出す)"
    else
      ng "衝突を残す: $1" "rc=$(rc "${r}") $(out "${r}") new=$(cat "${w}/new/flake.nix" 2>/dev/null)"
    fi
  else
    if [[ $(rc "${r}") == 0 && $(env_of "${w}" resolved) == 1 && $(env_of "${w}" remaining) == 0 ]] \
      && [[ $(sed '1,2d' "${w}/new/flake.nix") == "$5" ]]; then
      ok "衝突を自動で解く: $1"
    else
      ng "衝突を自動で解く: $1" "rc=$(rc "${r}") $(cat "${w}/prepare.env" 2>/dev/null) new=$(cat "${w}/new/flake.nix" 2>/dev/null)"
    fi
  fi
}
merge_case 今が後ろに足した $'a\nb\nc' $'a\nb\nX\nc' $'a\nB\nc' $'a\nB\nX\nc'
merge_case 今が前に足した $'a\nb\nc' $'a\nX\nb\nc' $'a\nB\nc' $'a\nX\nB\nc'
merge_case 手元が消した $'a\nb\nc' $'a\nb\nX\nc' $'a\nc' $'a\nX\nc'
merge_case 手元が足し今が直した $'a\nb\nc' $'a\nb2\nc' $'a\nb\nY\nc' $'a\nb2\nY\nc'
merge_case 両側が同じ所に足した $'a\nb\nc' $'a\nb\nX\nc' $'a\nb\nY\nc' 残す
merge_case 両側が同じ行を直した $'a\nb\nc' $'a\nb2\nc' $'a\nB\nc' 残す

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
