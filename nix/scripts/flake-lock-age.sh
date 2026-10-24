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
# ## 猶予の日数と例外 (release-age.nix。ADR 032)
#
# 日数と、期間付きの例外は設定のファイル (dotfiles では nix/release-age.nix) に書く。
# 設定は `--config` か、この script の隣の `../release-age.nix` (dotfiles のチェック
# アウトから叩いたとき)。どちらも無ければ (nix run で他の repo から呼んだとき) 7 日で、
# 例外は無い。日数は `--min-age-days` > `FLAKE_MIN_RELEASE_AGE_DAYS` > 設定 > 7。
#
# - **全体** (`exceptions.all`): date の日 (Asia/Tokyo) の終わりが猶予より新しければ、
#   nixpkgs (nixpkgs-unstable を追う input。nixpkgs-exceptions を除く) をその日の終わり
#   までの公開から選ぶ。ほかの github input は猶予のまま。check はその日の終わりまでの
#   pin を通す
# - **一部 (nixpkgs から)** (`exceptions.fromNixpkgs`): input の nixpkgs-exceptions を、
#   項目の最も新しい date の日の終わりまでの公開にする。それが nixpkgs (普段の pin) より
#   新しくなければ nixpkgs と同じ rev (取ってくるものを増やさない)。check は、その日の
#   終わりまでの pin と、nixpkgs と同じ rev を通す
# - **一部 (upstream から)** (`exceptions.fromUpstream`): flake.lock に関わらないので
#   ここでは読まない (home の overlay だけ。nix/lib/release-age.nix)
#
# 例外がもう何もしていないか (消し時) は、home の評価 (nix/lib/release-age.nix) が
# 警告に出す。ここは選ぶときの状態 (効いている・何もしない) を表示するだけ。
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
# `resolve` / `update` は、`--input <名前>` (くり返せる) でその input だけを選ぶ。
# 例外を足したときに普段の pin を動かさずに済む。
#
# input の一覧は flake.nix の `inputs` から読み、lock にあればその locked を使う。
# lock に無い input (flake.nix に足したばかり・flake.lock がまだ無い) も先端ではなく
# 決まりどおりに選ぶ。**最初の lock も update で作ること。** 先に
# `nix flake lock` を打つと一度先端へ pin されるので、遅延が最初から外れた lock を
# commit することになる。`check` は「今 pin されているもの」を測るので lock が要る。
#
# ディレクトリを省いたときの既定は、**この script の隣** (`<script>/../flake.nix`)
# があればそこ、無ければカレントディレクトリ。前者は dotfiles のチェックアウトから
# 直接叩く場合、後者は他のリポジトリから nix run で呼ぶ場合を想定している。
#
#   nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
#
# 緊急で CVE 修正を先端から入れたいときは、まず例外を考える。それでも全体を先端へ
# 上げるなら --min-age-days 0 で `update` し、`check` の CI が赤くなるのは意図どおり
# として扱う (nix/README.md 「遅延を外す」)。
#
# 今の時刻は FLAKE_LOCK_AGE_NOW (UNIX 秒) で差し替えられる (テスト用)。
#
# ## 依存
#
# bash 3.2 / coreutils / curl / nix。**jq は使わない** (jq は Nix が入れるものな
# ので初回 switch 前には無い)。JSON と設定は nix 自身に読ませる。

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

# 一部 (nixpkgs から) の例外の package を取る nixpkgs の input (nix/flake.nix)。
# 普段の pin は input の nixpkgs。
exceptions_input=nixpkgs-exceptions

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

# 止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは (引数の中の改行の後も) 字下げした
# 続きの行になる。setup.sh の手順 (flake-update) から走るときは、最後の「警告のまとめ」にも
# 同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '%s!! %s%s\n' "${c_yellow}" "${text//${nl}/${nl}   }" "${c_reset}" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
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
  --config FILE     猶予の日数と例外の設定 (既定: この script の隣の ../release-age.nix
                    があればそれ。無ければ 7 日で例外なし)
  --min-age-days N  下限日数 (環境変数 FLAKE_MIN_RELEASE_AGE_DAYS より、設定より先に効く)
  --input NAME      resolve / update でその input だけを選ぶ (くり返せる)
  --no-scan         update 後の閉包スキャン (closure-scan) を飛ばす
  -h, --help        この使い方を出す

ディレクトリを省くと、この script の隣 (<script>/../flake.nix) があればそこ、
無ければカレントディレクトリを対象にする。複数渡せば順に処理する。

flake.lock がまだ無い flake・lock に無い input でも resolve / update は通る
(最初の lock も update で作る)。先に nix flake lock を打つと一度先端へ pin
されるので使わないこと。
EOS
}

##########
# 引数   #
##########

cmd=""
flake_dirs=()
no_scan=0
config=""
cli_days=""
only_inputs=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)
      [[ $# -ge 2 ]] || die '--config には設定のファイルが要ります。'
      config=$2
      shift 2
      ;;
    --config=*)
      config=${1#*=}
      shift
      ;;
    --min-age-days)
      [[ $# -ge 2 ]] || die '--min-age-days には日数が要ります。'
      cli_days=$2
      shift 2
      ;;
    --min-age-days=*)
      cli_days=${1#*=}
      shift
      ;;
    --input)
      [[ $# -ge 2 ]] || die '--input には input の名前が要ります。'
      only_inputs+=("$2")
      shift 2
      ;;
    --input=*)
      only_inputs+=("${1#*=}")
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

# 今 (UNIX 秒)。テストは FLAKE_LOCK_AGE_NOW で差し替える。
now_epoch() {
  if [[ -n ${FLAKE_LOCK_AGE_NOW:-} ]]; then
    printf '%s\n' "${FLAKE_LOCK_AGE_NOW}"
  else
    date -u +%s
  fi
}

# YYYY-MM-DD の日 (Asia/Tokyo) の終わり (23:59:59 +09:00。夏時間は無い) の UNIX 秒を day_end へ入れる。
# 形が違えば止める。暦の計算は bash の算術でする (GNU と BSD の date の違いに寄らない)。
# 2026-02-30 のような無い日の確かめは、nix/lib/release-age.nix (flake の check) がする。
# 返り値ではなくグローバルへ置くのは、die でここから抜けたいため。$(...) で呼ぶと
# subshell になって exit が効かない。
day_end=""
day_end_of() {
  local y m d era yoe mp doy doe days
  if [[ ! $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    die "設定 (${config}) の date が YYYY-MM-DD ではありません: $1"
  fi
  y=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  # 1970-01-01 からの日数 (days from civil。3 月始まりの年で数える)
  if ((m <= 2)); then
    y=$((y - 1))
  fi
  era=$((y / 400))
  yoe=$((y - era * 400))
  mp=$(((m + 9) % 12))
  doy=$(((153 * mp + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  days=$((era * 146097 + doe - 719468))
  day_end=$((days * 86400 + 86400 - 1 - 9 * 3600))
}

##########
# 設定   #
##########

# 設定の中身を 1 行 1 件で出す。区切りはタブ。空の欄は - にする (read の区切りのタブは
# 空の欄を飛ばして詰めるため)。欄の型は nix/lib/release-age.nix が確かめるので、
# ここは無い欄を - にして読むだけ。
#
#   days    <日数>
#   all     <date> <reason>
#   nixpkgs <date> <packages (空白区切り)> <reason>
settings_rows() {
  nix eval --raw --impure --expr "
    let
      s = import \"$1\";
      e = s.exceptions or { };
      cell = v:
        let t = builtins.replaceStrings [ \"\t\" \"\n\" ] [ \" \" \" \" ] (toString v);
        in if t == \"\" then \"-\" else t;
      row = cols: builtins.concatStringsSep \"\t\" (map cell cols);
    in
    builtins.concatStringsSep \"\n\" (
      [ (row [ \"days\" (s.minimumReleaseAgeDays or \"\") ]) ]
      ++ map (i: row [ \"all\" (i.date or \"\") (i.reason or \"\") ]) (e.all or [ ])
      ++ map (i: row [
        \"nixpkgs\"
        (i.date or \"\")
        (builtins.concatStringsSep \" \" (i.packages or [ ]))
        (i.reason or \"\")
      ]) (e.fromNixpkgs or [ ])
    )
  "
}

settings_days=""
# 全体の例外 (date・その日の終わりの UNIX 秒・reason) と、一部 (nixpkgs から) の例外 (同じく + packages)
all_dates=()
all_ends=()
all_reasons=()
part_dates=()
part_ends=()
part_packages=()
part_reasons=()

read_settings() {
  local rows kind a b c
  if [[ -z ${config} ]]; then
    [[ -f "${script_dir}/../release-age.nix" ]] || return 0
    config="${script_dir}/../release-age.nix"
  fi
  [[ -f ${config} ]] || die "設定のファイルがありません: ${config}"
  # import は絶対パスしか受けない
  config="$(
    cd -- "$(dirname "${config}")" &>/dev/null
    pwd -P
  )/$(basename "${config}")"
  rows=$(settings_rows "${config}") || die "設定を読めませんでした: ${config}"
  while IFS=$'\t' read -r kind a b c; do
    case ${kind} in
      days)
        if [[ ${a} != - ]]; then
          settings_days=${a}
        fi
        ;;
      all)
        day_end_of "${a}"
        all_dates+=("${a}")
        all_ends+=("${day_end}")
        all_reasons+=("${b}")
        ;;
      nixpkgs)
        day_end_of "${a}"
        part_dates+=("${a}")
        part_ends+=("${day_end}")
        part_packages+=("${b}")
        part_reasons+=("${c}")
        ;;
    esac
  done <<<"${rows}"
}

read_settings

# 日数の出どころ: --min-age-days > FLAKE_MIN_RELEASE_AGE_DAYS (空は無いのと同じ。CI は
# workflow_dispatch 以外で空を渡してくる) > 設定 > 7。
if [[ -n ${cli_days} ]]; then
  min_age_days=${cli_days}
  days_from=--min-age-days
elif [[ -n ${FLAKE_MIN_RELEASE_AGE_DAYS:-} ]]; then
  min_age_days=${FLAKE_MIN_RELEASE_AGE_DAYS}
  days_from=FLAKE_MIN_RELEASE_AGE_DAYS
elif [[ -n ${settings_days} ]]; then
  min_age_days=${settings_days}
  days_from="設定 $(basename "${config}")"
else
  min_age_days=7
  days_from=既定
fi

case ${min_age_days} in
  '' | *[!0-9]*)
    die "下限日数は 0 以上の整数で指定すること (${days_from} の値: ${min_age_days})"
    ;;
esac
# 先頭 0 を 8 進数と解釈させない (10# を付けられない箇所で算術に使うため)。
min_age_days=$((10#${min_age_days}))

################
# input の一覧 #
################

# root の直下 input を 1 行 1 件で出す。区切りはタブで、空の欄は - (settings_rows と同じわけ)。
#
#   <名前> <type> <owner> <repo> <lastModified> <rev> <original.ref>
#
# $2 が 1 なら、名前は flake.nix の inputs から取り、lock にあればその locked を、無ければ
# flake.nix の url を使う (resolve / update。lock に無い input も先端を掴ませない)。0 なら
# lock だけを読む (check。今 pin されているものを測る)。lastModified は lock に無ければ 0。
#
# follows で他の input を指しているものは自分の locked ノードを持たない
# (root.inputs の値が文字列ではなく配列になる) ので落とす。flake.nix にしか無い
# follows だけの input は、type を follows にして下の classify_input で対象外へ落とす。
#
# url の文字列は builtins.parseFlakeRef に解かせる。github:owner/repo/ref?dir=...
# の細部を自前で切ると必ずずれるし、nix が実際に解くのと同じ結果が要る。
# flake の評価ではなく flake.nix の import なので、input の取得は起きず、
# flake.nix が git に追加されていなくても読める (追加は update の nix 側で要る)。
# `outputs` は関数だが遅延評価なので触らなければ問題にならない。
input_rows() {
  local dir=$1 with_nix=$2 nix_bool=false
  if [[ ${with_nix} == 1 ]]; then
    nix_bool=true
  fi
  nix eval --raw --impure --expr "
    let
      lockPath = \"${dir}/flake.lock\";
      lock = if builtins.pathExists lockPath then builtins.fromJSON (builtins.readFile lockPath) else null;
      root = if lock == null then { } else lock.nodes.\${lock.root}.inputs or { };
      specs = if ${nix_bool} then (import \"${dir}/flake.nix\").inputs or { } else root;
      cell = v: if v == \"\" then \"-\" else v;
      row = cols: builtins.concatStringsSep \"\t\" (map cell cols);
      fromLock = n:
        let
          node = lock.nodes.\${root.\${n}};
          l = node.locked or { };
          o = node.original or { };
        in
        row [ n (l.type or \"\") (l.owner or \"\") (l.repo or \"\") (toString (l.lastModified or 0)) (l.rev or \"\") (o.ref or \"\") ];
      fromNix = n:
        let
          spec = specs.\${n};
          # 文字列と url は flake ref として解く。どちらでもなければ type などを
          # 直に書いた形と見る。
          r =
            if builtins.isString spec then builtins.parseFlakeRef spec
            else if spec ? url then builtins.parseFlakeRef spec.url
            else if spec ? type then spec
            else { type = if spec ? follows then \"follows\" else \"\"; };
        in
        row [ n (r.type or \"\") (r.owner or \"\") (r.repo or \"\") \"0\" \"\" (r.ref or \"\") ];
      line = n:
        if root ? \${n} then (if builtins.isString root.\${n} then fromLock n else null)
        else fromNix n;
    in
    builtins.concatStringsSep \"\n\" (builtins.filter (x: x != null) (map line (builtins.attrNames specs)))
  "
}

# 読んだ行の - を空へ戻す (変数の名前を渡す)。
undash() {
  local v
  for v in "$@"; do
    if [[ ${!v} == - ]]; then
      printf -v "${v}" '%s' ''
    fi
  done
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

# input_rows を呼んで、読めなかったときにその場で止める。
# `< <(...)` で while へ流すと nix 側の失敗を取りこぼす (while は 0 で終わる)
# ので、一度変数へ受けてから流す。
read_inputs() {
  local abs rows
  abs=$(abs_flake_dir "$1") || return 1
  rows=$(input_rows "${abs}" "$2") || die "flake の input を読めませんでした: $1"
  printf '%s\n' "${rows}"
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

# 公開の一覧 (古い順) と、調べた公開時刻・rev (同じ添字。まだ調べていなければ空、
# 公開時刻が取れなかったものは -)。1 回の実行で 1 度だけ読み、選ぶたびに使い回す
# (nixpkgs と nixpkgs-exceptions、複数の flake を続けて選んでも同じ HEAD を投げない)。
# 公開の新旧は添字で比べる。
releases=()
release_epochs=()
release_revs=()
releases_loaded=0

load_series() {
  local list rel
  list=$(list_series "$1") || die "チャンネル公開の一覧を取れませんでした ($1)。"
  while IFS= read -r rel; do
    [[ -n ${rel} ]] || continue
    releases+=("${rel}")
    release_epochs+=("")
    release_revs+=("")
  done <<<"${list}"
}

# 系列が分岐した直後は新しい系列に十分古い公開が無いので、1 つ前の系列も先に読む。
load_releases() {
  local series prev
  [[ ${releases_loaded} -eq 0 ]] || return 0
  series=$(series_of "$(current_release)")
  [[ ${series} != pre ]] || die "チャンネル ${channel} の現在の公開名が取れませんでした。"
  if prev=$(previous_series "${series}"); then
    load_series "${prev}"
  fi
  load_series "${series}"
  [[ ${#releases[@]} -gt 0 ]] || die "チャンネル公開の一覧が空でした (${series})。"
  releases_loaded=1
}

# cutoff 以前に公開された最新の公開の添字を picked へ入れる。見つからなければ 1 を返す。
picked=""
# 走査上限に当たって打ち切ったか。見つからなかった理由を分けて報告するため。
hit_candidate_cap=0
pick_release() {
  local cutoff=$1 i seen=0
  load_releases
  hit_candidate_cap=0
  # 新しい側から順に見て、最初に cutoff を満たしたものを採る。
  for ((i = ${#releases[@]} - 1; i >= 0; i--)); do
    seen=$((seen + 1))
    if [[ ${seen} -gt ${max_candidates} ]]; then
      hit_candidate_cap=1
      break
    fi
    if [[ -z ${release_epochs[i]} ]]; then
      release_epochs[i]=$(release_published_epoch "${releases[i]}") || release_epochs[i]=-
    fi
    [[ ${release_epochs[i]} != - ]] || continue
    if [[ ${release_epochs[i]} -le ${cutoff} ]]; then
      picked=${i}
      return 0
    fi
  done
  return 1
}

die_not_found() {
  if [[ ${hit_candidate_cap} -eq 1 ]]; then
    die "$1 以前のチャンネル公開に、新しい側から ${max_candidates} 件
遡っても届きませんでした。日数の設定が大きすぎます (公開は 1〜3 日おき)。"
  fi
  die "$1 以前のチャンネル公開が見つかりませんでした。"
}

# 添字の公開の rev を found_rev へ入れる (git-revision の本文。release_revs に貯める)。
found_rev=""
release_rev_at() {
  local i=$1
  if [[ -z ${release_revs[i]} ]]; then
    release_revs[i]=$(curl -fsS "${releases_url}/${releases[i]}/git-revision" | tr -d '\r\n') \
      || die "${releases[i]} の git-revision を取れませんでした。"
  fi
  found_rev=${release_revs[i]}
}

# rev の公開を名前 (末尾は rev の頭 12 桁) で探し、添字を found_index へ入れる。無ければ空。
found_index=""
release_index_of_rev() {
  local short=${1:0:12} i
  load_releases
  found_index=""
  for ((i = ${#releases[@]} - 1; i >= 0; i--)); do
    if [[ ${releases[i]} == *".${short}" ]]; then
      found_index=${i}
      return 0
    fi
  done
}

# 表示用: 添字の公開の「名前 / 公開 YYYY-MM-DD (n 日前)」
release_label() {
  printf '%s / 公開 %s (%s 日前)' "${releases[$1]}" \
    "$(epoch_to_day "${release_epochs[$1]}")" "$(age_days "$2" "${release_epochs[$1]}")"
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

# --input で選んだか (指定が無ければ全部)。
selected() {
  local n
  [[ -n ${only_inputs[*]+x} ]] || return 0
  for n in "${only_inputs[@]}"; do
    if [[ ${n} == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# resolve_dir が埋める。update はこれをそのまま --override-input へ渡す。
# URL の owner/repo は読んだ側 (flake.lock の locked、無ければ flake.nix の inputs)
# から取る。追跡先を勝手に変えないため。
resolved_names=()
resolved_urls=()

# 選んだ input を resolved_* へ足す。
resolved() {
  resolved_names+=("$1")
  resolved_urls+=("github:$2/$3/$4")
}

# nixpkgs-exceptions を選ぶ。$1: 比べる相手 (普段の pin) の公開の添字 (分からなければ空)、
# $2: その rev、$3: 今、残り: input の owner と repo。
resolve_exceptions_input() {
  local ref_index=$1 ref_rev=$2 now=$3 owner=$4 repo=$5 i end x_index="" x_end=""
  local states=()
  # 項目ごとに、その日の終わりまでの最新の公開が普段の pin より新しいか
  for ((i = 0; i < ${#part_dates[@]}; i++)); do
    end=${part_ends[i]}
    if [[ ${end} -gt ${now} ]]; then
      end=${now}
    fi
    if pick_release "${end}" && [[ -z ${ref_index} || ${picked} -gt ${ref_index} ]]; then
      states+=("効いている")
      if [[ -z ${x_index} || ${picked} -gt ${x_index} ]]; then
        x_index=${picked}
        x_end=${part_dates[i]}
      fi
    else
      states+=("何もしない (その日の終わりまでの公開が普段の pin より新しくない。消してよい)")
    fi
  done
  if [[ -n ${x_index} ]]; then
    release_rev_at "${x_index}"
    resolved "${exceptions_input}" "${owner}" "${repo}" "${found_rev}"
    printf '  %-14s %s\n' "${exceptions_input}" "${found_rev}"
    detail "$(release_label "${x_index}" "${now}") / 一部の例外の ${x_end} の終わりまで"
  else
    resolved "${exceptions_input}" "${owner}" "${repo}" "${ref_rev}"
    printf '  %-14s %s\n' "${exceptions_input}" "${ref_rev}"
    detail "nixpkgs と同じ rev (効いている一部の例外が無い)"
  fi
  for ((i = 0; i < ${#part_dates[@]}; i++)); do
    note "例外 (一部・nixpkgs から) ${part_packages[i]} ${part_dates[i]}: ${states[i]} (理由: ${part_reasons[i]})"
  done
}

resolve_dir() {
  local dir=$1 now base cutoff rows i n found
  local name type owner repo lastmod rev ref
  local main_index="" main_rev="" lock_main_rev="" exc_owner="" exc_repo="" any_channel=0
  # die は $(...) の中では subshell を抜けるだけなので、呼び側で失敗を見る。
  rows=$(read_inputs "${dir}" 1) || return 1
  now=$(now_epoch)
  base=$((now - min_age_days * 86400))

  # 全体の例外: date の日の終わりが猶予より新しければ、nixpkgs の上限をそこまで上げる
  # (今より先へは上げない)。
  cutoff=${base}
  for ((i = 0; i < ${#all_dates[@]}; i++)); do
    if [[ ${all_ends[i]} -gt ${cutoff} ]]; then
      cutoff=${all_ends[i]}
    fi
  done
  if [[ ${cutoff} -gt ${now} ]]; then
    cutoff=${now}
  fi

  resolved_names=()
  resolved_urls=()

  printf '%s==> %s (下限 %s 日。%s)%s\n' "${c_cyan}" "${dir}" "${min_age_days}" "${days_from}" "${c_reset}"
  if [[ ! -f ${dir}/flake.lock ]]; then
    note 'flake.lock がまだ無いので flake.nix の inputs から決めます。'
  fi

  # --input に渡した名前が、この flake にあるか
  if [[ -n ${only_inputs[*]+x} ]]; then
    for n in "${only_inputs[@]}"; do
      found=0
      while IFS=$'\t' read -r name _; do
        if [[ ${name} == "${n}" ]]; then
          found=1
        fi
      done <<<"${rows}"
      [[ ${found} -eq 1 ]] || die "input '${n}' が ${dir} の flake にありません (--input)。"
    done
  fi

  while IFS=$'\t' read -r name type owner repo lastmod rev ref; do
    [[ -n ${name} ]] || continue
    undash type owner repo rev ref
    if [[ ${name} == nixpkgs ]]; then
      lock_main_rev=${rev}
    fi
    selected "${name}" || continue
    classify_input "${name}" "${type}" "${owner}" "${repo}" "${ref}"
    case ${input_kind} in
      channel)
        if [[ ${name} == "${exceptions_input}" ]]; then
          # 普段の pin が決まってから選ぶ (下)
          exc_owner=${owner}
          exc_repo=${repo}
          continue
        fi
        any_channel=1
        pick_release "${cutoff}" || die_not_found "$(epoch_to_day "${cutoff}")"
        release_rev_at "${picked}"
        resolved "${name}" "${owner}" "${repo}" "${found_rev}"
        if [[ ${name} == nixpkgs ]]; then
          main_index=${picked}
          main_rev=${found_rev}
        fi
        printf '  %-14s %s\n' "${name}" "${found_rev}"
        detail "$(release_label "${picked}" "${now}")"
        ;;
      commit)
        pick_github_commit "${name}" "${owner}" "${repo}" "${ref}" "${base}"
        resolved "${name}" "${owner}" "${repo}" "${gh_rev}"
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

  if [[ ${any_channel} -eq 1 ]]; then
    for ((i = 0; i < ${#all_dates[@]}; i++)); do
      if [[ ${all_ends[i]} -gt ${base} ]]; then
        note "例外 (全体) ${all_dates[i]}: 効いている。nixpkgs を ${all_dates[i]} の終わりまでの公開から選ぶ (理由: ${all_reasons[i]})"
      else
        note "例外 (全体) ${all_dates[i]}: 何もしない (猶予 ${min_age_days} 日の方が新しい。消してよい) (理由: ${all_reasons[i]})"
      fi
    done
  fi

  # 一部 (nixpkgs から) の例外の pin。比べる相手は、今選んだ nixpkgs か、選んでいなければ lock の nixpkgs
  if [[ -n ${exc_owner} ]]; then
    if [[ -z ${main_rev} ]]; then
      [[ -n ${lock_main_rev} ]] || die "${exceptions_input} を選ぶには nixpkgs の pin が要ります。nixpkgs も一緒に選ぶこと。"
      main_rev=${lock_main_rev}
      release_index_of_rev "${main_rev}"
      main_index=${found_index}
      if [[ -z ${main_index} ]]; then
        note "lock の nixpkgs (${main_rev}) がチャンネルの公開に見つからないので、一部の例外の公開と比べずに選びます。"
      fi
    fi
    resolve_exceptions_input "${main_index}" "${main_rev}" "${now}" "${exc_owner}" "${exc_repo}"
  fi

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

# 猶予を満たさない pin を、例外が通すか。通すなら、そのわけを allowed_by へ入れる。
# $1: input の名前、$2: lastModified、$3: rev、$4: nixpkgs の rev。
allowed_by=""
allowed() {
  local name=$1 lastmod=$2 rev=$3 main_rev=$4 i
  allowed_by=""
  if [[ ${name} == "${exceptions_input}" ]]; then
    if [[ -n ${rev} && ${rev} == "${main_rev}" ]]; then
      allowed_by="nixpkgs と同じ rev"
      return 0
    fi
    for ((i = 0; i < ${#part_dates[@]}; i++)); do
      if [[ ${lastmod} -le ${part_ends[i]} ]]; then
        allowed_by="例外 (一部・nixpkgs から) ${part_dates[i]}"
        return 0
      fi
    done
    return 1
  fi
  for ((i = 0; i < ${#all_dates[@]}; i++)); do
    if [[ ${lastmod} -le ${all_ends[i]} ]]; then
      allowed_by="例外 (全体) ${all_dates[i]}"
      return 0
    fi
  done
  return 1
}

cmd_check() {
  local dir rows now name type owner repo lastmod rev ref age failed=0 checked main_rev
  now=$(now_epoch)
  for dir in "${flake_dirs[@]}"; do
    lock_path_of "${dir}" >/dev/null
    rows=$(read_inputs "${dir}" 0)
    checked=0
    main_rev=""
    while IFS=$'\t' read -r name _ _ _ _ rev _; do
      if [[ ${name} == nixpkgs ]]; then
        main_rev=${rev}
      fi
    done <<<"${rows}"
    printf '%s==> %s の pin の古さ (下限 %s 日。%s)%s\n' \
      "${c_cyan}" "${dir}" "${min_age_days}" "${days_from}" "${c_reset}"
    if [[ ${min_age_days} -eq 0 ]]; then
      note '下限 0 なので常に通ります。'
    fi
    while IFS=$'\t' read -r name type owner repo lastmod rev ref; do
      [[ -n ${name} ]] || continue
      undash type owner repo rev ref
      classify_input "${name}" "${type}" "${owner}" "${repo}" "${ref}"
      [[ ${input_kind} != skip ]] || continue
      checked=$((checked + 1))
      if [[ -z ${lastmod} || ${lastmod} == 0 ]]; then
        die "${dir}/flake.lock から ${name} の lastModified が読めませんでした。"
      fi
      age=$(age_days "${now}" "${lastmod}")
      if [[ ${age} -ge ${min_age_days} ]]; then
        printf '  %-14s %s (%s 日前)  OK\n' \
          "${name}" "$(epoch_to_day "${lastmod}")" "${age}"
      elif [[ ${input_kind} == channel ]] && allowed "${name}" "${lastmod}" "${rev}" "${main_rev}"; then
        printf '  %-14s %s (%s 日前)  OK (%s)\n' \
          "${name}" "$(epoch_to_day "${lastmod}")" "${age}" "${allowed_by}"
      else
        printf '  %-14s %s (%s 日前)  %sNG%s\n' \
          "${name}" "$(epoch_to_day "${lastmod}")" "${age}" "${c_red}" "${c_reset}"
        failed=1
      fi
    done <<<"${rows}"
    if [[ ${checked} -eq 0 ]]; then
      warn "${dir}: 判定できる input がありませんでした (github 以外か follows だけ)。"
    fi
  done
  if [[ ${failed} -eq 1 ]]; then
    die "先端に近すぎる pin があります。
flake-lock-age.sh update で ${min_age_days} 日以上前の revision へ下げ直すこと。
セキュリティパッチのために新しい pin が要るなら、release-age.nix に例外を足す
(nix/README.md「猶予の例外」)。意図して先端を入れた (緊急の CVE 修正など) 場合は、
この失敗は意図どおりなので、そのまま記録として残すか下限を下げて再実行する。"
  fi
}

case ${cmd} in
  resolve) cmd_resolve ;;
  update) cmd_update ;;
  check) cmd_check ;;
esac
