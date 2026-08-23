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
# ## 何を対象にするか
#
# 渡された flake の **root の直下 input すべて**。input ごとに flake.lock から
# 種別を読んで測り方を選ぶ。片方だけ遅らせても、もう片方が先端に張り付く。
#
# - **nixpkgs** (nixpkgs-unstable を追うもの): releases.nixos.org 上のチャンネル
#   公開時刻 (`Last-Modified`)。各公開は Hydra を通った commit なので、master の
#   任意の commit を日付だけで選ぶのとは違い binary cache が揃っている。ここを
#   外すとほぼ全部ソースビルドになるので、公開の一覧から選ぶ形を崩さないこと。
# - **その他の github input** (home-manager など): 追跡先の commit 時刻
#   (GitHub API の `until=`)。これらにはチャンネルが無いので commit 時刻で測る。
# - **follows / github 以外の input**: 対象外。自分の revision を持たないか、
#   持っていても公開という概念が無い (`path:` など)。
#
# `check` の判定だけは flake.lock の `lastModified` を使う。これは **commit 時刻**
# であって公開時刻ではなく、Hydra の遅れ (実測で 1〜2 日) の分だけ古い側に出る。
# つまり判定は公開日数より **緩い**。先端へ飛んだ事故を捕まえるには十分。
#
# ## 使い方
#
#   flake-lock-age.sh resolve [<flake ディレクトリ>...]  選ぶ revision を出すだけ
#   flake-lock-age.sh update  [<flake ディレクトリ>...]  flake.lock をその revision へ更新
#   flake-lock-age.sh check   [<flake ディレクトリ>...]  今の flake.lock を検査 (CI 用)
#
# `update` は lock を書いたあと、その lock で実際に入る閉包のスキャン
# (closure-scan.sh / ADR 006) を自動で差し込む。lock を作る・上げる入口はここ
# しか無いので、「新しい pin を初めて実行する前に必ず照合が挟まる」を、この
# 位置に置くことで作っている。whitelist のある flake ではゲート (新規 findings
# で失敗)、無い flake (初回の lock など) では表示だけ。--no-scan で飛ばせる。
#
# `flake.lock` がまだ無い flake でも resolve / update は通る (input の一覧を
# flake.nix の `inputs` から読む)。**最初の lock も update で作ること。** 先に
# `nix flake lock` を打つと一度先端へ pin されるので、遅延が最初から外れた lock を
# commit することになる。`check` は「今 pin されているもの」を測るので lock が要る。
#
# ディレクトリを省いたときの既定は、**この script の隣** (`<script>/../flake.nix`)
# があればそこ、無ければカレントディレクトリ。前者は dotfiles のチェックアウトから
# 直接叩く場合、後者は他のリポジトリから nix run で呼ぶ場合を想定している。
#
#   nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
#
# 日数は `--min-age-days N` か環境変数 `FLAKE_MIN_RELEASE_AGE_DAYS` で変える
# (既定 7)。0 で遅延なし。緊急で CVE 修正を先端から入れたいときは 0 で `update` し、
# `check` の CI が赤くなるのは意図どおりとして扱う (nix/README.md 「遅延を外す」)。
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

# 追跡しているチャンネル。nixpkgs input の original.ref がこれと違えば止める
# (classify_input が実際に照合する)。
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

usage() {
  cat <<'EOS'
使い方: flake-lock-age.sh [オプション] <resolve|update|check> [<flake ディレクトリ>...]

  resolve  遅延を満たす revision を表示するだけ (flake.lock は触らない)
  update   その revision へ flake.lock を更新し、入る閉包をスキャンする
           (whitelist のある flake はゲート、無い flake は表示だけ)
  check    今の flake.lock が下限日数を満たすか検査する (CI 用)

オプション:
  --min-age-days N  下限日数 (既定 7 / 環境変数 FLAKE_MIN_RELEASE_AGE_DAYS)
  --no-scan         update 後の閉包スキャン (closure-scan) を飛ばす
  -h, --help        この使い方を出す

ディレクトリを省くと、この script の隣 (<script>/../flake.nix) があればそこ、
無ければカレントディレクトリを対象にする。複数渡せば順に処理する。

flake.lock がまだ無い flake でも resolve / update は通る (最初の lock も update で
作る)。先に nix flake lock を打つと一度先端へ pin されるので使わないこと。
EOS
}

##########
# 引数   #
##########

# 空文字も既定へ落とす。CI は workflow_dispatch 以外で空を渡してくる。
min_age_days=${FLAKE_MIN_RELEASE_AGE_DAYS:-7}
cmd=""
flake_dirs=()
no_scan=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --min-age-days)
      [[ $# -ge 2 ]] || die '--min-age-days には日数が要ります。'
      min_age_days=$2
      shift 2
      ;;
    --min-age-days=*)
      min_age_days=${1#*=}
      shift
      ;;
    --no-scan)
      no_scan=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    resolve | update | check)
      [[ -z ${cmd} ]] || die "動作は 1 つだけ指定すること (${cmd} と $1 が指定されました)。"
      cmd=$1
      shift
      ;;
    -*)
      usage >&2
      die "不明なオプション: $1"
      ;;
    *)
      flake_dirs+=("$1")
      shift
      ;;
  esac
done

if [[ -z ${cmd} ]]; then
  usage >&2
  exit 2
fi

case ${min_age_days} in
  '') min_age_days=7 ;;
  *[!0-9]*)
    die "下限日数は 0 以上の整数で指定すること (受け取った値: ${min_age_days})"
    ;;
esac
# 先頭 0 を 8 進数と解釈させない (10# を付けられない箇所で算術に使うため)。
min_age_days=$((10#${min_age_days}))

# 省略時の既定。チェックアウトから直接叩く形 (dotfiles) と、store から nix run で
# 呼ぶ形の両方を通すため、script の隣に flake があるかで分ける。目印は flake.nix。
# flake.lock で見ると、lock がまだ無い flake から呼んだときに判定が変わる。
# nix run 経由では script は writeShellApplication の bin/ に居るだけなので、
# 隣に flake.nix は無く、カレントディレクトリ側へ落ちる。
# 空配列への [@] 展開は bash 4.3 以前の set -u で落ちるので +x で見る。
if [[ -z ${flake_dirs[*]+x} ]]; then
  if [[ -f "${script_dir}/../flake.nix" ]]; then
    flake_dirs=("$(
      cd -- "${script_dir}/.." &>/dev/null
      pwd -P
    )")
  else
    flake_dirs=(.)
  fi
fi

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

# ISO 8601 (GitHub API の commit 日時) -> epoch
iso_to_epoch() {
  case ${date_flavor} in
    gnu) date -u -d "$1" +%s ;;
    bsd) LC_ALL=C date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s ;;
  esac
}

age_days() {
  printf '%s\n' "$((($1 - $2) / 86400))"
}

################
# input の一覧 #
################

# root の直下 input を 1 行 1 件で出す。区切りはタブ。
#
#   <名前> <type> <owner> <repo> <lastModified> <original.ref>
#
# 今 pin されている rev は出さない。update は新しい rev を自分で決めるし、
# check は lastModified しか見ないので誰も使わない。
#
# follows で他の input を指しているものは自分の locked ノードを持たない
# (root.inputs の値が文字列ではなく配列になる) ので落とす。
lock_inputs() {
  nix eval --raw --impure --expr "
    let
      lock = builtins.fromJSON (builtins.readFile \"$1\");
      root = lock.nodes.\${lock.root};
      names = builtins.filter (n: builtins.isString root.inputs.\${n})
        (builtins.attrNames (root.inputs or { }));
      line = n:
        let
          node = lock.nodes.\${root.inputs.\${n}};
          l = node.locked or { };
          o = node.original or { };
        in
        builtins.concatStringsSep \"\t\" [
          n
          (l.type or \"\")
          (l.owner or \"\")
          (l.repo or \"\")
          (toString (l.lastModified or 0))
          (o.ref or \"\")
        ];
    in
    builtins.concatStringsSep \"\n\" (map line names)
  "
}

# lock がまだ無い flake 用。同じ形の行を flake.nix の `inputs` から作る。
#
# lastModified は常に 0 を置く。pin がまだ無いので測るものが無い。この行を使うのは
# resolve / update だけで、lastModified を見る check は lock を要求する。
#
# url の文字列は builtins.parseFlakeRef に解かせる。github:owner/repo/ref?dir=...
# の細部を自前で切ると必ずずれるし、nix が実際に解くのと同じ結果が要る。
#
# flake の評価ではなく flake.nix の import なので、input の取得は起きず、
# flake.nix が git に追加されていなくても読める (追加は update の nix 側で要る)。
# `outputs` は関数だが遅延評価なので触らなければ問題にならない。
flake_nix_inputs() {
  nix eval --raw --impure --expr "
    let
      flake = import \"$1\";
      inputs = flake.inputs or { };
      line = n:
        let
          spec = inputs.\${n};
          # 文字列と url は flake ref として解く。どちらでもなければ type などを
          # 直に書いた形と見る。follows だけの input は自分の revision を持たない
          # ので、type を follows にして下の classify_input で対象外へ落とす。
          r =
            if builtins.isString spec then builtins.parseFlakeRef spec
            else if spec ? url then builtins.parseFlakeRef spec.url
            else if spec ? type then spec
            else { type = if spec ? follows then \"follows\" else \"\"; };
        in
        builtins.concatStringsSep \"\t\" [
          n
          (r.type or \"\")
          (r.owner or \"\")
          (r.repo or \"\")
          \"0\"
          (r.ref or \"\")
        ];
    in
    builtins.concatStringsSep \"\n\" (map line (builtins.attrNames inputs))
  "
}

# lock_inputs を呼んで、読めなかったときにその場で止める。
# `< <(...)` で while へ流すと nix 側の失敗を取りこぼす (while は 0 で終わる)
# ので、一度変数へ受けてから流す。
read_lock_inputs() {
  local rows
  rows=$(lock_inputs "$1") || die "flake.lock を読めませんでした: $1"
  printf '%s\n' "${rows}"
}

read_flake_nix_inputs() {
  local rows
  rows=$(flake_nix_inputs "$1") || die "flake.nix の inputs を読めませんでした: $1"
  printf '%s\n' "${rows}"
}

# flake ディレクトリを検算して **絶対パス** を出す。絶対にするのは
# builtins.readFile / import が相対パスの文字列を受け付けないため
# ("string './nix/flake.lock' doesn't represent an absolute path")。
abs_flake_dir() {
  local dir=$1
  [[ -d ${dir} ]] || die "flake ディレクトリがありません: ${dir}"
  [[ -f ${dir}/flake.nix ]] || die "flake.nix がありません: ${dir}/flake.nix"
  (
    cd -- "${dir}" &>/dev/null
    pwd -P
  )
}

# resolve / update が使う入口。lock があればその locked から、無ければ flake.nix
# から読む。lock が無い状態で止めないのは、そこで `nix flake lock` を打たせると
# 一度先端へ pin されてしまうため。最初の lock も update で作れる。
read_inputs() {
  local dir=$1 abs
  abs=$(abs_flake_dir "${dir}") || return 1
  if [[ -f ${abs}/flake.lock ]]; then
    read_lock_inputs "${abs}/flake.lock"
  else
    read_flake_nix_inputs "${abs}/flake.nix"
  fi
}

# input 1 件の測り方を決めて input_kind へ入れる (channel / commit / skip)。
# 返り値ではなくグローバルへ置くのは、追跡先が想定外のときに die でここから
# 抜けたいため。$(...) で呼ぶと subshell になって exit が効かない。
input_kind=""
classify_input() {
  local name=$1 type=$2 owner=$3 repo=$4 ref=$5 slug
  if [[ ${type} != github ]]; then
    input_kind=skip
    return 0
  fi
  # GitHub の owner は大文字小文字を区別しない。lock には書かれたとおり入る。
  slug=$(printf '%s/%s' "${owner}" "${repo}" | tr '[:upper:]' '[:lower:]')
  if [[ ${slug} == nixos/nixpkgs ]]; then
    # この script の遅延の作り方はチャンネル前提。追跡先が変わっていたら止める。
    if [[ ${ref} != "${channel}" ]]; then
      die "input '${name}' の nixpkgs が ${channel} を追っていません (ref=${ref:-なし})。
公開の一覧から選ぶ形が崩れると binary cache の揃わない revision を掴むので、
追跡先を変えたならこの script も直すこと。"
    fi
    input_kind=channel
    return 0
  fi
  input_kind=commit
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
  local releases=()
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

die_not_found() {
  if [[ ${hit_candidate_cap} -eq 1 ]]; then
    die "${min_age_days} 日以上前のチャンネル公開に、新しい側から ${max_candidates} 件
遡っても届きませんでした。日数の設定が大きすぎます (公開は 1〜3 日おき)。"
  fi
  die "${min_age_days} 日以上前のチャンネル公開が見つかりませんでした。"
}

# 選ぶ公開は cutoff だけで決まる。複数の flake を続けて処理するとき、同じ
# HEAD を何度も投げないよう 1 度だけ解決する。
nixpkgs_resolved=0
resolve_nixpkgs_once() {
  local cutoff=$1 series prev
  [[ ${nixpkgs_resolved} -eq 0 ]] || return 0
  series=$(series_of "$(current_release)")
  [[ ${series} != pre ]] || die "チャンネル ${channel} の現在の公開名が取れませんでした。"
  if ! pick_nixpkgs_release "${cutoff}" "${series}"; then
    # 系列が分岐した直後。1 つ前の系列まで広げてもう一度探す。
    prev=$(previous_series "${series}") || die_not_found
    note "${series} に ${min_age_days} 日以上前の公開が無いので ${prev} も見ます。"
    pick_nixpkgs_release "${cutoff}" "${prev}" "${series}" || die_not_found
  fi
  nixpkgs_resolved=1
}

#####################
# github の commit  #
#####################

gh_rev=""
gh_epoch=""
# cutoff 以前で最新の commit を GitHub に直接引かせる。ref を指定していない
# input は既定ブランチが対象になる。
pick_github_commit() {
  local name=$1 owner=$2 repo=$3 ref=$4 cutoff=$5 url json date_str
  url="https://api.github.com/repos/${owner}/${repo}/commits?per_page=1&until=$(epoch_to_iso "${cutoff}")"
  if [[ -n ${ref} ]]; then
    url="${url}&sha=${ref}"
  fi
  # 未認証は 60 req/hour。input 1 件につき 1 本しか投げないので通常は足りるが、
  # CI では GITHUB_TOKEN があれば使う。
  #
  # -L が要る。改名・移管された repo は 301 を JSON の本体付きで返し、-f は 3xx で
  # 落ちないので、追わないと「sha が無い応答」として下の空振り判定に化ける
  # (「commit が見つかりません」に見えるが実際は repo が動いている)。転送先は同じ
  # api.github.com なので Authorization ヘッダは維持される。
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}")
  else
    json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "${url}")
  fi
  # 応答の最初の "sha" が commit 自身の sha (以降は tree / parents のもの)。
  # 空振りは下で判定するので、pipefail に殺されないよう握る。
  gh_rev=$(printf '%s\n' "${json}" \
    | grep -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' \
    | head -n 1 \
    | grep -oE '[0-9a-f]{40}' || true)
  if [[ -z ${gh_rev} ]]; then
    die "input '${name}' (${owner}/${repo}) に $(epoch_to_day "${cutoff}") 以前の commit が
見つかりませんでした。"
  fi
  # 表示用。committer の日付が commit そのものの時刻。
  date_str=$(printf '%s\n' "${json}" \
    | grep -oE '"date"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' \
    | tail -n 1 \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' || true)
  gh_epoch=""
  if [[ -n ${date_str} ]]; then
    gh_epoch=$(iso_to_epoch "${date_str}")
  fi
}

##########
# 各動作 #
##########

# check 専用。check は「今 pin されているもの」を測るので lock が要る。
# ここで `nix flake lock` を勧めてはいけない (一度先端へ pin されるので、
# その lock は check を通らない)。最初の lock は update が作る。
lock_path_of() {
  local dir=$1 abs
  abs=$(abs_flake_dir "${dir}")
  [[ -f ${abs}/flake.lock ]] || die "flake.lock がありません: ${dir}/flake.lock
(まだ lock が無いなら flake-lock-age.sh update で作ること。素の nix flake lock は
先端へ pin するので、遅延が最初から外れた lock になる。)"
  printf '%s/flake.lock\n' "${abs}"
}

# resolve_dir が埋める。update はこれをそのまま --override-input へ渡す。
# URL の owner/repo は読んだ側 (flake.lock の locked、無ければ flake.nix の inputs)
# から取る。追跡先を勝手に変えないため。
resolved_names=()
resolved_urls=()

resolve_dir() {
  local dir=$1 now cutoff rows
  local name type owner repo lastmod ref
  # die は $(...) の中では subshell を抜けるだけなので、呼び側で失敗を見る。
  rows=$(read_inputs "${dir}") || return 1
  now=$(date -u +%s)
  cutoff=$((now - min_age_days * 86400))

  resolved_names=()
  resolved_urls=()

  printf '%s==> %s (下限 %s 日)%s\n' "${c_cyan}" "${dir}" "${min_age_days}" "${c_reset}"
  if [[ ! -f ${dir}/flake.lock ]]; then
    note 'flake.lock がまだ無いので flake.nix の inputs から決めます。'
  fi

  while IFS=$'\t' read -r name type owner repo lastmod ref; do
    [[ -n ${name} ]] || continue
    classify_input "${name}" "${type}" "${owner}" "${repo}" "${ref}"
    case ${input_kind} in
      channel)
        resolve_nixpkgs_once "${cutoff}"
        resolved_names+=("${name}")
        resolved_urls+=("github:${owner}/${repo}/${picked_rev}")
        printf '  %-14s %s\n' "${name}" "${picked_rev}"
        detail "${picked_release} / 公開 $(epoch_to_day "${picked_epoch}") ($(age_days "${now}" "${picked_epoch}") 日前)"
        ;;
      commit)
        pick_github_commit "${name}" "${owner}" "${repo}" "${ref}" "${cutoff}"
        resolved_names+=("${name}")
        resolved_urls+=("github:${owner}/${repo}/${gh_rev}")
        printf '  %-14s %s\n' "${name}" "${gh_rev}"
        if [[ -n ${gh_epoch} ]]; then
          detail "${owner}/${repo}${ref:+ (${ref})} / commit $(epoch_to_day "${gh_epoch}") ($(age_days "${now}" "${gh_epoch}") 日前)"
        fi
        ;;
      skip)
        # type は lock なら locked.type、flake.nix なら flake ref の type
        # (follows だけの input には follows が入る)。どちらでも読めなければ「不明」。
        printf '  %-14s %s(%s なので対象外)%s\n' \
          "${name}" "${c_dim}" "${type:-不明}" "${c_reset}"
        ;;
    esac
  done <<<"${rows}"

  if [[ -z ${resolved_names[*]+x} ]]; then
    warn "${dir}: 遅延の対象になる input がありませんでした。"
    return 1
  fi
}

cmd_resolve() {
  local dir failed=0
  for dir in "${flake_dirs[@]}"; do
    resolve_dir "${dir}" || failed=1
  done
  return "${failed}"
}

# update が書いた lock で実際に入る閉包を、ツールを実行する前にスキャンする
# (closure-scan.sh / ADR 006)。lock を作る・上げる入口はここしか無いので、この
# 位置に差し込むことで「新しい pin を初めて実行する前に必ず照合が挟まる」を作る。
#
# whitelist (<flake>/vulnxscan-whitelist.csv) がある flake ではゲートとして呼ぶ
# (新規 findings があれば失敗)。無い flake では表示だけ (report)。初回の lock は
# まだ基準線が無いのが普通で、そこで止めるより全 findings を目に入れる方が
# 「実行する前に見る」という目的に合う。
#
# scanner の探し方は 2 段。チェックアウトから叩いたときは隣の closure-scan.sh、
# nix run (store の app) のときは flake-lock-age と同じパッケージが PATH へ入れる
# closure-scan。どちらも無ければ案内だけ出して通す (scan の強制は CI 側の仕事)。
auto_scan() {
  local dir=$1 scanner
  if [[ ${no_scan} -eq 1 ]]; then
    note "--no-scan なので更新後のスキャンを飛ばします。"
    return 0
  fi
  if [[ -x "${script_dir}/closure-scan.sh" ]]; then
    scanner="${script_dir}/closure-scan.sh"
  elif command -v closure-scan &>/dev/null; then
    scanner=closure-scan
  else
    warn "closure-scan が見つからないので更新後のスキャンを飛ばします。
入るものを実行する前に手で照合すること:
  nix run 'github:pollenjp/dotfiles?dir=nix#closure-scan' -- report ${dir}"
    return 0
  fi
  if [[ -f "${dir}/vulnxscan-whitelist.csv" ]]; then
    "${scanner}" scan "${dir}" || {
      warn "lock は更新済み。上の findings に対応してから使うこと
(pin を動かして直るか見るか、理由を書いて whitelist へ足すか)。"
      return 1
    }
  else
    "${scanner}" report "${dir}"
  fi
}

cmd_update() {
  local dir i args failed=0
  for dir in "${flake_dirs[@]}"; do
    # 1 つ落ちても残りは更新する (複数の flake をまとめて上げる用)。
    resolve_dir "${dir}" || {
      failed=1
      continue
    }
    # --override-input は flake.nix を書き換えずに lock の pin だけを差し替える。
    # `nix flake update` 経由なら lock へ書き込まれる (nix 2.34 で実測)。lock が
    # まだ無ければここで作られる (対象外の input は nix が普通に解決する)。
    # flake.nix 側は追跡先を指したままなので、素で `nix flake update` を叩くと
    # 先端へ飛ぶ。そのための保険が check (CI で回している)。
    #
    # flake.nix が git に追加されていないと nix 側が止まる (flake は追跡済み
    # ファイルしか見ない)。その旨は nix が git add を促す形で出すのでここでは見ない。
    args=()
    for ((i = 0; i < ${#resolved_names[@]}; i++)); do
      args+=("${resolved_names[i]}")
    done
    args+=(--flake "${dir}")
    for ((i = 0; i < ${#resolved_names[@]}; i++)); do
      args+=(--override-input "${resolved_names[i]}" "${resolved_urls[i]}")
    done
    printf '%s+ nix flake update %s%s\n' "${c_cyan}" "${args[*]}" "${c_reset}"
    nix flake update "${args[@]}"
    auto_scan "${dir}" || failed=1
  done
  return "${failed}"
}

cmd_check() {
  local dir lock rows now name type owner repo lastmod ref age failed=0 checked
  now=$(date -u +%s)
  for dir in "${flake_dirs[@]}"; do
    lock=$(lock_path_of "${dir}")
    rows=$(read_lock_inputs "${lock}")
    checked=0
    printf '%s==> %s の pin の古さ (下限 %s 日)%s\n' \
      "${c_cyan}" "${dir}" "${min_age_days}" "${c_reset}"
    if [[ ${min_age_days} -eq 0 ]]; then
      note '下限 0 なので常に通ります。'
    fi
    while IFS=$'\t' read -r name type owner repo lastmod ref; do
      [[ -n ${name} ]] || continue
      classify_input "${name}" "${type}" "${owner}" "${repo}" "${ref}"
      [[ ${input_kind} != skip ]] || continue
      checked=$((checked + 1))
      if [[ -z ${lastmod} || ${lastmod} == 0 ]]; then
        die "${lock} から ${name} の lastModified が読めませんでした。"
      fi
      age=$(age_days "${now}" "${lastmod}")
      if [[ ${age} -lt ${min_age_days} ]]; then
        printf '  %-14s %s (%s 日前)  %sNG%s\n' \
          "${name}" "$(epoch_to_day "${lastmod}")" "${age}" "${c_red}" "${c_reset}"
        failed=1
      else
        printf '  %-14s %s (%s 日前)  OK\n' \
          "${name}" "$(epoch_to_day "${lastmod}")" "${age}"
      fi
    done <<<"${rows}"
    if [[ ${checked} -eq 0 ]]; then
      warn "${dir}: 判定できる input がありませんでした (github 以外か follows だけ)。"
    fi
  done
  if [[ ${failed} -eq 1 ]]; then
    die "先端に近すぎる pin があります。
flake-lock-age.sh update で ${min_age_days} 日以上前の revision へ下げ直すこと。
意図して先端を入れた (緊急の CVE 修正など) 場合は、この失敗は意図どおりなので、
そのまま記録として残すか下限を下げて再実行する。"
  fi
}

case ${cmd} in
  resolve) cmd_resolve ;;
  update) cmd_update ;;
  check) cmd_check ;;
esac
