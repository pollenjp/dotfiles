#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/flake-lock-age.sh が、設定 (release-age.nix) の猶予の日数と例外で pin を選び (resolve・update)、検査する
# (check) ことを、偽の curl (チャンネルの公開と GitHub の commit の表から答える) と nix の包み (eval は本物の nix に
# --store dummy:// を付けて渡し、flake update は引数を残す) で確かめる。
#
#   bash nix/tests/flake-lock-age.test.sh [<flake-lock-age.sh のパス>]
#
# flake の checks (flake-lock-age-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・nix (flake.lock・
# flake.nix・設定を読む nix eval) だけ。
#
# ## 確かめること
#
#   - 猶予の日数: 設定の minimumReleaseAgeDays (10) で選ぶ。FLAKE_MIN_RELEASE_AGE_DAYS が設定に、--min-age-days が
#     環境変数に勝つ。設定が無ければ 7 (見出しの行に「既定。設定なし」)。--config も flake の隣の設定も無ければ、
#     script の隣の ../release-age.nix を読む (見出しの行に「(script の隣)」)
#   - 設定の置き場所: --config が無ければ、対象の flake の隣の release-age.nix を読む (見出しの行に「(flake の隣)」)。
#     flake の隣が script の隣に、--config が flake の隣に勝つ。複数の flake は、それぞれの隣の設定で選ぶ
#   - ほかの repo (script の隣に設定が無い): flake の隣の全体の例外で、猶予を満たさない nixpkgs の pin を check が通し、
#     update もその日の終わりまでの公開を選ぶ (直しの前の版へ戻さない。ほかの github input は猶予のまま)
#   - 一部の例外: input nixpkgs-exceptions の無い flake の隣の設定に fromNixpkgs・fromUpstream があれば止まる
#     (nix flake update を打たない)。input のある flake の隣の設定と、script の隣の設定を借りる flake では止まらない
#   - 全体の例外: date の日 (Asia/Tokyo) の終わりが猶予より新しければ、その日の終わりまでの最新の公開を nixpkgs に選ぶ
#     (14:59:59 UTC の公開は入り、15:00:00 UTC は入らない)。猶予より古い date は何もしない (その旨の行)。ほかの
#     github input (home-manager) は猶予のまま
#   - 時差つきの timestamp の date: その時刻までの最新の公開を選ぶ (+09:00・Z・-05:00 のどれで書いても同じ時刻。
#     1 秒の境目も)。一部の例外 (nixpkgs-exceptions) も同じ。効いている行に、その時刻を JST と UTC で出す。check は
#     その時刻までの pin を通し、1 秒でも新しければ NG
#   - 時刻の出し方: resolve の「公開」と github の input の「commit」、check の「commit」(lock の commit の時刻) に、
#     「YYYY-MM-DD HH:MM:SS JST (HH:MM:SS UTC)」を出す。UTC の日付が JST と違えば UTC も日付から出す
#   - nixpkgs-exceptions: 一部の例外が無ければ nixpkgs と同じ rev。date の日の終わりまでの公開が nixpkgs より新しければ
#     それ、そうでなければ nixpkgs と同じ rev
#   - --input nixpkgs-exceptions だけなら、nix flake update に渡す名前と override はそれだけ。比べる相手は lock の
#     nixpkgs (公開の名前の末尾 12 桁で見つける)。lock にも flake.nix にも無い名前を --input に渡すと止まる
#   - lock に無い input (flake.nix にだけある nixpkgs-exceptions) も、先端ではなく決まりどおりに選ぶ。--input に
#     無くても一緒に選ぶ (nix flake update は lock に無い input を先端で足すため)
#   - check: 猶予を満たさない nixpkgs は NG (終了コード 1)。全体の例外の date の日の終わりまでの nixpkgs は OK とわけを
#     出す。nixpkgs-exceptions は nixpkgs と同じ rev なら OK、一部の例外の date の日の終わりまでなら OK、どちらでもなく
#     新しければ NG。何もしなくなった全体の例外には「何もしない (… 消してよい)」の行を出す
#   - 設定の date が YYYY-MM-DD でも時差つきの timestamp でもなければ止まる。今日 (Asia/Tokyo) より先の date も止まる
#     (打ち間違いで猶予が外れたままになるため。check も update も)。暦に無い date も止まる。時差の無い timestamp・
#     時刻や時差の誤り・今より先の timestamp も止まる (今ちょうどは通る)
#   - 設定の書き誤り: 知らない欄 (どの深さでも)・欄の型 (日数が整数でない・list でない・項目が attrset でない)・無い欄・
#     空の reason を、まとめて出して止まる。後ろの flake の設定に誤りがあれば、前の flake も更新しない
#
# 偽の curl は、公開の表 (releases.tsv) と commit の表 (commits.tsv) を 1 行ずつ「名前<TAB>UNIX 秒<TAB>rev」で読む。
# 今の時刻は FLAKE_LOCK_AGE_NOW (UNIX 秒) で渡す。偽のコマンドの shebang は $BASH から作る (Nix のサンドボックスには
# /usr/bin/env が無い)。

set -u -o pipefail
# 日数の環境変数は、ケースごとに渡すものだけを効かせる
unset FLAKE_MIN_RELEASE_AGE_DAYS DOTFILES_MIN_RELEASE_AGE_DAYS

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/flake-lock-age.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/flake-lock-age-test.XXXXXX")
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

if ! real_nix=$(command -v nix); then
  echo "nix が見つからない" >&2
  exit 1
fi
export HOME="${work}/home"
mkdir -p "${HOME}"

# ISO 8601 (UTC) → UNIX 秒
at() { date -u -d "$1" +%s; }
now=$(at 2026-10-24T03:00:00Z) # = 2026-10-24 12:00 JST

# 公開 k の rev と名前 (名前の末尾は rev の頭 12 桁)
rev() { printf 'c0ffee%06d%028d' "$1" 0; }
rel() { printf 'nixpkgs-26.11pre%07d.%s' "$((1000000 + $1))" "$(rev "$1" | cut -c1-12)"; }
hm() { printf 'beef%036d' "$1"; }

fixtures="${work}/fixtures"
mkdir -p "${fixtures}"
# 公開 (古い順)。7 日の猶予の上限は 2026-10-17T03:00Z
: >"${fixtures}/releases.tsv"
k=0
for t in 2026-10-10T12:00:00Z 2026-10-13T12:00:00Z 2026-10-16T12:00:00Z 2026-10-18T12:00:00Z \
  2026-10-20T00:00:00Z 2026-10-21T14:59:59Z 2026-10-21T15:00:00Z 2026-10-23T12:00:00Z; do
  k=$((k + 1))
  printf '%s\t%s\t%s\n' "$(rel "${k}")" "$(at "${t}")" "$(rev "${k}")" >>"${fixtures}/releases.tsv"
done
# home-manager の commit (古い順)
{
  printf 'nix-community/home-manager\t%s\t%s\n' "$(at 2026-10-12T00:00:00Z)" "$(hm 1)"
  printf 'nix-community/home-manager\t%s\t%s\n' "$(at 2026-10-16T00:00:00Z)" "$(hm 2)"
  printf 'nix-community/home-manager\t%s\t%s\n' "$(at 2026-10-22T00:00:00Z)" "$(hm 3)"
} >"${fixtures}/commits.tsv"

bin="${work}/bin"
mkdir -p "${bin}"
{
  printf '#!%s\n' "${BASH}"
  printf 'fixtures=%q\n' "${fixtures}"
  cat <<'EOF'
head_only=0
url=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -H) shift 2 ;;
    -*)
      if [[ $1 == *I* ]]; then head_only=1; fi
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
http_date() { LC_ALL=C date -u -d "@$1" '+%a, %d %b %Y %H:%M:%S GMT'; }
case ${url} in
  https://channels.nixos.org/nixpkgs-unstable)
    latest=$(tail -n 1 "${fixtures}/releases.tsv" | cut -f1)
    printf 'HTTP/2 302\r\nlocation: https://releases.nixos.org/nixpkgs/%s\r\n\r\n' "${latest}"
    ;;
  'https://nix-releases.s3.amazonaws.com/?'*)
    prefix=${url#*prefix=nixpkgs/}
    prefix=${prefix%%&*}
    printf '<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Prefix>nixpkgs/%s</Prefix>' "${prefix}"
    while IFS=$'\t' read -r r _ _; do
      if [[ ${r} == "${prefix}"* ]]; then printf '<CommonPrefixes><Prefix>nixpkgs/%s/</Prefix></CommonPrefixes>' "${r}"; fi
    done <"${fixtures}/releases.tsv"
    printf '<IsTruncated>false</IsTruncated></ListBucketResult>\n'
    ;;
  https://releases.nixos.org/nixpkgs/*/git-revision)
    want=${url#https://releases.nixos.org/nixpkgs/}
    want=${want%/git-revision}
    while IFS=$'\t' read -r r epoch sha; do
      if [[ ${r} == "${want}" ]]; then
        if [[ ${head_only} == 1 ]]; then
          printf 'HTTP/2 200\r\nlast-modified: %s\r\n\r\n' "$(http_date "${epoch}")"
        else
          printf '%s' "${sha}"
        fi
        exit 0
      fi
    done <"${fixtures}/releases.tsv"
    exit 22
    ;;
  'https://api.github.com/repos/'*'/commits?'*)
    repo=${url#https://api.github.com/repos/}
    repo=${repo%%/commits*}
    until=${url#*until=}
    until=$(date -u -d "${until%%&*}" +%s)
    found=""
    while IFS=$'\t' read -r r epoch sha; do
      if [[ ${r} == "${repo}" && ${epoch} -le ${until} ]]; then found="${sha} ${epoch}"; fi
    done <"${fixtures}/commits.tsv"
    if [[ -z ${found} ]]; then
      echo '[]'
      exit 0
    fi
    printf '[{"sha":"%s","commit":{"committer":{"date":"%s"}}}]\n' "${found% *}" \
      "$(date -u -d "@${found#* }" +%Y-%m-%dT%H:%M:%SZ)"
    ;;
  *)
    echo "偽の curl: 知らない URL: ${url}" >&2
    exit 22
    ;;
esac
EOF
} >"${bin}/curl"
{
  printf '#!%s\n' "${BASH}"
  printf 'real=%q\n' "${real_nix}"
  cat <<'EOF'
case $1 in
  eval) exec "${real}" --store dummy:// --extra-experimental-features 'nix-command flakes' "$@" ;;
  flake)
    if [[ $2 == update ]]; then
      printf '%s\n' "$*" >>"${FAKE_NIX_LOG:?}"
      exit 0
    fi
    ;;
esac
echo "偽の nix: 知らない呼び出し: $*" >&2
exit 1
EOF
} >"${bin}/nix"
chmod +x "${bin}/curl" "${bin}/nix"

# flake のディレクトリ。$1: 名前、$2: flake.lock の中身 (空なら作らない)。flake.nix は 3 つの input を持つ
new_flake() {
  local d="${work}/$1"
  mkdir -p "${d}"
  cat >"${d}/flake.nix" <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-exceptions.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = _: { };
}
EOF
  if [[ -n $2 ]]; then printf '%s\n' "$2" >"${d}/flake.lock"; fi
  echo "${d}"
}

# input nixpkgs-exceptions を持たない flake (ほかの repo・dotfiles の skill の flake の形)。$1: 名前、$2: flake.lock の中身
new_plain_flake() {
  local d="${work}/$1"
  mkdir -p "${d}"
  cat >"${d}/flake.nix" <<'EOF'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = _: { };
}
EOF
  printf '%s\n' "$2" >"${d}/flake.lock"
  echo "${d}"
}

# flake.lock の node。$1: owner、$2: repo、$3: rev、$4: lastModified、$5: ref (省けば無し)
node() {
  local original
  original=$(printf '"owner": "%s", "repo": "%s", "type": "github"' "$1" "$2")
  if [[ -n ${5:-} ]]; then original="${original}, \"ref\": \"$5\""; fi
  printf '{"locked": {"lastModified": %s, "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "owner": "%s", "repo": "%s", "rev": "%s", "type": "github"}, "original": {%s}}' \
    "$4" "$1" "$2" "$3" "${original}"
}
# $1: nixpkgs の node、$2: nixpkgs-exceptions の node (空なら lock に無い)
lock() {
  local hm_node exc="" exc_root=""
  hm_node=$(node nix-community home-manager "$(hm 2)" "$(at 2026-10-16T00:00:00Z)")
  hm_node="{\"inputs\": {\"nixpkgs\": [\"nixpkgs\"]}, ${hm_node#\{}"
  if [[ -n ${2:-} ]]; then
    exc=", \"nixpkgs-exceptions\": $2"
    exc_root=', "nixpkgs-exceptions": "nixpkgs-exceptions"'
  fi
  printf '{"nodes": {"home-manager": %s, "nixpkgs": %s%s, "root": {"inputs": {"home-manager": "home-manager", "nixpkgs": "nixpkgs"%s}}}, "root": "root", "version": 7}' \
    "${hm_node}" "$1" "${exc}" "${exc_root}"
}
nixpkgs_node() { node NixOS nixpkgs "$(rev "$1")" "$2" nixpkgs-unstable; }

# 設定のファイル。$1: パス、$2: 中身
settings() { printf '%s\n' "$2" >"$1"; }

# script を流す。$1: 結果を置くディレクトリ、残り: script の引数。FLAKE_MIN_RELEASE_AGE_DAYS は呼び側の env を渡す
run_in() {
  local r=$1
  shift
  mkdir -p "${r}"
  : >"${r}/nix.log"
  env HOME="${HOME}" PATH="${bin}:${PATH}" FAKE_NIX_LOG="${r}/nix.log" FLAKE_LOCK_AGE_NOW="${now}" \
    "${BASH}" "${run_script:-${script}}" "$@" >"${r}/stdout" 2>"${r}/stderr"
  echo $? >"${r}/rc"
}
detail() { printf 'rc=%s\n--- nix.log\n%s\n--- stdout\n%s\n--- stderr\n%s' "$(cat "$1/rc")" "$(cat "$1/nix.log")" "$(cat "$1/stdout")" "$(cat "$1/stderr")"; }
seen() { grep -Fq -- "$1" "$2"; }
# update が nixpkgs (と nixpkgs-exceptions) に選んだ rev を override に渡したか。$1: 結果、$2: input、$3: 公開の番号
picked() { seen "--override-input $2 github:NixOS/nixpkgs/$(rev "$3")" "$1/nix.log"; }
# picked の flake を分けて見る版 (複数の flake を渡したとき)。$1: 結果、$2: flake、$3: input、$4: 公開の番号
picked_in() {
  local line
  while IFS= read -r line; do
    if [[ ${line} == *"--flake $2 "* && ${line} == *"--override-input $3 github:NixOS/nixpkgs/$(rev "$4")"* ]]; then
      return 0
    fi
  done <"$1/nix.log"
  return 1
}

old_lock=$(lock "$(nixpkgs_node 4 "$(at 2026-10-17T00:00:00Z)")" "$(nixpkgs_node 4 "$(at 2026-10-17T00:00:00Z)")")
cfg="${work}/release-age.nix"

echo "== 猶予の日数"

settings "${cfg}" '{ minimumReleaseAgeDays = 10; }'
d=$(new_flake days "${old_lock}")
r="${work}/r-days-settings"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && seen '下限 10 日' "${r}/stdout" && picked "${r}" nixpkgs 2; then
  ok "設定の minimumReleaseAgeDays (10) で、10 日前までの公開 (2026-10-13) を選ぶ"
else
  ng "設定の minimumReleaseAgeDays (10) で、10 日前までの公開 (2026-10-13) を選ぶ" "$(detail "${r}")"
fi

r="${work}/r-days-env"
FLAKE_MIN_RELEASE_AGE_DAYS=5 run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if seen '下限 5 日' "${r}/stdout" && picked "${r}" nixpkgs 4; then
  ok "FLAKE_MIN_RELEASE_AGE_DAYS (5) が設定に勝つ"
else
  ng "FLAKE_MIN_RELEASE_AGE_DAYS (5) が設定に勝つ" "$(detail "${r}")"
fi

r="${work}/r-days-cli"
FLAKE_MIN_RELEASE_AGE_DAYS=5 run_in "${r}" --config "${cfg}" --min-age-days 3 --no-scan update "${d}"
if seen '下限 3 日' "${r}/stdout" && picked "${r}" nixpkgs 5; then
  ok "--min-age-days (3) が環境変数に勝つ"
else
  ng "--min-age-days (3) が環境変数に勝つ" "$(detail "${r}")"
fi

# 設定の無い置き場所 (script の隣に ../release-age.nix が無い。nix run で呼んだときの形) へ写して流す
mkdir -p "${work}/bare/scripts"
bare="${work}/bare/scripts/flake-lock-age.sh"
cp "${script}" "${bare}"
r="${work}/r-days-default"
run_script="${bare}" run_in "${r}" --no-scan update "${d}"
if seen '下限 7 日。既定。設定なし' "${r}/stdout" && picked "${r}" nixpkgs 3; then
  ok "設定が無ければ 7 日"
else
  ng "設定が無ければ 7 日" "$(detail "${r}")"
fi

mkdir -p "${work}/beside/nix/scripts"
cp "${script}" "${work}/beside/nix/scripts/flake-lock-age.sh"
settings "${work}/beside/nix/release-age.nix" '{ minimumReleaseAgeDays = 10; }'
beside_cfg="$(
  cd -- "${work}/beside/nix" || exit
  pwd -P
)/release-age.nix"
r="${work}/r-days-beside"
run_script="${work}/beside/nix/scripts/flake-lock-age.sh" run_in "${r}" --no-scan update "${d}"
if seen "下限 10 日。設定 ${beside_cfg} (script の隣)" "${r}/stdout" && picked "${r}" nixpkgs 2; then
  ok "--config も flake の隣の設定も無ければ、script の隣の ../release-age.nix を読む"
else
  ng "--config も flake の隣の設定も無ければ、script の隣の ../release-age.nix を読む" "$(detail "${r}")"
fi

echo "== 設定の置き場所"

# 隣に 5 日の設定を置いた flake。script の隣の設定 (beside) と --config (cfg) は 10 日
d_own=$(new_flake own "${old_lock}")
settings "${d_own}/release-age.nix" '{ minimumReleaseAgeDays = 5; }'
settings "${cfg}" '{ minimumReleaseAgeDays = 10; }'

r="${work}/r-own"
run_script="${bare}" run_in "${r}" --no-scan update "${d_own}"
if [[ $(cat "${r}/rc") == 0 ]] && seen '下限 5 日。設定 release-age.nix (flake の隣)' "${r}/stdout" \
  && picked "${r}" nixpkgs 4; then
  ok "--config が無ければ、対象の flake の隣の release-age.nix を読む"
else
  ng "--config が無ければ、対象の flake の隣の release-age.nix を読む" "$(detail "${r}")"
fi

r="${work}/r-own-beside"
run_script="${work}/beside/nix/scripts/flake-lock-age.sh" run_in "${r}" --no-scan update "${d_own}"
if seen '下限 5 日。設定 release-age.nix (flake の隣)' "${r}/stdout" && picked "${r}" nixpkgs 4; then
  ok "flake の隣の設定が、script の隣の設定に勝つ"
else
  ng "flake の隣の設定が、script の隣の設定に勝つ" "$(detail "${r}")"
fi

r="${work}/r-own-config"
run_script="${bare}" run_in "${r}" --config "${cfg}" --no-scan update "${d_own}"
if seen "下限 10 日。設定 ${cfg} (--config)" "${r}/stdout" && picked "${r}" nixpkgs 2; then
  ok "--config が、flake の隣の設定に勝つ"
else
  ng "--config が、flake の隣の設定に勝つ" "$(detail "${r}")"
fi

d_two=$(new_flake two "${old_lock}")
r="${work}/r-own-two"
run_script="${bare}" run_in "${r}" --no-scan update "${d_own}" "${d_two}"
if [[ $(cat "${r}/rc") == 0 ]] && picked_in "${r}" "${d_own}" nixpkgs 4 && picked_in "${r}" "${d_two}" nixpkgs 3 \
  && seen "==> ${d_two} (下限 7 日。既定。設定なし)" "${r}/stdout"; then
  ok "複数の flake は、それぞれの隣の設定で選ぶ (隣に無い flake は 7 日)"
else
  ng "複数の flake は、それぞれの隣の設定で選ぶ (隣に無い flake は 7 日)" "$(detail "${r}")"
fi

echo "== 全体の例外"

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-21"; reason = "全体の理由"; } ]; }'
r="${work}/r-all-on"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && picked "${r}" nixpkgs 6 && seen '例外 (全体) 2026-10-21: 効いている' "${r}/stdout"; then
  ok "date の日の終わりまでの最新の公開を選ぶ (14:59:59 UTC の公開は入り、15:00:00 UTC は入らない)"
else
  ng "date の日の終わりまでの最新の公開を選ぶ (14:59:59 UTC の公開は入り、15:00:00 UTC は入らない)" "$(detail "${r}")"
fi
if seen "--override-input home-manager github:nix-community/home-manager/$(hm 2)" "${r}/nix.log"; then
  ok "全体の例外があっても、home-manager は猶予のまま"
else
  ng "全体の例外があっても、home-manager は猶予のまま" "$(detail "${r}")"
fi
if picked "${r}" nixpkgs-exceptions 6; then
  ok "一部の例外が無ければ、nixpkgs-exceptions は nixpkgs と同じ rev"
else
  ng "一部の例外が無ければ、nixpkgs-exceptions は nixpkgs と同じ rev" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-15"; reason = "古い理由"; } ]; }'
r="${work}/r-all-old"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if picked "${r}" nixpkgs 3 && seen '例外 (全体) 2026-10-15: 何もしない' "${r}/stdout"; then
  ok "猶予より古い date は何もしない (その旨の行を出す)"
else
  ng "猶予より古い date は何もしない (その旨の行を出す)" "$(detail "${r}")"
fi

echo "== nixpkgs-exceptions"

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-22"; reason = "一部の理由"; } ]; }'
r="${work}/r-part-on"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if picked "${r}" nixpkgs 3 && picked "${r}" nixpkgs-exceptions 7 \
  && seen '例外 (一部・nixpkgs から) hello 2026-10-22: 効いている' "${r}/stdout"; then
  ok "date の日の終わりまでの公開が nixpkgs より新しければ、それを nixpkgs-exceptions に選ぶ"
else
  ng "date の日の終わりまでの公開が nixpkgs より新しければ、それを nixpkgs-exceptions に選ぶ" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-15"; reason = "一部の理由"; } ]; }'
r="${work}/r-part-old"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if picked "${r}" nixpkgs-exceptions 3 && seen '例外 (一部・nixpkgs から) hello 2026-10-15: 何もしない' "${r}/stdout"; then
  ok "date までの公開が nixpkgs より新しくなければ、nixpkgs と同じ rev"
else
  ng "date までの公開が nixpkgs より新しくなければ、nixpkgs と同じ rev" "$(detail "${r}")"
fi

echo "== --input"

settings "${cfg}" '{ }'
r="${work}/r-input-none"
run_in "${r}" --config "${cfg}" --input nixpkgs-exceptions --no-scan update "${d}"
want="flake update nixpkgs-exceptions --flake ${d} --override-input nixpkgs-exceptions github:NixOS/nixpkgs/$(rev 4)"
if [[ $(cat "${r}/rc") == 0 && $(cat "${r}/nix.log") == "${want}" ]]; then
  ok "--input nixpkgs-exceptions だけなら、それだけを lock の nixpkgs と同じ rev にする"
else
  ng "--input nixpkgs-exceptions だけなら、それだけを lock の nixpkgs と同じ rev にする" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-22"; reason = "一部の理由"; } ]; }'
r="${work}/r-input-part"
run_in "${r}" --config "${cfg}" --input nixpkgs-exceptions --no-scan update "${d}"
want="flake update nixpkgs-exceptions --flake ${d} --override-input nixpkgs-exceptions github:NixOS/nixpkgs/$(rev 7)"
if [[ $(cat "${r}/nix.log") == "${want}" ]]; then
  ok "--input nixpkgs-exceptions で一部の例外があれば、lock の nixpkgs より新しい date までの公開"
else
  ng "--input nixpkgs-exceptions で一部の例外があれば、lock の nixpkgs より新しい date までの公開" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-17"; reason = "一部の理由"; } ]; }'
r="${work}/r-input-older"
run_in "${r}" --config "${cfg}" --input nixpkgs-exceptions --no-scan update "${d}"
want="flake update nixpkgs-exceptions --flake ${d} --override-input nixpkgs-exceptions github:NixOS/nixpkgs/$(rev 4)"
if [[ $(cat "${r}/nix.log") == "${want}" ]]; then
  ok "--input で、date までの公開が lock の nixpkgs (公開の名前で見つける) より古ければ lock の nixpkgs の rev"
else
  ng "--input で、date までの公開が lock の nixpkgs (公開の名前で見つける) より古ければ lock の nixpkgs の rev" "$(detail "${r}")"
fi

r="${work}/r-input-unknown"
run_in "${r}" --config "${cfg}" --input no-such --no-scan update "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'no-such' "${r}/stderr" && [[ ! -s ${r}/nix.log ]]; then
  ok "--input に無い名前は止まる (nix flake update を打たない)"
else
  ng "--input に無い名前は止まる (nix flake update を打たない)" "$(detail "${r}")"
fi

echo "== lock に無い input"

settings "${cfg}" '{ }'
d_missing=$(new_flake missing "$(lock "$(nixpkgs_node 4 "$(at 2026-10-17T00:00:00Z)")")")
r="${work}/r-missing"
run_in "${r}" --config "${cfg}" --input nixpkgs-exceptions --no-scan update "${d_missing}"
want="flake update nixpkgs-exceptions --flake ${d_missing} --override-input nixpkgs-exceptions github:NixOS/nixpkgs/$(rev 4)"
if [[ $(cat "${r}/rc") == 0 && $(cat "${r}/nix.log") == "${want}" ]]; then
  ok "flake.nix にだけある nixpkgs-exceptions も、決まりどおり (lock の nixpkgs と同じ rev) に選ぶ"
else
  ng "flake.nix にだけある nixpkgs-exceptions も、決まりどおり (lock の nixpkgs と同じ rev) に選ぶ" "$(detail "${r}")"
fi

r="${work}/r-missing-other"
run_in "${r}" --config "${cfg}" --input nixpkgs --no-scan update "${d_missing}"
if [[ $(cat "${r}/rc") == 0 ]] && picked "${r}" nixpkgs 3 && picked "${r}" nixpkgs-exceptions 3 \
  && ! seen 'home-manager' "${r}/nix.log"; then
  ok "lock に無い nixpkgs-exceptions は、--input に無くても一緒に (nixpkgs と同じ rev で) 選ぶ"
else
  ng "lock に無い nixpkgs-exceptions は、--input に無くても一緒に (nixpkgs と同じ rev で) 選ぶ" "$(detail "${r}")"
fi

echo "== check"

young=$(at 2026-10-22T03:00:00Z) # 2 日前
young_lock=$(lock "$(nixpkgs_node 7 "${young}")" "$(nixpkgs_node 7 "${young}")")
d_young=$(new_flake young "${young_lock}")

settings "${cfg}" '{ }'
r="${work}/r-check-ng"
run_in "${r}" --config "${cfg}" check "${d_young}"
if [[ $(cat "${r}/rc") == 1 ]] && seen 'NG' "${r}/stdout"; then
  ok "猶予を満たさない nixpkgs は NG (終了コード 1)"
else
  ng "猶予を満たさない nixpkgs は NG (終了コード 1)" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-22"; reason = "全体の理由"; } ]; }'
r="${work}/r-check-all"
run_in "${r}" --config "${cfg}" check "${d_young}"
if [[ $(cat "${r}/rc") == 0 ]] && seen 'OK (例外 (全体) 2026-10-22)' "${r}/stdout" \
  && seen 'OK (nixpkgs と同じ rev)' "${r}/stdout"; then
  ok "全体の例外の date の日の終わりまでの nixpkgs と、それと同じ rev の nixpkgs-exceptions は OK"
else
  ng "全体の例外の date の日の終わりまでの nixpkgs と、それと同じ rev の nixpkgs-exceptions は OK" "$(detail "${r}")"
fi

part_lock=$(lock "$(nixpkgs_node 3 "$(at 2026-10-16T00:00:00Z)")" "$(nixpkgs_node 7 "${young}")")
d_part=$(new_flake part "${part_lock}")
settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-22"; reason = "一部の理由"; } ]; }'
r="${work}/r-check-part"
run_in "${r}" --config "${cfg}" check "${d_part}"
if [[ $(cat "${r}/rc") == 0 ]] && seen 'OK (例外 (一部・nixpkgs から) 2026-10-22)' "${r}/stdout"; then
  ok "一部の例外の date の日の終わりまでの nixpkgs-exceptions は OK"
else
  ng "一部の例外の date の日の終わりまでの nixpkgs-exceptions は OK" "$(detail "${r}")"
fi

settings "${cfg}" '{ }'
r="${work}/r-check-part-ng"
run_in "${r}" --config "${cfg}" check "${d_part}"
if [[ $(cat "${r}/rc") == 1 ]] && seen 'NG' "${r}/stdout"; then
  ok "一部の例外が無く、nixpkgs と違う新しい nixpkgs-exceptions は NG"
else
  ng "一部の例外が無く、nixpkgs と違う新しい nixpkgs-exceptions は NG" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-15"; reason = "古い理由"; } ]; }'
r="${work}/r-check-idle"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && seen '例外 (全体) 2026-10-15: 何もしない' "${r}/stdout"; then
  ok "何もしなくなった全体の例外に、check も「何もしない (… 消してよい)」の行を出す"
else
  ng "何もしなくなった全体の例外に、check も「何もしない (… 消してよい)」の行を出す" "$(detail "${r}")"
fi

echo "== 時差つきの timestamp"

# 公開 6 は 2026-10-21T14:59:59Z、公開 7 は 2026-10-21T15:00:00Z (= 2026-10-22T00:00:00+09:00)
for c in '2026-10-21T23:59:59+09:00 6' '2026-10-21T14:59:59Z 6' '2026-10-21T09:59:59-05:00 6' '2026-10-22T00:00:00+09:00 7'; do
  ts=${c% *}
  k=${c##* }
  settings "${cfg}" "{ exceptions.all = [ { date = \"${ts}\"; reason = \"時刻の理由\"; } ]; }"
  r="${work}/r-ts-${ts//[:+]/_}"
  run_in "${r}" --config "${cfg}" --no-scan update "${d}"
  if [[ $(cat "${r}/rc") == 0 ]] && picked "${r}" nixpkgs "${k}"; then
    ok "全体の例外の date ${ts} は、その時刻までの最新の公開 (${k}) を選ぶ"
  else
    ng "全体の例外の date ${ts} は、その時刻までの最新の公開 (${k}) を選ぶ" "$(detail "${r}")"
  fi
done
if seen '例外 (全体) 2026-10-22T00:00:00+09:00: 効いている。nixpkgs を 2026-10-22 00:00:00 JST (2026-10-21 15:00:00 UTC) まで' "${r}/stdout"; then
  ok "効いている timestamp の例外の行に、その時刻を JST と UTC で出す"
else
  ng "効いている timestamp の例外の行に、その時刻を JST と UTC で出す" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-22T00:00:00+09:00"; reason = "一部の理由"; } ]; }'
r="${work}/r-ts-part"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && picked "${r}" nixpkgs 3 && picked "${r}" nixpkgs-exceptions 7; then
  ok "一部の例外の timestamp も、その時刻までの公開を nixpkgs-exceptions に選ぶ"
else
  ng "一部の例外の timestamp も、その時刻までの公開を nixpkgs-exceptions に選ぶ" "$(detail "${r}")"
fi

# d_young の nixpkgs の lastModified は 2026-10-22T03:00:00Z (= 12:00:00+09:00)
settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-22T12:00:00+09:00"; reason = "時刻の理由"; } ]; }'
r="${work}/r-ts-check"
run_in "${r}" --config "${cfg}" check "${d_young}"
if [[ $(cat "${r}/rc") == 0 ]] && seen 'OK (例外 (全体) 2026-10-22T12:00:00+09:00)' "${r}/stdout"; then
  ok "check は、timestamp の例外の時刻までの pin を通す"
else
  ng "check は、timestamp の例外の時刻までの pin を通す" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-22T11:59:59+09:00"; reason = "時刻の理由"; } ]; }'
r="${work}/r-ts-check-ng"
run_in "${r}" --config "${cfg}" check "${d_young}"
if [[ $(cat "${r}/rc") == 1 ]] && seen 'NG' "${r}/stdout"; then
  ok "check は、timestamp の例外の時刻より 1 秒でも新しい pin を NG にする"
else
  ng "check は、timestamp の例外の時刻より 1 秒でも新しい pin を NG にする" "$(detail "${r}")"
fi

echo "== 時刻の出し方"

settings "${cfg}" '{ }'
r="${work}/r-label"
run_in "${r}" --config "${cfg}" resolve "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && seen '公開 2026-10-16 21:00:00 JST (12:00:00 UTC)' "${r}/stdout" \
  && seen 'commit 2026-10-16 09:00:00 JST (00:00:00 UTC)' "${r}/stdout"; then
  ok "resolve の nixpkgs の「公開」と github の input の「commit」に、時刻を JST と UTC で出す"
else
  ng "resolve の nixpkgs の「公開」と github の input の「commit」に、時刻を JST と UTC で出す" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-22"; reason = "日またぎ"; } ]; }'
r="${work}/r-label-cross"
run_in "${r}" --config "${cfg}" resolve "${d}"
if seen '公開 2026-10-22 00:00:00 JST (2026-10-21 15:00:00 UTC)' "${r}/stdout"; then
  ok "UTC の日付が JST と違えば、UTC も日付から出す"
else
  ng "UTC の日付が JST と違えば、UTC も日付から出す" "$(detail "${r}")"
fi

settings "${cfg}" '{ }'
r="${work}/r-label-check"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") == 0 ]] && seen 'commit 2026-10-17 09:00:00 JST (00:00:00 UTC)' "${r}/stdout"; then
  ok "check の時刻は lock の commit の時刻と分かる形 (commit) で、JST と UTC で出す"
else
  ng "check の時刻は lock の commit の時刻と分かる形 (commit) で、JST と UTC で出す" "$(detail "${r}")"
fi

echo "== ほかの repo (script の隣に設定が無い)"

d_other=$(new_plain_flake other "$(lock "$(nixpkgs_node 7 "${young}")")")
settings "${d_other}/release-age.nix" '{ exceptions.all = [ { date = "2026-10-22"; reason = "openssl の修正"; } ]; }'
r="${work}/r-other-check"
run_script="${bare}" run_in "${r}" check "${d_other}"
if [[ $(cat "${r}/rc") == 0 ]] && seen 'OK (例外 (全体) 2026-10-22)' "${r}/stdout" \
  && seen '設定 release-age.nix (flake の隣)' "${r}/stdout"; then
  ok "flake の隣の全体の例外で、猶予を満たさない nixpkgs の pin を check が通す"
else
  ng "flake の隣の全体の例外で、猶予を満たさない nixpkgs の pin を check が通す" "$(detail "${r}")"
fi

r="${work}/r-other-update"
run_script="${bare}" run_in "${r}" --no-scan update "${d_other}"
if [[ $(cat "${r}/rc") == 0 ]] && picked "${r}" nixpkgs 7 \
  && seen "--override-input home-manager github:nix-community/home-manager/$(hm 2)" "${r}/nix.log"; then
  ok "update も flake の隣の全体の例外で選ぶ (直しの前の版へ戻さない。ほかの github input は猶予のまま)"
else
  ng "update も flake の隣の全体の例外で選ぶ (直しの前の版へ戻さない。ほかの github input は猶予のまま)" "$(detail "${r}")"
fi

echo "== 一部の例外の置き場所"

d_plain=$(new_plain_flake plain "$(lock "$(nixpkgs_node 4 "$(at 2026-10-17T00:00:00Z)")")")
settings "${d_plain}/release-age.nix" '{
  exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-22"; reason = "一部の理由"; } ];
  exceptions.fromUpstream = [ { package = "mise"; version = "2026.10.17"; reason = "upstream の理由"; } ];
}'
r="${work}/r-partial-plain"
run_script="${bare}" run_in "${r}" --no-scan update "${d_plain}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'exceptions.fromNixpkgs の 1 件目 (hello' "${r}/stderr" \
  && seen 'exceptions.fromUpstream の 1 件目 (mise' "${r}/stderr" && [[ ! -s ${r}/nix.log ]]; then
  ok "input nixpkgs-exceptions の無い flake の隣の設定に、一部の例外 (nixpkgs から・upstream から) があれば止まる"
else
  ng "input nixpkgs-exceptions の無い flake の隣の設定に、一部の例外 (nixpkgs から・upstream から) があれば止まる" "$(detail "${r}")"
fi

d_dotlike=$(new_flake dotlike "${old_lock}")
settings "${d_dotlike}/release-age.nix" '{ exceptions.fromUpstream = [ { package = "mise"; version = "2026.10.17"; reason = "upstream の理由"; } ]; }'
r="${work}/r-partial-dotlike"
run_script="${bare}" run_in "${r}" check "${d_dotlike}"
if [[ $(cat "${r}/rc") == 0 ]]; then
  ok "input nixpkgs-exceptions のある flake (dotfiles の nix/ の形) の隣の設定には、一部の例外を書ける"
else
  ng "input nixpkgs-exceptions のある flake (dotfiles の nix/ の形) の隣の設定には、一部の例外を書ける" "$(detail "${r}")"
fi

mkdir -p "${work}/dotfiles/nix/scripts"
cp "${script}" "${work}/dotfiles/nix/scripts/flake-lock-age.sh"
settings "${work}/dotfiles/nix/release-age.nix" '{ exceptions.fromUpstream = [ { package = "mise"; version = "2026.10.17"; reason = "upstream の理由"; } ]; }'
d_skill=$(new_plain_flake skill "$(lock "$(nixpkgs_node 4 "$(at 2026-10-17T00:00:00Z)")")")
r="${work}/r-partial-borrow"
run_script="${work}/dotfiles/nix/scripts/flake-lock-age.sh" run_in "${r}" check "${d_skill}"
if [[ $(cat "${r}/rc") == 0 ]] && seen '(script の隣)' "${r}/stdout"; then
  ok "script の隣の設定 (dotfiles) を借りる flake (skill の flake の形) では、一部の例外を読み飛ばす"
else
  ng "script の隣の設定 (dotfiles) を借りる flake (skill の flake の形) では、一部の例外を読み飛ばす" "$(detail "${r}")"
fi

echo "== 設定の誤り"

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-1"; reason = "形の違う日付"; } ]; }'
r="${work}/r-bad-date"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '2026-10-1' "${r}/stderr"; then
  ok "設定の date が YYYY-MM-DD でなければ止まる"
else
  ng "設定の date が YYYY-MM-DD でなければ止まる" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2062-01-01"; reason = "先の日付"; } ]; }'
r="${work}/r-future-check"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '2062-01-01' "${r}/stderr"; then
  ok "今日より先の date は止まる (check)"
else
  ng "今日より先の date は止まる (check)" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.fromNixpkgs = [ { packages = [ "hello" ]; date = "2026-10-26"; reason = "あさって"; } ]; }'
r="${work}/r-future-update"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '2026-10-26' "${r}/stderr" && [[ ! -s ${r}/nix.log ]]; then
  ok "今日より先の date は止まる (update。nix flake update を打たない)"
else
  ng "今日より先の date は止まる (update。nix flake update を打たない)" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-24"; reason = "今日"; } ]; }'
r="${work}/r-today"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") == 0 ]]; then
  ok "今日 (Asia/Tokyo) の date は通る"
else
  ng "今日 (Asia/Tokyo) の date は通る" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-21T12:00:00"; reason = "時差が無い"; } ]; }'
r="${work}/r-ts-nozone"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'exceptions.all の 1 件目の date 2026-10-21T12:00:00 に時差が無い' "${r}/stderr"; then
  ok "時差の無い timestamp は止まる"
else
  ng "時差の無い timestamp は止まる" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-21T24:00:00+09:00"; reason = "時刻の誤り"; } { date = "2026-10-21T12:00:00+09:60"; reason = "時差の誤り"; } { date = "2026-02-30T12:00:00Z"; reason = "暦に無い"; } ]; }'
r="${work}/r-ts-range"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '1 件目の date 2026-10-21T24:00:00+09:00 は時刻か時差が正しくない' "${r}/stderr" \
  && seen '2 件目の date 2026-10-21T12:00:00+09:60 は時刻か時差が正しくない' "${r}/stderr" \
  && seen '3 件目の date 2026-02-30T12:00:00Z は暦に無い日付' "${r}/stderr"; then
  ok "timestamp の時刻・時差の誤りと、暦に無い日付は止まる"
else
  ng "timestamp の時刻・時差の誤りと、暦に無い日付は止まる" "$(detail "${r}")"
fi

# 今は 2026-10-24T03:00:00Z (= 12:00:00+09:00)
settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-24T12:00:01+09:00"; reason = "先の時刻"; } ]; }'
r="${work}/r-ts-future"
run_in "${r}" --config "${cfg}" --no-scan update "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'date 2026-10-24T12:00:01+09:00 は今' "${r}/stderr" && [[ ! -s ${r}/nix.log ]]; then
  ok "今より先の timestamp は止まる (nix flake update を打たない)"
else
  ng "今より先の timestamp は止まる (nix flake update を打たない)" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-10-24T03:00:00Z"; reason = "今"; } ]; }'
r="${work}/r-ts-now"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") == 0 ]]; then
  ok "今ちょうどの timestamp は通る"
else
  ng "今ちょうどの timestamp は通る" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { date = "2026-02-30"; reason = "暦に無い"; } ]; }'
r="${work}/r-calendar"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'exceptions.all の 1 件目の date 2026-02-30 は暦に無い日付' "${r}/stderr"; then
  ok "暦に無い date は止まる"
else
  ng "暦に無い date は止まる" "$(detail "${r}")"
fi

settings "${cfg}" '{ minimumReleaseAge = 6; exceptions.al = [ ]; exceptions.all = [ { date = "2026-10-21"; reason = "理由"; note = "x"; } ]; }'
r="${work}/r-unknown"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '知らない欄 minimumReleaseAge がある' "${r}/stderr" \
  && seen 'exceptions に知らない欄 al がある' "${r}/stderr" \
  && seen 'exceptions.all の 1 件目に知らない欄 note がある' "${r}/stderr"; then
  ok "知らない欄 (どの深さでも) を、まとめて出して止まる"
else
  ng "知らない欄 (どの深さでも) を、まとめて出して止まる" "$(detail "${r}")"
fi

settings "${cfg}" '{ minimumReleaseAgeDays = "6"; exceptions.all = { date = "2026-10-21"; reason = "理由"; }; exceptions.fromNixpkgs = [ "hello" ]; }'
r="${work}/r-types"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'minimumReleaseAgeDays は 0 以上の整数にする' "${r}/stderr" \
  && seen 'exceptions.all は list にする' "${r}/stderr" \
  && seen 'exceptions.fromNixpkgs の 1 件目は attrset にする' "${r}/stderr"; then
  ok "欄の型の誤り (日数が整数でない・list でない・項目が attrset でない) で止まる"
else
  ng "欄の型の誤り (日数が整数でない・list でない・項目が attrset でない) で止まる" "$(detail "${r}")"
fi

settings "${cfg}" '{ exceptions.all = [ { reason = "date が無い"; } { date = "2026-10-21"; reason = ""; } ]; }'
r="${work}/r-fields"
run_in "${r}" --config "${cfg}" check "${d}"
if [[ $(cat "${r}/rc") != 0 ]] && seen 'exceptions.all の 1 件目に date が無い' "${r}/stderr" \
  && seen 'exceptions.all の 2 件目の reason は' "${r}/stderr"; then
  ok "無い欄と空の reason で止まる"
else
  ng "無い欄と空の reason で止まる" "$(detail "${r}")"
fi

d_first=$(new_flake first "${old_lock}")
d_second=$(new_flake second "${old_lock}")
settings "${d_second}/release-age.nix" '{ exceptions.all = [ { date = "2026-02-30"; reason = "暦に無い"; } ]; }'
r="${work}/r-bad-later"
run_script="${bare}" run_in "${r}" --no-scan update "${d_first}" "${d_second}"
if [[ $(cat "${r}/rc") != 0 ]] && seen '2026-02-30' "${r}/stderr" && [[ ! -s ${r}/nix.log ]]; then
  ok "後ろの flake の設定に誤りがあれば、前の flake も更新しない"
else
  ng "後ろの flake の設定に誤りがあれば、前の flake も更新しない" "$(detail "${r}")"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]]
