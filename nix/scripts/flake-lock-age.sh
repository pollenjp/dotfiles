#!/usr/bin/env bash
# shellcheck shell=bash
#
# flake.lock の pin を「出てから一定日数が経った revision」に限る。
# npm / pnpm の minimumReleaseAge に相当するものを Nix 側で作るためのもの。
#
# ## なぜ script が要るのか
#
# Nix にはパッケージ単位のバージョン解決が無い。入るものは flake.lock が指す
# nixpkgs ツリー 1 点で決まるので、「新しすぎるパッケージを避ける」は
# 「新しすぎる revision を pin しない」と同義になる。`nix flake update` は常に
# 追跡先の先端を取るため、遅延はこちらで作るしかない。
#
# ## 何を根拠に日数を測るか
#
# - **nixpkgs**: releases.nixos.org 上のチャンネル公開時刻 (`Last-Modified`)。
#   `nixpkgs-unstable` の各公開は Hydra を通った commit なので、master の任意の
#   commit を日付だけで選ぶのとは違い binary cache が揃っている。ここを外すと
#   ほぼ全部ソースビルドになるので、公開の一覧から選ぶ形を崩さないこと。
# - **home-manager**: 既定ブランチの commit 時刻 (GitHub API の `until=`)。
#   home-manager にはチャンネルが無いので commit 時刻で測るしかない。
#
# `check` の判定だけは flake.lock の `lastModified` を使う。これは **commit 時刻**
# であって公開時刻ではなく、Hydra の遅れ (実測で 1〜2 日) の分だけ古い側に出る。
# つまり判定は公開日数より **緩い**。先端へ飛んだ事故を捕まえるには十分。
#
# ## 使い方
#
#   ./nix/scripts/flake-lock-age.sh resolve   選ぶ revision を出すだけ
#   ./nix/scripts/flake-lock-age.sh update    flake.lock をその revision へ更新
#   ./nix/scripts/flake-lock-age.sh check     今の flake.lock を検査 (CI 用)
#
# 日数は `DOTFILES_MIN_RELEASE_AGE_DAYS` で変える (既定 7)。0 で遅延なし。
# 緊急で CVE 修正を先端から入れたいときは 0 で `update` し、`check` の CI が
# 赤くなるのは意図どおりとして扱う (nix/README.md 「遅延を外す」)。
#
# ## 依存
#
# bash 3.2 / coreutils / curl / nix。**jq は使わない** (jq は Nix が入れるものな
# ので初回 switch 前には無い)。JSON は nix 自身に読ませる。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)
nix_dir=$(dirname "${script_dir}")
lock_file="${nix_dir}/flake.lock"

# 空文字も既定へ落とす。CI は workflow_dispatch 以外で空を渡してくる。
min_age_days=${DOTFILES_MIN_RELEASE_AGE_DAYS:-7}
case ${min_age_days} in
  '' | *[!0-9]*)
    printf 'ERROR: DOTFILES_MIN_RELEASE_AGE_DAYS は 0 以上の整数で指定すること (受け取った値: %s)\n' \
      "${min_age_days}" >&2
    exit 1
    ;;
esac
# 先頭 0 を 8 進数と解釈させない (10# を付けられない箇所で算術に使うため)。
min_age_days=$((10#${min_age_days}))

# 追跡しているチャンネル。flake.nix の nixpkgs.url と一致していること
# (require_channel_input が実際に照合する)。
channel=nixpkgs-unstable
channel_url="https://channels.nixos.org/${channel}"
releases_url="https://releases.nixos.org/nixpkgs"
# ListObjectsV2 を直接引く。releases.nixos.org の索引は JS で描画されるので
# HTML からは公開の一覧が辿れない。
bucket_url="https://nix-releases.s3.amazonaws.com"

# 遡って公開時刻を調べる最大件数。1 件ごとに HEAD が 1 本飛ぶ。
# 公開は 1〜3 日おきなので 40 件で 2〜3 か月分に届く。
max_candidates=40

c_dim=$'\033[2m'
c_red=$'\033[31m'
c_yellow=$'\033[33m'
c_cyan=$'\033[36m'
c_reset=$'\033[0m'
if [[ ! -t 1 ]]; then
  c_dim="" c_red="" c_yellow="" c_cyan="" c_reset=""
fi

note() {
  printf '  %s%s%s\n' "${c_dim}" "$*" "${c_reset}"
}

# 直前の行に対する補足。1 段深く出す。
detail() {
  printf '                %s%s%s\n' "${c_dim}" "$*" "${c_reset}"
}

warn() {
  printf '%s!! %s%s\n' "${c_yellow}" "$*" "${c_reset}" >&2
}

die() {
  printf '%sERROR: %s%s\n' "${c_red}" "$*" "${c_reset}" >&2
  exit 1
}

##########
# 日付   #
##########

# GNU coreutils と BSD (macOS) で date の書式指定が違う。判定は GNU にしか無い
# -d を試すだけでよい。
if date -u -d @0 +%s >/dev/null 2>&1; then
  date_flavor=gnu
else
  date_flavor=bsd
fi

# epoch -> YYYY-MM-DD
epoch_to_day() {
  case ${date_flavor} in
    gnu) date -u -d "@$1" +%Y-%m-%d ;;
    bsd) date -u -r "$1" +%Y-%m-%d ;;
  esac
}

# epoch -> GitHub API の until= に渡す ISO 8601
epoch_to_iso() {
  case ${date_flavor} in
    gnu) date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ ;;
    bsd) date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ ;;
  esac
}

# HTTP の Last-Modified ("Mon, 25 May 2026 20:47:05 GMT") -> epoch。
# 月名を英語で読ませるため LC_ALL=C を固定する。
http_date_to_epoch() {
  case ${date_flavor} in
    gnu) LC_ALL=C date -u -d "$1" +%s ;;
    bsd) LC_ALL=C date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "$1" +%s ;;
  esac
}

##############
# flake.lock #
##############

# flake.lock の 1 フィールドを読む。読めなければ空を返す (呼び側で判定する)。
# 属性名に `-` が入る (home-manager) ので引用符を付けて引く。
lock_field() {
  nix eval --raw --impure --expr \
    "toString (builtins.fromJSON (builtins.readFile \"${lock_file}\")).nodes.\"$1\".$2" \
    2>/dev/null || true
}

# この script の遅延の作り方はチャンネル前提なので、追跡先が変わっていたら止める。
require_channel_input() {
  local ref
  ref=$(lock_field nixpkgs 'original.ref')
  if [[ ${ref} != "${channel}" ]]; then
    die "flake.nix の nixpkgs が ${channel} を追っていません (ref=${ref:-なし})。
公開の一覧から選ぶ形が崩れるので、追跡先を変えたならこの script も直すこと。"
  fi
}

################
# nixpkgs 側   #
################

# 追跡中チャンネルの現在の公開名 (例 nixpkgs-26.11pre1052792.044bfe75bfe4)。
# channels.nixos.org は releases.nixos.org の該当ディレクトリへ 302 する。
current_release() {
  curl -fsSI "${channel_url}" \
    | tr -d '\r' \
    | sed -n 's|^[Ll]ocation:.*/nixpkgs/\(nixpkgs-[^/[:space:]]*\).*|\1|p' \
    | head -n 1
}

# nixpkgs-26.11pre1052792.044bfe... -> nixpkgs-26.11pre
series_of() {
  printf '%s\n' "${1%%pre*}pre"
}

# unstable の系列は半年ごとに変わる (…26.05pre -> 26.11pre -> 27.05pre)。
# 分岐直後は新しい系列に「十分古い公開」が 1 件も無いので 1 つ前も見る。
previous_series() {
  local ver=${1#nixpkgs-} yy mm
  ver=${ver%pre}
  yy=${ver%%.*}
  mm=${ver##*.}
  case ${mm} in
    11) printf 'nixpkgs-%s.05pre\n' "${yy}" ;;
    05) printf 'nixpkgs-%02d.11pre\n' "$((10#${yy} - 1))" ;;
    *) return 1 ;;
  esac
}

# 系列に属する公開を古い順に並べる。名前の連番は単調増加なので辞書順で足りる。
list_series() {
  local xml
  xml=$(curl -fsS "${bucket_url}/?list-type=2&prefix=nixpkgs/$1&delimiter=/&max-keys=1000") \
    || return 1
  case ${xml} in
    *'<IsTruncated>true</IsTruncated>'*)
      warn "$1 の一覧が 1000 件で切れました。古い側だけを見ています。"
      ;;
  esac
  printf '%s\n' "${xml}" \
    | tr '<' '\n' \
    | sed -n "s|^Prefix>nixpkgs/\($1[^/]*\)/\$|\1|p"
}

# 公開時刻。git-revision の Last-Modified がチャンネルが出た時刻そのもの。
release_published_epoch() {
  local lm
  lm=$(curl -fsSI "${releases_url}/$1/git-revision" \
    | tr -d '\r' \
    | sed -n 's|^[Ll]ast-[Mm]odified:[[:space:]]*||p' \
    | head -n 1)
  [[ -n ${lm} ]] || return 1
  http_date_to_epoch "${lm}"
}

# cutoff 以前に公開された最新のチャンネル公開を選ぶ。
#
#   pick_nixpkgs_release <cutoff> <系列>...
#
# 系列は **古い順** に並べて渡す。見つかったら picked_release / picked_epoch /
# picked_rev を埋める。見つからなければ 1 を返す。
picked_release=""
picked_epoch=""
picked_rev=""
# 走査上限に当たって打ち切ったか。見つからなかった理由を分けて報告するため。
hit_candidate_cap=0
pick_nixpkgs_release() {
  local cutoff=$1 series rel epoch i seen=0
  local -a releases=()
  shift
  hit_candidate_cap=0
  for series in "$@"; do
    while IFS= read -r rel; do
      [[ -n ${rel} ]] || continue
      releases+=("${rel}")
    done < <(list_series "${series}")
  done
  if [[ ${#releases[@]} -eq 0 ]]; then
    die "チャンネル公開の一覧が空でした ($*)。"
  fi
  # 新しい側から順に見て、最初に cutoff を満たしたものを採る。
  for ((i = ${#releases[@]} - 1; i >= 0; i--)); do
    rel=${releases[i]}
    seen=$((seen + 1))
    if [[ ${seen} -gt ${max_candidates} ]]; then
      hit_candidate_cap=1
      break
    fi
    epoch=$(release_published_epoch "${rel}") || continue
    if [[ ${epoch} -le ${cutoff} ]]; then
      picked_release=${rel}
      picked_epoch=${epoch}
      picked_rev=$(curl -fsS "${releases_url}/${rel}/git-revision" | tr -d '\r\n')
      return 0
    fi
  done
  return 1
}

#####################
# home-manager 側   #
#####################

hm_rev=""
hm_epoch=""
# cutoff 以前で最新の commit を GitHub に直接引かせる。flake.nix が ref を
# 指定していないので既定ブランチが対象 (sha= は渡さない)。
pick_home_manager_commit() {
  local cutoff=$1 owner repo url json date_str
  owner=$(lock_field home-manager 'locked.owner')
  repo=$(lock_field home-manager 'locked.repo')
  if [[ -z ${owner} || -z ${repo} ]]; then
    die "flake.lock から home-manager の owner/repo が読めませんでした。"
  fi
  url="https://api.github.com/repos/${owner}/${repo}/commits?per_page=1&until=$(epoch_to_iso "${cutoff}")"
  # 未認証は 60 req/hour。1 回の実行で 1 本しか投げないので通常は足りるが、
  # CI では GITHUB_TOKEN があれば使う。
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    json=$(curl -fsS -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}")
  else
    json=$(curl -fsS -H 'Accept: application/vnd.github+json' "${url}")
  fi
  # 応答の最初の "sha" が commit 自身の sha (以降は tree / parents のもの)。
  hm_rev=$(printf '%s\n' "${json}" \
    | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' \
    | head -n 1 \
    | grep -oE '[0-9a-f]{40}')
  if [[ -z ${hm_rev} ]]; then
    die "${owner}/${repo} に ${cutoff} 以前の commit が見つかりませんでした。"
  fi
  # 表示用。committer の日付が commit そのものの時刻。
  date_str=$(printf '%s\n' "${json}" \
    | grep -oE '"date"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' \
    | tail -n 1 \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z')
  hm_epoch=""
  if [[ -n ${date_str} ]]; then
    case ${date_flavor} in
      gnu) hm_epoch=$(date -u -d "${date_str}" +%s) ;;
      bsd) hm_epoch=$(LC_ALL=C date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${date_str}" +%s) ;;
    esac
  fi
}

##########
# 各動作 #
##########

age_days() {
  printf '%s\n' "$((($1 - $2) / 86400))"
}

die_not_found() {
  if [[ ${hit_candidate_cap} -eq 1 ]]; then
    die "${min_age_days} 日以上前のチャンネル公開に、新しい側から ${max_candidates} 件
遡っても届きませんでした。日数の設定が大きすぎます (公開は 1〜3 日おき)。"
  fi
  die "${min_age_days} 日以上前のチャンネル公開が見つかりませんでした。"
}

resolve() {
  local now cutoff series prev
  now=$(date -u +%s)
  cutoff=$((now - min_age_days * 86400))

  require_channel_input

  series=$(series_of "$(current_release)")
  [[ ${series} != pre ]] || die "チャンネル ${channel} の現在の公開名が取れませんでした。"
  if ! pick_nixpkgs_release "${cutoff}" "${series}"; then
    # 系列が分岐した直後。1 つ前の系列まで広げてもう一度探す。
    prev=$(previous_series "${series}") || die_not_found
    note "${series} に ${min_age_days} 日以上前の公開が無いので ${prev} も見ます。"
    pick_nixpkgs_release "${cutoff}" "${prev}" "${series}" || die_not_found
  fi

  pick_home_manager_commit "${cutoff}"

  printf '%s==> %s 日以上前の revision を選びました%s\n' \
    "${c_cyan}" "${min_age_days}" "${c_reset}"
  printf '  %-13s %s\n' nixpkgs "${picked_rev}"
  detail "${picked_release} / 公開 $(epoch_to_day "${picked_epoch}") ($(age_days "${now}" "${picked_epoch}") 日前)"
  printf '  %-13s %s\n' home-manager "${hm_rev}"
  if [[ -n ${hm_epoch} ]]; then
    detail "commit $(epoch_to_day "${hm_epoch}") ($(age_days "${now}" "${hm_epoch}") 日前)"
  fi
}

cmd_update() {
  resolve
  printf '%s+ nix flake update nixpkgs home-manager --flake %s ...%s\n' \
    "${c_cyan}" "${nix_dir}" "${c_reset}"
  # --override-input は flake.nix を書き換えずに lock の pin だけを差し替える。
  # `nix flake update` 経由なら lock へ書き込まれる (nix 2.34 で実測)。
  # flake.nix 側は ${channel} を指したままなので、素で `nix flake update` を
  # 叩くと先端へ飛ぶ。そのための保険が check (CI で回している)。
  nix flake update nixpkgs home-manager --flake "${nix_dir}" \
    --override-input nixpkgs "github:NixOS/nixpkgs/${picked_rev}" \
    --override-input home-manager "github:nix-community/home-manager/${hm_rev}"
}

cmd_check() {
  local now node lm age failed=0
  now=$(date -u +%s)
  printf '%s==> flake.lock の pin の古さ (下限 %s 日)%s\n' \
    "${c_cyan}" "${min_age_days}" "${c_reset}"
  if [[ ${min_age_days} -eq 0 ]]; then
    note '下限 0 なので常に通ります (DOTFILES_MIN_RELEASE_AGE_DAYS=0)。'
  fi
  for node in nixpkgs home-manager; do
    lm=$(lock_field "${node}" 'locked.lastModified')
    if [[ -z ${lm} ]]; then
      die "flake.lock から ${node} の lastModified が読めませんでした。"
    fi
    age=$(age_days "${now}" "${lm}")
    if [[ ${age} -lt ${min_age_days} ]]; then
      printf '  %-13s %s (%s 日前)  %sNG%s\n' \
        "${node}" "$(epoch_to_day "${lm}")" "${age}" "${c_red}" "${c_reset}"
      failed=1
    else
      printf '  %-13s %s (%s 日前)  OK\n' \
        "${node}" "$(epoch_to_day "${lm}")" "${age}"
    fi
  done
  if [[ ${failed} -eq 1 ]]; then
    die "先端に近すぎる pin があります。
./nix/scripts/flake-lock-age.sh update で ${min_age_days} 日以上前の revision へ
下げ直すこと。意図して先端を入れた (緊急の CVE 修正など) 場合は、この失敗は
意図どおりなので、そのまま記録として残すか workflow_dispatch で下限を下げて
再実行する。"
  fi
}

case ${1:-} in
  resolve) resolve ;;
  update) cmd_update ;;
  check) cmd_check ;;
  *)
    cat <<'EOS' >&2
使い方: flake-lock-age.sh <resolve|update|check>

  resolve  遅延を満たす revision を表示するだけ (flake.lock は触らない)
  update   その revision へ flake.lock を更新する
  check    今の flake.lock が下限日数を満たすか検査する (CI 用)

日数は DOTFILES_MIN_RELEASE_AGE_DAYS で変える (既定 7)。
EOS
    exit 2
    ;;
esac
