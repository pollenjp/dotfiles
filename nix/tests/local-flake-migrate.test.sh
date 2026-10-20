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
#     別の checkout を指せば、そのパスで描いてそう出す。flake.lock が無くても進む。--out が空でなければ 2。
#     --base で元の雛形を選び直せ (base_how=given)、描けない rev なら作業場所を作らずに 2
#   - compare (偽の nix) は、基準 (old/ か --baseline) と new/ を評価用の写しで評価し (old/ は触らない)、全ホストの
#     drvPath が同じなら 0 と「同じ」、値が違えば 1 と違うホスト・config.dotfiles の違い (同じ違いのホストはまとめる)、
#     ホストの集合が違えば 1 と片側だけのホスト、setup が拾うホストの並び (一番上が既定) が違えば drvPath が同じでも 1。
#     基準が評価できなければ 3、移した flake が評価できなければ 4 (どちらも前の compare.result を消す)、衝突の印が
#     残っていれば nix を呼ばずに 2。警告は「移して消えた」と「移した flake にある」で出す。lock は本体の hash が
#     無いときだけ nix flake update dotfiles で、lock が無ければ nix flake lock で、写しに作る。compare.result に
#     new/flake.nix の cksum・基準・結果を書く
#   - apply は、prepare のあとに flake.nix が書き換わった・衝突の印が残る・compare をしていない・compare のあとに
#     new/flake.nix を直した、なら 2 で止まって何も変えない。compare が違う・--baseline で比べたなら --accept-changes
#     が要る。書けたときは flake.nix.bak-<日時>・flake.lock.bak-<同じ日時> (元と同じ中身) を置いてから
#     new/flake.nix を書き、flake.lock は変えず、戻すコマンド (cp -p) を出す。flake.lock が無ければ lock の分を飛ばす

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
# key=value の行のファイル ($1) から値 ($2) を読む
env_get_test() { sed -n "s/^$2=//p" "$1" 2>/dev/null; }

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

# 12b. prepare --base: 元の版を選び直せる (base_how=given)。履歴に無い rev なら 2
user_flake "${r}" v1
run "${r}" prepare --flake "${r}/local" --out "${r}/w12b" --base "$(cat "${r}/rev-v2")"
if [[ $(rc "${r}") == 0 && $(env_of "${r}/w12b" base_how) == given && $(env_of "${r}/w12b" base_rev) == "$(cat "${r}/rev-v2")" ]] \
  && grep -q '選んだ版' "${r}/out"; then
  ok "prepare --base: 元の雛形を選び直せる"
else
  ng "prepare --base" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi
run "${r}" prepare --flake "${r}/local" --out "${r}/w12c" --base 0000000
if [[ $(rc "${r}") == 2 && ! -e ${r}/w12c ]]; then
  ok "prepare --base: 描けない rev なら 2 で、作業場所を作らない"
else
  ng "prepare --base (無い rev)" "rc=$(rc "${r}") $(err "${r}")"
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

# ---- compare (偽の nix) ----
# 偽の nix は呼ばれた引数を FAKE_NIX_LOG に書く。
#   nix hash path …                      sha256-FAKE を出す
#   nix flake lock path:<dir>            <dir>/flake.lock に sha256-FAKE を書く
#   nix flake update dotfiles --flake path:<dir>   同じ
#   nix eval --raw path:<dir>#homeConfigurations --apply <式>
#     <dir>/flake.nix の「# FAKE_EVAL_ERROR: <文>」があれば stderr に error: <文> を出して 1。
#     ホストは「# FAKE_HOSTS: a b」(既定 h1 h2)。式に config.dotfiles があれば、コメントでない
#     「dotfiles.<パス> = <値>;」の行を「パス<TAB>値」で返す。無ければ、コメントでも空でもない行を並べ替えた cksum を
#     drvPath にした「drv<TAB><host><TAB><drvPath>」と、「# FAKE_WARN: <文>」ごとの「warn<TAB><host><TAB><文>」を返す
fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_NIX_LOG:-/dev/null}"
last=""
for a in "$@"; do last=$a; done
case $1 in
  hash)
    echo sha256-FAKE
    ;;
  flake)
    d=${last#path:}
    printf '{ "fake": "sha256-FAKE" }\n' >"${d}/flake.lock"
    ;;
  eval)
    d=${3#path:}
    d=${d%%#*}
    f="${d}/flake.nix"
    e=$(sed -n 's/^# FAKE_EVAL_ERROR: //p' "${f}")
    if [[ -n ${e} ]]; then
      printf 'error: %s\n' "${e}" >&2
      exit 1
    fi
    hosts=$(sed -n 's/^# FAKE_HOSTS: //p' "${f}")
    case $5 in
      *config.dotfiles*)
        sed -n 's/^[[:space:]]*dotfiles\.\([A-Za-z0-9_.]*\)[[:space:]]*=[[:space:]]*\(.*\);[[:space:]]*$/\1\t\2/p' "${f}"
        ;;
      *)
        sum=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${f}" | sort | cksum)
        for h in ${hosts:-h1 h2}; do
          printf 'drv\t%s\t/nix/store/%s-%s.drv\n' "${h}" "${sum%% *}" "${h}"
        done
        while IFS= read -r w; do
          for h in ${hosts:-h1 h2}; do
            printf 'warn\t%s\t%s\n' "${h}" "${w}"
          done
        done < <(sed -n 's/^# FAKE_WARN: //p' "${f}")
        ;;
    esac
    ;;
esac
exit 0
EOF
} >"${fake_bin}/nix"
chmod +x "${fake_bin}/nix"

# $1: repo、残り: script の引数。偽の nix を PATH の先に置いて流す (呼び出しは <repo>/nix-calls)
run_nix() {
  local r=$1
  shift
  : >"${r}/nix-calls"
  PATH="${fake_bin}:${PATH}" FAKE_NIX_LOG="${r}/nix-calls" run "${r}" "$@"
}

# v1 から作った flake.nix を prepare した作業場所 (<repo>/w) を作る。$2 を渡せば、その行を利用者の flake.nix の
# 末尾に足してから prepare する
compare_case() {
  local r
  r=$(history_repo "$1")
  user_flake "${r}" v1
  [[ -z ${2:-} ]] || printf '%s\n' "$2" >>"${r}/local/flake.nix"
  run "${r}" prepare --flake "${r}/local" --out "${r}/w"
  echo "${r}"
}

# 15. コメントだけ違う → 0「同じ」。compare.result に今の new/flake.nix の cksum と result=same。old/ は触らない
r=$(compare_case c15)
cp -p "${r}/w/old/flake.nix" "${r}/old-before.nix"
cp -p "${r}/w/old/flake.lock" "${r}/old-lock-before"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 0 ]] && grep -q '全 2 ホストで同じ' "${r}/out" \
  && [[ $(env_get_test "${r}/w/compare.result" result) == same ]] \
  && [[ $(env_get_test "${r}/w/compare.result" new_sum) == "$(cksum <"${r}/w/new/flake.nix")" ]] \
  && [[ $(env_get_test "${r}/w/compare.result" baseline_is_old) == 1 ]]; then
  ok "compare: コメントだけ違えば 0 で「同じ」、compare.result に今の中身の cksum と result=same"
else
  ng "compare (同じ)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}") $(cat "${r}/w/compare.result" 2>/dev/null)"
fi
if cmp -s "${r}/old-before.nix" "${r}/w/old/flake.nix" && cmp -s "${r}/old-lock-before" "${r}/w/old/flake.lock"; then
  ok "compare: old/ の flake.nix と flake.lock は触らない (評価は写しで行う)"
else
  ng "compare が old/ を書き換えた"
fi
if grep -q '^flake update dotfiles --flake path:' "${r}/nix-calls"; then
  ok "compare: 写しの lock に本体の hash が無ければ、nix flake update dotfiles で張り直す"
else
  ng "compare (lock の張り直し)" "$(cat "${r}/nix-calls")"
fi
# 張り直した lock (sha256-FAKE を含む) を基準に渡すと、もう張り直さない
mkdir -p "${r}/synced"
cp -p "${r}/w/old/flake.nix" "${r}/synced/flake.nix"
printf '{ "fake": "sha256-FAKE" }\n' >"${r}/synced/flake.lock"
run_nix "${r}" compare "${r}/w" --baseline "${r}/synced"
if [[ $(rc "${r}") == 0 ]] && ! grep -q '^flake' "${r}/nix-calls" \
  && [[ $(env_get_test "${r}/w/compare.result" baseline_is_old) == 0 ]]; then
  ok "compare --baseline: 基準のディレクトリと比べ (baseline_is_old=0)、lock が本体と合えば張り直さない"
else
  ng "compare (--baseline・合っている lock)" "rc=$(rc "${r}") $(cat "${r}/nix-calls") $(cat "${r}/w/compare.result" 2>/dev/null)"
fi

# 16. 値が違う → 1、そのホストと config.dotfiles の違い
sed -i 's/dotfiles.ccPages.port = 7778;/dotfiles.ccPages.port = 7779;/' "${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 1 ]] && grep -qE '^ +h1 +違う' "${r}/out" && grep -qF 'ccPages.port: 7778 → 7779' "${r}/out" \
  && grep -qF '(基準 → 移した。h1, h2)' "${r}/out" && [[ $(grep -c 'ccPages.port: 7778 → 7779' "${r}/out") == 1 ]] \
  && [[ $(env_get_test "${r}/w/compare.result" result) == differ ]]; then
  ok "compare: 値が違えば 1 で、違うホストと config.dotfiles の違い (旧 → 新) を出す (同じ違いのホストはまとめる)"
else
  ng "compare (値の違い)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 17. ホストの集合が違う → 1
r=$(compare_case c17)
printf '# FAKE_HOSTS: h1 h2 h3\n' >>"${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 1 ]] && grep -qE '^ +h3 +移した flake だけ' "${r}/out"; then
  ok "compare: ホストの集合が違えば 1 で、片側にしかないホストを出す"
else
  ng "compare (ホストの集合)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 18. setup が拾うホストの並びが違う (drvPath は同じ) → 1
r=$(compare_case c18 '      a = dotfiles.lib.mkHome { };
      "b@x" = dotfiles.lib.mkHome { };')
sed -i -e 's/^      a = dotfiles.lib.mkHome { };$/      "b@x" = dotfiles.lib.mkHome { };/;t' \
  -e 's/^      "b@x" = dotfiles.lib.mkHome { };$/      a = dotfiles.lib.mkHome { };/' "${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 1 ]] && grep -qF '基準 [a b@x] → 移した [b@x a]' "${r}/out" && grep -q '全 2 ホストで同じ' "${r}/out"; then
  ok "compare: drvPath が同じでも、setup が拾うホストの並び (一番上が既定) が違えば 1"
else
  ng "compare (ホストの並び)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 19. 基準が評価できない → 3 / 移した flake が評価できない → 4。落ちた compare は前の結果を残さない
r=$(compare_case c19 '# FAKE_EVAL_ERROR: The option `dotfiles.gone'"'"' does not exist.')
sed -i '/^# FAKE_EVAL_ERROR: /d' "${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 3 ]] && grep -q '旧い flake (基準) は今の本体' "${r}/err" \
  && grep -qF 'error: The option `dotfiles.gone'"'"' does not exist.' "${r}/err" && [[ ! -e ${r}/w/compare.result ]]; then
  ok "compare: 基準が今の本体で評価できなければ 3 で、そう出してエラーの行を添える"
else
  ng "compare (基準が評価できない)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi
mkdir -p "${r}/fixed"
grep -v '^# FAKE_EVAL_ERROR: ' "${r}/w/old/flake.nix" >"${r}/fixed/flake.nix"
run_nix "${r}" compare "${r}/w" --baseline "${r}/fixed"
rc_fixed=$(rc "${r}")
printf '# FAKE_EVAL_ERROR: 移した flake の誤り\n' >>"${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w" --baseline "${r}/fixed"
if [[ ${rc_fixed} == 0 && $(rc "${r}") == 4 ]] && grep -q '移した flake は評価できません' "${r}/err" && [[ ! -e ${r}/w/compare.result ]]; then
  ok "compare: 直した基準なら比べられ、移した flake が評価できなければ 4 (前の compare.result は消す)"
else
  ng "compare (移した flake が評価できない)" "fixed rc=${rc_fixed} rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 20. 衝突の印が残っている → 2 で止まり、nix を呼ばない
r=$(compare_case c20)
printf '<<<<<<< 手元\nx\n||||||| 元の雛形\ny\n=======\nz\n>>>>>>> 今の雛形\n' >>"${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 2 ]] && grep -q '衝突の印' "${r}/err" && [[ ! -s ${r}/nix-calls ]]; then
  ok "compare: new/flake.nix に衝突の印が残っていれば 2 で止まり、nix を呼ばない"
else
  ng "compare (衝突の印)" "rc=$(rc "${r}") $(err "${r}") calls=$(cat "${r}/nix-calls")"
fi

# 21. 警告: 基準だけにある警告は「移して消えた」、移した側の警告は「移した flake にある」
r=$(compare_case c21 '# FAKE_WARN: 旧名 a は b へ改名しました')
sed -i 's/^# FAKE_WARN: 旧名 a は b へ改名しました$/# FAKE_WARN: 新しい警告/' "${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 0 ]] && grep -qF '移して消えた: 旧名 a は b へ改名しました (2 ホスト)' "${r}/out" \
  && grep -qF '移した flake にある: 新しい警告 (2 ホスト)' "${r}/out"; then
  ok "compare: 基準だけの警告は「移して消えた」、移した flake の警告は「移した flake にある」で出す"
else
  ng "compare (警告)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}")"
fi

# 22. lock が無い → nix flake lock で作る
r=$(compare_case c22)
rm -f "${r}/w/old/flake.lock"
run_nix "${r}" compare "${r}/w"
if [[ $(rc "${r}") == 0 ]] && grep -q '^flake lock path:' "${r}/nix-calls"; then
  ok "compare: lock が無ければ nix flake lock で写しに作る"
else
  ng "compare (lock が無い)" "rc=$(rc "${r}") $(cat "${r}/nix-calls") $(err "${r}")"
fi

# ---- apply ----
# ローカル flake のディレクトリの中身 (退避を含む) を、名前と cksum で並べる
dir_state() { (cd "$1" && for f in *; do printf '%s %s\n' "${f}" "$(cksum <"${f}")"; done); }

# 23. prepare のあとに flake.nix を書き換えた → 止まり、何も変えない
r=$(compare_case c23)
run_nix "${r}" compare "${r}/w"
printf '# 利用者があとから足した行\n' >>"${r}/local/flake.nix"
before=$(dir_state "${r}/local")
run "${r}" apply "${r}/w"
if [[ $(rc "${r}") == 2 ]] && grep -q 'prepare のあとに' "${r}/err" && [[ $(dir_state "${r}/local") == "${before}" ]]; then
  ok "apply: prepare のあとに flake.nix が書き換わっていれば止まり、何も変えない"
else
  ng "apply (書き換わった)" "rc=$(rc "${r}") $(err "${r}")"
fi

# 24. 衝突の印が残る・compare をしていない・compare のあとに直した → 止まる
r=$(compare_case c24)
before=$(dir_state "${r}/local")
run "${r}" apply "${r}/w"
rc_nocompare=$(rc "${r}")
grep -q 'compare' "${r}/err" && nocompare_msg=1 || nocompare_msg=0
run_nix "${r}" compare "${r}/w"
printf '# compare のあとに直した\n' >>"${r}/w/new/flake.nix"
run "${r}" apply "${r}/w"
rc_stale=$(rc "${r}")
grep -q 'compare のあとに' "${r}/err" && stale_msg=1 || stale_msg=0
printf '<<<<<<< 手元\nx\n||||||| 元の雛形\ny\n=======\nz\n>>>>>>> 今の雛形\n' >>"${r}/w/new/flake.nix"
run "${r}" apply "${r}/w"
if [[ ${rc_nocompare} == 2 && ${nocompare_msg} == 1 && ${rc_stale} == 2 && ${stale_msg} == 1 && $(rc "${r}") == 2 ]] \
  && grep -q '衝突の印' "${r}/err" && [[ $(dir_state "${r}/local") == "${before}" ]]; then
  ok "apply: compare をしていない・compare のあとに直した・衝突の印が残る、なら止まって何も変えない"
else
  ng "apply (止まる 3 つ)" "compare なし rc=${rc_nocompare} 直した rc=${rc_stale} 印 rc=$(rc "${r}") $(err "${r}")"
fi

# 25. compare が違う・--baseline で比べた → --accept-changes が無ければ止まり、あれば書く
r=$(compare_case c25)
sed -i 's/dotfiles.ccPages.port = 7778;/dotfiles.ccPages.port = 7779;/' "${r}/w/new/flake.nix"
run_nix "${r}" compare "${r}/w"
run "${r}" apply "${r}/w"
rc_differ=$(rc "${r}")
grep -q -- '--accept-changes' "${r}/err" && differ_msg=1 || differ_msg=0
run "${r}" apply "${r}/w" --accept-changes
if [[ ${rc_differ} == 2 && ${differ_msg} == 1 && $(rc "${r}") == 0 ]] && cmp -s "${r}/w/new/flake.nix" "${r}/local/flake.nix" \
  && grep -q 'setup --update' "${r}/out"; then
  ok "apply: compare が違えば --accept-changes が要り、付ければ書いて setup --update を案内する"
else
  ng "apply (違いを受け入れる)" "rc=${rc_differ} → $(rc "${r}") $(out "${r}") $(err "${r}")"
fi
r=$(compare_case c25b)
mkdir -p "${r}/fixed"
cp "${r}/w/old/flake.nix" "${r}/fixed/flake.nix"
run_nix "${r}" compare "${r}/w" --baseline "${r}/fixed"
run "${r}" apply "${r}/w"
if [[ $(rc "${r}") == 2 ]] && grep -q -- '--accept-changes' "${r}/err"; then
  ok "apply: --baseline で比べたなら、同じでも --accept-changes が要る"
else
  ng "apply (--baseline)" "rc=$(rc "${r}") $(err "${r}")"
fi

# 26. 書けたとき: 退避 2 つは元と同じ中身、flake.nix は new/flake.nix と同じ、flake.lock は変わらない、
#     戻すコマンド (cp -p) を 2 つ出す。flake.lock が無ければ lock の退避と戻しを飛ばす
r=$(compare_case c26)
cp -p "${r}/local/flake.nix" "${r}/nix-before"
cp -p "${r}/local/flake.lock" "${r}/lock-before"
run_nix "${r}" compare "${r}/w"
run "${r}" apply "${r}/w"
bak_nix=$(find "${r}/local" -maxdepth 1 -name 'flake.nix.bak-*' | head -n 1)
bak_lock=$(find "${r}/local" -maxdepth 1 -name 'flake.lock.bak-*' | head -n 1)
if [[ $(rc "${r}") == 0 && -n ${bak_nix} && -n ${bak_lock} ]] && cmp -s "${bak_nix}" "${r}/nix-before" \
  && cmp -s "${bak_lock}" "${r}/lock-before" && cmp -s "${r}/local/flake.nix" "${r}/w/new/flake.nix" \
  && cmp -s "${r}/local/flake.lock" "${r}/lock-before" && [[ ${bak_nix##*.bak-} == "${bak_lock##*.bak-}" ]] \
  && [[ ${bak_nix##*.bak-} =~ ^[0-9]{8}T[0-9]{6}$ ]] && [[ $(grep -c '^    cp -p ' "${r}/out") == 2 ]] \
  && grep -qF "cp -p ${bak_nix} ${r}/local/flake.nix" "${r}/out" && grep -q 'switch は要りません' "${r}/out"; then
  ok "apply: 退避 (flake.nix.bak-<日時>・flake.lock.bak-<日時>) を取ってから書き、戻すコマンドを出す"
else
  ng "apply (書けたとき)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}") $(ls "${r}/local")"
fi
r=$(compare_case c26b)
rm -f "${r}/local/flake.lock" "${r}/w/old/flake.lock"
run_nix "${r}" compare "${r}/w"
run "${r}" apply "${r}/w"
if [[ $(rc "${r}") == 0 && -z $(find "${r}/local" -maxdepth 1 -name 'flake.lock*') ]] \
  && [[ $(grep -c '^    cp -p ' "${r}/out") == 1 ]]; then
  ok "apply: flake.lock が無ければ、lock の退避と戻すコマンドを飛ばす"
else
  ng "apply (lock が無い)" "rc=$(rc "${r}") $(out "${r}") $(err "${r}") $(ls "${r}/local")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
