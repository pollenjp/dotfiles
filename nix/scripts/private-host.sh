#!/usr/bin/env bash
# shellcheck shell=bash
#
# この PC を dotfiles-private に登録するときの名前と、dotfiles-private の clone の場所を決める (ADR 026)。
#
# ## 何のために
#
# 実機のホストの定義と値は、private な dotfiles-private の nix/hosts/<user>@<hostname>.nix に 1 PC 1 ファイルで置く。
# ローカル flake (~/dotfiles/flake.nix) の雛形がその nix/ を path: の入力に取り、setup.sh は --host が無ければ
# この PC の名前のファイルのホストを選ぶ。名前と clone の場所の決め方は、この script だけが持つ
# (setup.sh・setup-local-flake.sh・local-flake-migrate.sh はこれを呼ぶ。登録の skill pjp-dotfiles-register-host も)。
# この PC の system と、WSL のホスト側 Windows のユーザー名の引き方も、この script だけが持つ (inspect と draft が使い、
# setup-local-flake.sh --initial が初期用のホスト initial を書くときに system・windows-user で呼ぶ)。
#
#   名前        <user>@<短い hostname>。user は $USER (無ければ id -un)。hostname は macOS ならネットワークで変わらない
#               LocalHostName (scutil)、ほかは uname -n の最初の . まで (hostname -s と同じ)。英数字と . _ - だけ
#   clone       $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
#               ~/ghq/github.com/pollenjp/dotfiles-private (bootstrap-dotfiles-private.sh などの private_dir() と同じ)
#   入力の先    clone の nix/ が directory ならそれ、無ければ本体の空の stub (nix/private-stub)。雛形は clone の無い
#               マシンでも入力の行の形を変えずに書く
#   system      uname から <arch>-linux・<arch>-darwin (x86_64・aarch64)
#   Windows のユーザー名
#               WSL (WSL_DISTRO_NAME があるか、/proc/version に microsoft がある) のときだけ、pwsh.exe → powershell.exe の
#               $env:USERNAME (出力の文字コードを UTF-8 にしてから引く。日本語の名前が CP932 で化けないように)。CR と末尾の
#               空白を落とす。/mnt/c/Users/<名前> にあるかは呼ぶ側が確かめる。テストは DOTFILES_PROC_VERSION で
#               /proc/version の場所を差し替える (ふだんは空)
#
# name・dir・input-dir・system・windows-user は bash と uname (windows-user は WSL の interop) だけで動く (setup.sh と
# setup-local-flake.sh は Nix を入れる前にも呼ぶ。macOS の bash 3.2 でも動く書き方)。
#
# ## 登録の決まった処理 (inspect・draft・compare)
#
# この PC を登録する手順 (skill pjp-dotfiles-register-host) のうち、決まった処理を持つ。判断と確認の取り方は skill。
#
#   inspect   この PC を調べる (名前・WSL・clone と登録と shared/ の module・ローカル flake の手で足したホストと local
#             (前の雛形)・setup が選ぶホスト・今の世代と outPath が一致するホスト = 元にするホストの候補)
#   draft     元にするホスト (ローカル flake で評価した値。前の雛形なら local も当たる) の options.dotfiles から、
#             nix/hosts/<名前>.nix の下書きを描く (nix/lib/host-draft.nix。dotfiles の option の外の local の行は、描かずに
#             頭のコメントで知らせる)
#   compare   旧い形 (ローカル flake の <元のホスト>。前の雛形なら local が当たる) と新しい形 (dotfiles-private の <名前>。
#             ローカル flake の値は当たらない) を、同じ本体・同じ lock で評価して drvPath を比べる。同じなら、この登録で
#             世代の中身は変わらない
#
# dotfiles-private の nix/shared/*.nix (登録した全ホストに足す module。ADR 030) は、ホストのファイルの外の値なので、登録の
# 判定から外す。compare は shared/ に module があれば新しい形を shared/ を外しても評価し、それが旧い形と同じなら
# 「同じ (shared/ の値だけ違う)」として 0 を返し、shared/ が足す値は別に出す。元のホストが dotfiles-private に登録した
# ホスト (値を直すとき) なら、その元のホストにもローカル flake の読む shared/ が当たっているので、draft と compare の
# 旧い形は shared/ を外して評価する (下書きに shared/ の値を描かない・ホストのファイルどうしで比べる)。このとき compare は、
# clone と作業ツリーの shared/ が同じかをファイルで比べて出す (同じなら、shared/ の値はこの登録で動かない)。
#
# 評価はローカル flake の写しで行い、ユーザーの ~/dotfiles (flake.nix と flake.lock) にも dotfiles-private にも書かない
# (shared/ を外すのも、dotfiles-private の nix/ の写しで行う)。
#
# ## ホストの要約 (summary・summaries)
#
# ホストの設定グループ・道具の on/off と、その値がどこで決まったか (dotfiles-private の docs/adr/057_host_setting_groups_*・109_host_groups_minimum_all_*。
# 図の HTML にしたのは docs/adr/093_host_summary_html_*)。中身は nix/lib/host-summary/ (mkHome が組み立てたホストに足す
# hostSummary と、flake の lib.hostSummaryFiles) で、ここは評価して出す・書くだけ。
#
#   summary     1 ホストの要約を stdout に出す (既定は setup が --host なしで選ぶホスト。ローカル flake の tmp でも)。ローカル flake の
#               写しで評価する (--nix-dir を渡したときだけ写しの本体を替える)。--out <dir> なら、そのホストのページ (md と HTML 版。
#               <dir>/nix/<ホスト>.md・<dir>/nix/html/<ホスト>.html) を書く (登録しない PC でもブラウザで図を見られる)
#   summaries   dotfiles-private の作業ツリーの nix/hosts/*.nix と win/hosts/*.toml の全ホストを、compare の新しい形と同じく
#               privateHosts (と windowsHosts) だけの flake で評価し、docs/hosts/ にページを書く (入口の README.md と html/hosts.html、
#               ホストごとの nix/<ホスト>.md・win/<ホスト>.md と、それぞれの html/<ホスト>.html)。作らなくなったファイル
#               (ホストのファイルが無くなったページ) は消す。--check は書かずに、古い・足りない・余るファイルを出して 1。
#               作業ツリーに書くのは docs/hosts/ の中だけ (docs/hosts/ は全部この生成物。手で書いたファイルを置かない)
#
# docs/hosts/ の md は、dotfiles-private の docs/ を Notion に写す道具 (claude-skills の pjp-docs-to-notion) がページを作ると、
# h1 の下 (3 行目) に「📝 [Notion で開く](https://app.notion.com/p/…)」の行と空行を足す。summaries はその行を残して書き直し、
# --check と setup.sh はその行を外して比べる (行の有る無しでは古いと言わない)。
#
# 並びは毎回同じ (要約は日時・store のパス・dotfiles の版を持たない) なので、同じ本体とホストのファイルなら出し直しても差が
# 出ない。setup.sh も、この PC のホストのページ (docs/hosts/nix/<ホスト>.md と HTML 版) を同じ hostSummary.pages で作り直して
# 比べる (古ければ警告のまとめに出す)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
この PC を dotfiles-private に登録するときの名前と、dotfiles-private の clone の場所を決める。

使い方:
  private-host.sh name
      この PC のホストの名前 (<user>@<短い hostname>) を出す。決められない・使えない文字を含むなら 1
  private-host.sh dir
      dotfiles-private の clone の場所を出す ($DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
      ~/ghq/github.com/pollenjp/dotfiles-private)
  private-host.sh input-dir [--nix-dir <本体の nix>]
      ローカル flake の雛形が dotfiles-private の入力に書く場所を出す (clone の nix/ が無ければ <本体の nix>/private-stub。
      --nix-dir の既定はこの script の repo の nix/)
  private-host.sh system
      この PC の system (x86_64-linux・aarch64-linux・aarch64-darwin など) を出す
  private-host.sh windows-user
      WSL のホスト側 Windows のユーザー名 (pwsh.exe → powershell.exe の $env:USERNAME) を出す。WSL でない・引けないなら 1
  private-host.sh is-wsl
      WSL なら何も出さずに 0、WSL でなければ理由を出して 1
  private-host.sh inspect [--flake <dir>]
      この PC を調べる: 名前・system・WSL (Windows のユーザー名)・clone と登録と shared/ の module (登録した全ホストに
      足す)・ローカル flake (雛形の版・入力・手で足したホスト・前の雛形なら local の行)・setup が --host なしで選ぶ
      ホスト (決まらなければそう出す)・今の世代と outPath が一致するホスト
  private-host.sh draft --base <ホスト> [--flake <dir>] [--name <名前>] [--nix-dir <本体の nix>] [--out <ファイル> [--force]]
      元にするホスト (前の雛形なら + local) から nix/hosts/<名前>.nix の下書きを描く。評価する本体は compare と同じ (--nix-dir。既定は
      この script の repo の nix/)。元のホストが dotfiles-private に登録したホストなら、ローカル flake の読む shared/ を
      外して描く (shared/ の値はホストのファイルに書かない)。--out が無ければ stdout。在る --out は --force が無いと
      書かない (2)。元のホストを評価できなければ 3
  private-host.sh compare --base <ホスト> --private <dotfiles-private の作業ツリー> [--name <名前>] [--flake <dir>]
                          [--nix-dir <本体の nix>] [--out <作業場所>]
      旧い形 (ローカル flake の <ホスト>) と新しい形 (<作業ツリー>/nix/hosts/<名前>.nix) を同じ本体 (--nix-dir。既定は
      この script の repo の nix/)・同じ lock で評価し、drvPath を比べる。<作業ツリー>/nix/shared/ に module があれば、
      新しい形を shared/ を外しても評価し、ホストのファイルの違いと shared/ が足す値を分けて出す (元のホストが
      dotfiles-private に登録したホストなら、旧い形からもローカル flake の読む shared/ を外し、clone と作業ツリーの
      shared/ が同じかを出す)。--out は作業ツリーの nix/・ローカル flake・その dotfiles-private の nix/ の外に置く。
      0 = 同じ (shared/ を外すと同じ = shared/ の値だけ違うときも)、1 = 違う (config.dotfiles の違いを出す)、
      2 = 使い方の誤り・登録のファイルが無い、3 = 旧い形が評価できない、4 = 新しい形 (shared/ を足した形) が評価できない
  private-host.sh summary [--host <ホスト>] [--flake <dir>] [--nix-dir <本体の nix>] [--out <dir>]
      ホストの要約 (設定グループ・道具の on/off と、その値がどこで決まったか) を出す。既定のホストは setup が --host なしで
      選ぶもの (決まらなければ 2)。ローカル flake の写しで評価し、--nix-dir を渡せば写しの本体をそこに替える。--out なら、
      そのホストのページ (dotfiles-private の docs/hosts/ に置くのと同じ md と HTML 版) を <dir>/nix/ に書く (<dir> は無い場所。
      在れば 2)。ホストを評価できなければ 3
  private-host.sh summaries --private <dotfiles-private の作業ツリー> [--nix-dir <本体の nix>] [--check]
      作業ツリーの nix/hosts/*.nix と win/hosts/*.toml の全ホストの要約を、docs/hosts/ に書く (入口の README.md と html/hosts.html・
      nix/<ホスト>.md・win/<ホスト>.md と、それぞれの html/<ホスト>.html。本体は --nix-dir。既定はこの script の repo の nix/)。
      作らなくなったファイルは消す。md の 3 行目の「📝 [Notion で開く](…)」の行 (Notion に写す道具が書く) は残す。--check は書かずに、
      違うファイルを出して 1 (同じなら 0。その行の有る無しは違いに数えない)。2 = 使い方の誤り、3 = 評価できない
  private-host.sh -h, --help
      これ

  --flake の既定は ${DOTFILES_LOCAL_DIR:-~/dotfiles}。--name の既定はこの PC の名前 (name)。
  ユーザーの ~/dotfiles と dotfiles-private には書かない (評価は写しで行う。draft が書くのは --out だけ)。
EOS
}

die() {
  printf '!! %s\n' "$*" >&2
  exit 2
}

# $0 が symlink 経由でも実体の場所を返す (setup-local-flake.sh と同じ。macOS の readlink には -f が無い)。
resolve_dir() {
  local src=$1 dir
  while [[ -L ${src} ]]; do
    dir=$(
      cd -P -- "$(dirname -- "${src}")" &>/dev/null
      pwd
    )
    src=$(readlink -- "${src}")
    case ${src} in
      /*) ;;
      *) src="${dir}/${src}" ;;
    esac
  done
  cd -P -- "$(dirname -- "${src}")" &>/dev/null
  pwd
}

script_dir=$(resolve_dir "$0")
nix_dir=$(dirname "${script_dir}")

# dotfiles-private の clone の場所。bootstrap-dotfiles-private.sh などと同じ本文 (nix/tests/private-host.test.sh が見る)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

# この PC の短い hostname。macOS は LocalHostName (scutil。ネットワークで変わらない)、ほかと scutil が使えないときは
# uname -n の最初の . まで
short_hostname() {
  local h=""
  if [[ $(uname -s) == Darwin ]] && command -v scutil &>/dev/null; then
    h=$(scutil --get LocalHostName 2>/dev/null) || h=""
  fi
  if [[ -z ${h} ]]; then
    h=$(uname -n 2>/dev/null) || h=""
  fi
  printf '%s' "${h%%.*}"
}

# この PC のホストの名前 (<user>@<短い hostname>)。決められない・英数字と . _ - の外の文字を含むなら 1
this_host_name() {
  local user h
  user=${USER:-$(id -un 2>/dev/null || true)}
  h=$(short_hostname)
  if [[ -z ${user} || -z ${h} ]]; then
    printf '!! この PC のホストの名前を決められません (user: %s / hostname: %s)。\n' "${user:-不明}" "${h:-不明}" >&2
    return 1
  fi
  if [[ ! ${user}@${h} =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]]; then
    printf '!! この PC のホストの名前 (%s) に、ファイル名に使えない文字があります (英数字と . _ - だけにする)。\n' "${user}@${h}" >&2
    return 1
  fi
  printf '%s\n' "${user}@${h}"
}

cmd_input_dir() {
  local nd=${nix_dir} clone
  while [[ $# -gt 0 ]]; do
    case $1 in
      --nix-dir)
        [[ $# -ge 2 ]] || die "--nix-dir にディレクトリを渡してください"
        nd=${2%/}
        shift
        ;;
      *) die "input-dir の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  clone=$(private_dir)
  if [[ -d ${clone}/nix ]]; then
    printf '%s\n' "${clone}/nix"
  else
    printf '%s\n' "${nd}/private-stub"
  fi
}

############################################
# 登録の決まった処理 (inspect・draft・compare) #
############################################

self="${script_dir}/private-host.sh"
default_flake_dir=${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}

# 一時ファイルの置き場は使うときに作る (name・dir・input-dir は mktemp も要らない)。$(...) の中から初めて呼ぶと、
# 作った場所が親に伝わらず消えずに残るので、使うコマンドの頭で (親のシェルで) 呼ぶ
tmp=""
trap '[[ -z ${tmp} ]] || rm -rf "${tmp}"' EXIT
need_tmp() {
  [[ -n ${tmp} ]] || tmp=$(mktemp -d "${TMPDIR:-/tmp}/private-host.XXXXXX")
}

need_nix() {
  command -v nix &>/dev/null || die "nix がありません。"
}

# ホストの名前として使えるか (式やファイル名に埋めるので、英数字と . _ @ - だけ)
check_host() {
  [[ $1 =~ ^[A-Za-z0-9._@-]+$ ]] || die "ホストの名前に使えない文字があります: $1 (英数字と . _ @ - だけ)"
}

# Nix の文字列に埋めるパスとして使えるか ("・\・$ を含まない)
check_path() {
  case $1 in
    *[\"\\\$]*) die "パスに \"・\\・\$ を含むものは扱えません: $1" ;;
  esac
}

# まだ無いかもしれないパス ($1) の絶対パス。在る祖先を cd -P で解き、無い部分を後ろに足す (作らずに置き場所を確かめるため)
abs_path() {
  local p=$1 rest=""
  while [[ ! -d ${p} ]]; do
    rest="/${p##*/}${rest}"
    p=$(dirname -- "${p}")
  done
  printf '%s%s' "$(cd -P -- "${p}" && pwd)" "${rest}"
}

# この PC の system (x86_64-linux など。uname から)
this_system() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  case ${arch} in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
  esac
  case ${os} in
    Darwin) printf '%s-darwin' "${arch}" ;;
    *) printf '%s-linux' "${arch}" ;;
  esac
}

# WSL か。WSL_DISTRO_NAME があるか、/proc/version に microsoft がある。テストは DOTFILES_PROC_VERSION で /proc/version の
# 場所を差し替える (WSL の上でテストを流しても、手元の /proc/version を見ないように)
is_wsl() {
  [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft "${DOTFILES_PROC_VERSION:-/proc/version}" 2>/dev/null
}

# WSL のホスト側 Windows のユーザー名 (mkHome の wsl.windowsUserName)。調べられなければ 1。
# 出力の文字コードを UTF-8 にしてから引く (既定のままだと、日本語の名前が CP932 で届いて化ける)。CR と末尾の空白を落とす
windows_user() {
  local exe u
  for exe in pwsh.exe powershell.exe; do
    command -v "${exe}" &>/dev/null || continue
    # shellcheck disable=SC2016 # PowerShell の変数をそのまま渡す
    u=$("${exe}" -NoProfile -Command '[Console]::OutputEncoding = [Text.Encoding]::UTF8; $env:USERNAME' 2>/dev/null </dev/null) || continue
    u=${u//$'\r'/}
    u=${u%%$'\n'*}
    # 出力の文字コードに BOM が付いていたら落とす ([Text.Encoding]::UTF8 は BOM 付き。付けるかどうかは PowerShell の版による)
    u=${u#$'\xef\xbb\xbf'}
    while [[ ${u} == *[[:space:]] ]]; do
      u=${u%[[:space:]]}
    done
    if [[ -n ${u} ]]; then
      printf '%s' "${u}"
      return 0
    fi
  done
  return 1
}

# 今の home-manager の世代 (profile の指す先の store path)。見つからなければ 1
current_generation() {
  local p
  for p in "${XDG_STATE_HOME:-${HOME}/.local/state}/nix/profiles/home-manager" \
    "/nix/var/nix/profiles/per-user/${USER:-$(id -un 2>/dev/null || true)}/home-manager"; do
    if [[ -e ${p} ]]; then
      readlink -f "${p}"
      return 0
    fi
  done
  return 1
}

# flake.nix ($1) の inputs.<$2>.url の path: を出す ($2 は dotfiles か dotfiles-private)。無ければ空
input_path() {
  local p
  p=$(sed -n "s|^[[:space:]]*inputs\\.$2\\.url[[:space:]]*=[[:space:]]*\"path:\\([^\"]*\\)\".*|\\1|p" "$1" 2>/dev/null) || p=""
  printf '%s' "${p%%$'\n'*}"
}

# flake.nix ($1) の inputs.<$2>.url を path:<$3> に書き換える ($2 は dotfiles か dotfiles-private。比べるための写しで、
# 本体を揃える・shared/ を外した dotfiles-private の写しを指す)
set_input() {
  awk -v name="$2" -v dir="$3" '
    !done && $0 ~ ("^[[:space:]]*inputs\\." name "\\.url[[:space:]]*=[[:space:]]*\"path:[^\"]*\"") {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "inputs." name ".url = \"path:" dir "\";"
      done = 1
      next
    }
    { print }
  ' "$1" >"$1.new" && mv "$1.new" "$1"
}

# dotfiles-private の nix/ ($1) の shared/ の module (privateHosts が拾うもの: .nix で終わり、. で始まらないファイル)。
# 「, 」でつなぐ
shared_modules() {
  local f out=""
  for f in "$1"/shared/*.nix; do
    [[ -f ${f} ]] || continue
    f=${f##*/}
    out+="${out:+, }${f}"
  done
  printf '%s' "${out}"
}

# flake の写し ($1) の dotfiles-private の入力から shared/ を外す: 入力の nix/ を shared/ だけ除いて <$1>-private に写し、
# 入力をそこへ指し直す (lock は呼ぶ側が lock_sync で張り直す)。dotfiles-private には書かない
strip_shared() {
  local d p f
  d=$(cd -P -- "$1" && pwd)
  check_path "${d}"
  p=$(input_path "${d}/flake.nix" dotfiles-private)
  [[ -n ${p} && -d ${p} ]] || die "dotfiles-private の入力の指す先がありません: ${p:-(入力が無い)} (${d}/flake.nix)"
  mkdir -p "${d}-private"
  for f in "${p}"/* "${p}"/.[!.]*; do
    [[ -e ${f} || -L ${f} ]] || continue
    [[ ${f##*/} != shared ]] || continue
    cp -R -p "${f}" "${d}-private/" || die "dotfiles-private の nix/ を写せません: ${f}"
  done
  set_input "${d}/flake.nix" dotfiles-private "${d}-private"
}

# flake の写し ($1) で、元のホスト $2 が dotfiles-private の入力に登録したホスト (hosts/$2.nix) で、その shared/ に
# module があれば、shared/ を外し (strip_shared)、外した module を「, 」でつないで出す。元のホストに当たっている shared/ を、
# 下書きと compare の旧い形から外すため。どちらでもなければ何もしない
strip_base_shared() {
  local p mods
  p=$(input_path "$1/flake.nix" dotfiles-private)
  [[ -n ${p} && -f ${p}/hosts/$2.nix ]] || return 0
  mods=$(shared_modules "${p}")
  [[ -n ${mods} ]] || return 0
  strip_shared "$1"
  printf '%s' "${mods}"
}

# ローカル flake ($1) の flake.nix・flake.lock と隣のファイル (flake.nix が import するもの) を $2 に写す。
# setup (setup.sh への symlink)・退避・一時ファイルは写さない
copy_flake() {
  local src=$1 dst=$2 f
  mkdir -p "${dst}"
  cp "${src}/flake.nix" "${dst}/flake.nix"
  [[ ! -f ${src}/flake.lock ]] || cp "${src}/flake.lock" "${dst}/flake.lock"
  for f in "${src}"/* "${src}"/.[!.]*; do
    [[ -e ${f} || -L ${f} ]] || continue
    case ${f##*/} in
      flake.nix | flake.lock | setup | flake.nix.bak-* | flake.lock.bak-* | .flake.nix.*) continue ;;
    esac
    cp -R -p "${f}" "${dst}/" || die "ローカル flake の隣のファイルを写せません: ${f}"
  done
}

# flake.nix の path: の入力を「名前 パス」で 1 行ずつ出す (本体と dotfiles-private)
path_inputs() {
  sed -n 's|^[[:space:]]*inputs\.\([A-Za-z0-9_-]*\)\.url[[:space:]]*=[[:space:]]*"path:\([^"]*\)".*|\1 \2|p' "$1"
}

# 写し ($1) の lock を path: の入力ぜんぶに合わせる (local-flake-migrate.sh と同じ)。lock が無ければ nix flake lock、
# あれば実物の narHash が lock に無い入力をまとめて nix flake update。張り直したら lock_synced=1
lock_synced=0
lock_sync() {
  local d=$1 name path cur stale=()
  : >"${d}.lock.log"
  if [[ ! -f ${d}/flake.lock ]]; then
    nix flake lock "path:${d}" >>"${d}.lock.log" 2>&1
    return
  fi
  while read -r name path; do
    [[ -n ${name} && -d ${path} ]] || continue
    cur=$(nix hash path --sri --type sha256 "${path}" 2>>"${d}.lock.log") || return 1
    grep -qF -- "${cur}" "${d}/flake.lock" || stale+=("${name}")
  done < <(path_inputs "${d}/flake.nix")
  if ((${#stale[@]} > 0)); then
    lock_synced=1
    nix flake update "${stale[@]}" --flake "path:${d}" >>"${d}.lock.log" 2>&1
  fi
}

# nix のエラーの出力から、原因の行を字下げして出す (最後の error: の行から 15 行。local-flake-migrate.sh と同じ)
eval_error_excerpt() {
  local at
  at=$(awk '/^[[:space:]]*error:/ { n = NR } END { print n + 0 }' "$1")
  if ((at > 0)); then
    awk -v at="${at}" 'NR >= at && NR < at + 15 { print "    " $0 }' "$1"
  else
    tail -n 15 "$1" | sed 's/^/    /'
  fi
  printf '    (全文: %s)\n' "$1"
}

# ローカル flake ($1) に local (前の雛形の「このマシンだけの設定」) があるか。今の雛形には無い (ADR 027)
has_local() {
  grep -q '^[[:space:]]*local[[:space:]]*=' "$1"
}

# ローカル flake ($1) の local の中の、コメントでも空でもない行 (字下げを外して)。local は「local = …」の行から、
# 同じ字下げの「};」の行まで (前の雛形の形。関数の形 local = { lib, ... }: { … }; でも同じ)。local が無ければ何も出さない
local_lines() {
  awk '
    !inb && /^[[:space:]]*local[[:space:]]*=/ {
      match($0, /^[[:space:]]*/)
      ind = substr($0, 1, RLENGTH)
      inb = 1
      next
    }
    inb {
      if ($0 == ind "};") exit
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || line ~ /^#/) next
      print line
    }
  ' "$1"
}

# local の行のうち、dotfiles の option の外に値を書いている行 (下書きは options.dotfiles しか見ないので知らせる)
local_outside_lines() {
  local_lines "$1" | awk '/^[A-Za-z_][A-Za-z0-9_."-]*[[:space:]]*=/ && !/^dotfiles\./'
}

# ローカル flake ($1) に手で足したホスト (setup.sh が文字列から拾うのと同じ形)。「, 」でつなぐ
hand_hosts() {
  sed -n \
    -e 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    -e 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_-]*\)[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    "$1" | awk '$0 != "sandbox" && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 } END { print "" }'
}

# dotfiles-private の作業ツリー ($1) の nix/hosts/ に登録してあるホスト。「, 」でつなぐ
clone_hosts() {
  local f out=""
  for f in "$1"/nix/hosts/*.nix; do
    [[ -f ${f} ]] || continue
    f=${f##*/}
    out+="${out:+, }${f%.nix}"
  done
  printf '%s' "${out}"
}

# 全ホストの activationPackage.outPath を「out<TAB>ホスト<TAB>outPath」(落ちれば「fail<TAB>ホスト」) で出す式。
# 検証専用の sandbox は見ない
# shellcheck disable=SC2016 # Nix の式をそのまま書く
out_expr='hs: builtins.concatStringsSep "" (map (n:
  let d = builtins.tryEval (builtins.getAttr n hs).activationPackage.outPath; in
  if d.success then "out\t" + n + "\t" + d.value + "\n" else "fail\t" + n + "\n"
) (builtins.filter (n: n != "sandbox") (builtins.attrNames hs)))'

# 1 ホストの drvPath と outPath を 2 行で出す式。$1: ホスト (check_host 済み)
drv_expr() {
  printf '%s' 'hs: let a = (builtins.getAttr "'"$1"'" hs).activationPackage; in a.drvPath + "\n" + a.outPath'
}

# 1 ホストの dotfiles の option の値を「パス<TAB>値の JSON」で 1 行ずつ出す式。$1: ホスト (check_host 済み)。
# config ではなく options.dotfiles を辿り、表に出ない option (visible = false。改名した旧名の alias。値は新しい名前の
# option と同じ) は出さない (同じ違いが旧名と新しい名前の 2 行に出て読み違えるため)。関数は "<function>"、評価できない値は
# "<評価できない>" にする
dotfiles_expr() {
  printf '%s' 'hs: let
    flat = p: v:
      if builtins.isAttrs v && (v._type or "") == "option" then
        (if (v.visible or true) == false then [ ] else
          let r = builtins.tryEval (builtins.deepSeq v.value v.value); in
          [ (p + "\t" + (if !r.success then "\"<評価できない>\"" else if builtins.isFunction r.value then "\"<function>\"" else builtins.toJSON r.value) + "\n") ])
      else if builtins.isAttrs v then
        builtins.concatLists (map (k: flat (if p == "" then k else p + "." + k) (builtins.getAttr k v)) (builtins.attrNames v))
      else [ ];
  in builtins.concatStringsSep "" (flat "" (builtins.getAttr "'"$1"'" hs).options.dotfiles)'
}

# draft の式。値は env で渡す (PJP_FLAKE: 写しのディレクトリ、PJP_BASE: 元のホスト、PJP_NAME: この PC の名前、
# PJP_NOTES: 頭のコメントにする行のファイル、PJP_DRAFT_LIB: nix/lib/host-draft.nix)。--impure で評価する
# shellcheck disable=SC2016 # Nix の式をそのまま書く
draft_expr='let
  env = builtins.getEnv;
  f = builtins.getFlake ("path:" + env "PJP_FLAKE");
  h = builtins.getAttr (env "PJP_BASE") f.homeConfigurations;
  lib = h.pkgs.lib;
  draft = import (/. + env "PJP_DRAFT_LIB") { inherit lib; };
  u = h.config.home.username;
  s = h.pkgs.stdenv.hostPlatform.system;
  home = h.config.home.homeDirectory;
  defaultHome = if lib.hasSuffix "darwin" s then "/Users/${u}" else "/home/${u}";
in
draft.render {
  name = env "PJP_NAME";
  username = u;
  system = s;
  homeDirectory = if home == defaultHome then null else home;
  base = env "PJP_BASE";
  values = draft.collect h.options.dotfiles;
  notes = builtins.filter (l: l != "") (lib.splitString "\n" (builtins.readFile (/. + env "PJP_NOTES")));
}'

cmd_inspect() {
  local flake_dir=${default_flake_dir} name system clone pin state rc=0 main hand lines l which gen matched="" f reads=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --flake)
        [[ $# -ge 2 ]] || die "--flake にディレクトリを渡してください"
        flake_dir=${2%/}
        shift
        ;;
      *) die "inspect の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  f="${flake_dir}/flake.nix"
  name=$(this_host_name) || name=""
  system=$(this_system)
  clone=$(private_dir)

  echo "==> この PC"
  printf '  ホストの名前: %s  (<user>@<短い hostname>。setup と同じ決め方)\n' "${name:-決められない}"
  printf '  system: %s\n' "${system}"
  if is_wsl; then
    printf '  WSL: はい (Windows のユーザー名: %s)\n' "$(windows_user || printf '調べられない。Windows の PowerShell で環境変数 USERNAME を見る')"
  else
    echo "  WSL: いいえ"
  fi

  echo "==> dotfiles-private"
  if [[ -d ${clone}/.git ]]; then
    printf '  clone: %s\n' "${clone}"
  else
    printf '  clone: %s (無い。setup の bootstrap-dotfiles-private が作る)\n' "${clone}"
  fi
  if [[ -n ${name} ]]; then
    if [[ -f ${clone}/nix/hosts/${name}.nix ]]; then
      printf '  この PC のホスト: %s (ある。登録済みなので、直すなら今の値と比べる)\n' "${clone}/nix/hosts/${name}.nix"
    else
      printf '  この PC のホスト: %s (無い)\n' "${clone}/nix/hosts/${name}.nix"
    fi
  fi
  hand=$(clone_hosts "${clone}")
  printf '  登録してあるホスト: %s\n' "${hand:-なし}"
  hand=$(shared_modules "${clone}/nix")
  printf '  shared/ (登録した全ホストに足す module): %s\n' "${hand:-なし}"

  printf '==> ローカル flake: %s\n' "${f}"
  if [[ ! -f ${f} ]]; then
    echo "  無い (setup-local-flake.sh で用意する)"
  else
    if [[ -f ${script_dir}/local-flake-migrate.sh ]]; then
      state=$("${BASH}" "${script_dir}/local-flake-migrate.sh" check --flake "${flake_dir}" 2>/dev/null) || rc=$?
      case ${rc} in
        0) echo "  雛形の版: 今の雛形と同じ" ;;
        1) printf '  雛形の版: 前の雛形 (%s)。登録が merge されたら今の雛形へ移す\n' "${state}" ;;
        *) echo "  雛形の版: 調べられない" ;;
      esac
    fi
    main=$(input_path "${f}" dotfiles)
    printf '  本体 (inputs.dotfiles.url): %s\n' "${main:-無い}"
    pin=$(input_path "${f}" dotfiles-private)
    if [[ -z ${pin} ]]; then
      echo "  dotfiles-private の入力: 無い (前の雛形。登録が merge されたら今の雛形へ移す)"
    elif [[ -d ${pin} && -d ${clone}/nix && $(cd -P -- "${pin}" && pwd) == "$(cd -P -- "${clone}/nix" && pwd)" ]]; then
      reads=1
      printf '  dotfiles-private の入力: %s (clone の nix/ を読んでいる)\n' "${pin}"
    elif [[ ${pin} == */private-stub ]]; then
      printf '  dotfiles-private の入力: %s (本体の空の stub。clone の nix/ を読んでいない)\n' "${pin}"
    else
      printf '  dotfiles-private の入力: %s (clone の nix/ ではない)\n' "${pin}"
    fi
    hand=$(hand_hosts "${f}")
    printf '  手で足したホスト: %s\n' "${hand:-なし}"
    if has_local "${f}"; then
      echo "  local のコメントでない行 (前の雛形):"
      lines=$(local_lines "${f}")
      if [[ -n ${lines} ]]; then
        while IFS= read -r l; do
          printf '    %s\n' "${l}"
        done <<<"${lines}"
      else
        echo "    (無い)"
      fi
    else
      echo "  local: 無い (今の雛形。値は手で足したホストか dotfiles-private の登録に書く)"
    fi
  fi

  if [[ -f ${script_dir}/setup.sh ]]; then
    if which=$(DOTFILES_LOCAL_DIR="${flake_dir}" "${BASH}" "${script_dir}/setup.sh" --which-host 2>/dev/null </dev/null); then
      case ${which#*$'\t'} in
        local) state='ローカル flake で定義' ;;
        private) state='dotfiles-private に登録したこの PC のホスト' ;;
        *) state=${which#*$'\t'} ;;
      esac
      printf '==> setup が --host なしで選ぶホスト: %s (%s)\n' "${which%%$'\t'*}" "${state}"
    elif [[ -n ${name} && -f ${clone}/nix/hosts/${name}.nix ]]; then
      echo "==> setup が --host なしで選ぶホスト: 決まらない (setup は止まる。ローカル flake が clone の nix/ を読むまでは --host <型> で当てる)"
    else
      echo "==> setup が --host なしで選ぶホスト: 決まらない (setup は止まる。推測はしない。登録するまでは --host <型> で当てる。"
      echo "    型には WSL・1Password の署名・Dev Tracker などの PC の値が無い)"
    fi
  fi

  gen=$(current_generation) || gen=""
  printf '==> 今の世代: %s\n' "${gen:-見つからない}"
  if [[ -n ${gen} && -f ${f} ]] && command -v nix &>/dev/null; then
    need_tmp
    copy_flake "${flake_dir}" "${tmp}/cur"
    if ! lock_sync "${tmp}/cur"; then
      echo "  ローカル flake の写しの lock を張り直せないので、一致を調べられない:"
      eval_error_excerpt "${tmp}/cur.lock.log"
    else
      echo "  評価しています (1 回 20〜60 秒)…"
      if nix eval --raw "path:${tmp}/cur#homeConfigurations" --apply "${out_expr}" >"${tmp}/out.tsv" 2>"${tmp}/out.err"; then
        matched=$(awk -F'\t' -v g="${gen}" '$1 == "out" && $3 == g { printf "%s%s", (n++ ? ", " : ""), $2 }' "${tmp}/out.tsv")
        if [[ -n ${matched} ]]; then
          printf '  一致するホスト: %s\n' "${matched}"
        else
          echo "  一致するホストはありません (本体が最後の switch から進んだ、など)。setup が選ぶホスト (上。決まらなければ"
          echo "  登録簿の型) を元にするか、ユーザーに確かめる"
        fi
        if ((lock_synced)); then
          echo "  (ローカル flake の lock が本体と合っていなかったので、写しで張り直して評価した。今の世代とは一致しにくい)"
        fi
      else
        echo "  ローカル flake を評価できないので、一致を調べられない:"
        eval_error_excerpt "${tmp}/out.err"
      fi
    fi
  fi
  if [[ -n ${name} && -f ${clone}/nix/hosts/${name}.nix ]]; then
    printf '次: この PC は登録済み (%s)。\n' "${clone}/nix/hosts/${name}.nix"
    if ((reads == 0)); then
      echo "  ローカル flake が dotfiles-private の nix/ を読んでいないので、setup はまだこのホストを選ばない。今の雛形へ移す"
      echo "  (pjp-dotfiles-register-host の手順 6):"
      printf '    %s/local-flake-migrate.sh prepare --flake %s\n' "${script_dir}" "${flake_dir}"
      echo "  値を直すなら、移したあとで今の値から下書きを描き、今のファイルとの差を見る:"
    else
      echo "  値を直すなら、今の値から下書きを描き、今のファイルとの差を見る:"
    fi
    printf '    %s draft --base %s --flake %s\n' "${self}" "${name}" "${flake_dir}"
  else
    echo "次: 元にするホストを決めて、下書きを描く:"
    printf '  %s draft --base <ホスト> --flake %s\n' "${self}" "${flake_dir}"
  fi
}

cmd_draft() {
  local flake_dir=${default_flake_dir} base="" name="" nd=${nix_dir} out="" force=0 text lines l base_shared note=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --base | --flake | --name | --nix-dir | --out)
        [[ $# -ge 2 ]] || die "$1 に値を渡してください"
        case $1 in
          --base) base=$2 ;;
          --flake) flake_dir=${2%/} ;;
          --name) name=$2 ;;
          --nix-dir) nd=${2%/} ;;
          --out) out=$2 ;;
        esac
        shift
        ;;
      --force) force=1 ;;
      *) die "draft の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  [[ -n ${base} ]] || die "draft には --base <元にするホスト> が要ります (inspect の「一致するホスト」)"
  check_host "${base}"
  if [[ -z ${name} ]]; then
    name=$(this_host_name) || exit 2
  fi
  check_host "${name}"
  [[ -f ${flake_dir}/flake.nix ]] || die "ローカル flake がありません: ${flake_dir}/flake.nix"
  if [[ -n ${out} && -e ${out} && ${force} == 0 ]]; then
    die "--out が既にあります: ${out} (今の値と比べてから、上書きするなら --force)"
  fi
  # compare と同じ本体で評価する (既定はこの script の repo の nix/)。ローカル flake が別の本体を指していても、写しの
  # inputs.dotfiles.url をそこに書き換える (下書きと compare で評価する本体を揃える)
  nd=$(cd -P -- "${nd}" && pwd) || die "--nix-dir がありません: ${nd}"
  check_path "${nd}"
  need_nix
  need_tmp
  copy_flake "${flake_dir}" "${tmp}/cur"
  set_input "${tmp}/cur/flake.nix" dotfiles "${nd}"
  # 元のホストが dotfiles-private に登録したホスト (値を直すとき) なら、元のホストに当たっている shared/ を外して描く
  # (shared/ の値は登録した全ホストに足すので、ホストのファイルに書くと 2 重になる)
  base_shared=$(strip_base_shared "${tmp}/cur" "${base}") || exit 2
  if [[ -n ${base_shared} ]]; then
    note="元のホスト ${base} は dotfiles-private に登録したホストなので、shared/ (${base_shared}) を外して描いた (shared/ の値は登録した全ホストに足すので、ホストのファイルには書かない)"
  fi
  if ! lock_sync "${tmp}/cur"; then
    echo "!! ローカル flake の写しの lock を、path: の入力に合わせられません:" >&2
    eval_error_excerpt "${tmp}/cur.lock.log" >&2
    exit 2
  fi
  # local の、dotfiles の option の外の行 (下書きには描かない) を頭のコメントで知らせる
  lines=$(local_outside_lines "${flake_dir}/flake.nix")
  {
    if [[ -n ${lines} ]]; then
      echo "ローカル flake の local にあった、dotfiles の option の外の行 (下書きには入れていない。要るなら modules に足す):"
      while IFS= read -r l; do
        printf '  %s\n' "${l}"
      done <<<"${lines}"
    fi
  } >"${tmp}/notes"
  if ! text=$(PJP_FLAKE="${tmp}/cur" PJP_BASE="${base}" PJP_NAME="${name}" PJP_NOTES="${tmp}/notes" \
    PJP_DRAFT_LIB="${nix_dir}/lib/host-draft.nix" nix eval --raw --impure --expr "${draft_expr}" 2>"${tmp}/draft.err"); then
    {
      printf '!! 元にするホスト %s を、ローカル flake (%s) の写しで評価できません:\n' "${base}" "${flake_dir}"
      if [[ -n ${base_shared} ]]; then
        printf '   (dotfiles-private に登録したホストなので、shared/ (%s) を外して評価した。ホストのファイルが shared/ に頼っていないか確かめる)\n' \
          "${base_shared}"
      fi
      eval_error_excerpt "${tmp}/draft.err"
    } >&2
    exit 3
  fi
  if [[ -z ${out} ]]; then
    printf '%s\n' "${text}"
    [[ -z ${note} ]] || printf '==> %s\n' "${note}" >&2
    return 0
  fi
  mkdir -p "$(dirname -- "${out}")"
  printf '%s\n' "${text}" >"${out}"
  printf '==> 下書きを書きました: %s\n' "${out}"
  printf '  元にしたホスト: %s (ローカル flake で評価した値。前の雛形なら local も当たる)\n' "${base}"
  [[ -z ${lines} ]] || echo "  local に dotfiles の option の外の行があります (下書きの頭のコメント)。要るなら modules に足す"
  [[ -z ${note} ]] || printf '  %s\n' "${note}"
}

# dotfiles-private の nix/ ($3) のホストだけを出す flake を $1 に書く (compare の新しい形。本体は $2)
private_flake() {
  mkdir -p "$1"
  cat >"$1/flake.nix" <<EOS
# private-host.sh compare が作った、dotfiles-private の nix/ のホストだけを出す flake (比べるための写し)
{
  inputs.dotfiles.url = "path:$2";
  inputs.dotfiles-private.url = "path:$3";
  inputs.dotfiles-private.flake = false;
  outputs =
    { dotfiles, dotfiles-private, ... }:
    {
      homeConfigurations = dotfiles.lib.privateHosts dotfiles-private;
    };
}
EOS
}

# flake の写し ($1) のホスト ($2) の dotfiles の option の値を、<$1>.dotfiles.tsv に「パス<TAB>値の JSON」で書く。
# 書いてあれば評価し直さない (1 つの形を 2 つの違いで使う)。読めなければ 1
dotfiles_tsv() {
  [[ ! -f $1.dotfiles.tsv ]] || return 0
  nix eval --raw "path:$1#homeConfigurations" --apply "$(dotfiles_expr "$2")" >"$1.dotfiles.tsv.part" 2>/dev/null \
    && mv "$1.dotfiles.tsv.part" "$1.dotfiles.tsv"
}

# 2 つの形の config.dotfiles の違いを「    パス: 前 → 後」で 1 行ずつ出す ($1・$2: 前の形の flake の写しとホスト、
# $3・$4: 後の形。$5: 違いが無いときに出す行)
dotfiles_diff() {
  local text
  if ! dotfiles_tsv "$1" "$2" || ! dotfiles_tsv "$3" "$4"; then
    echo "    (config.dotfiles を読めませんでした)"
    return 0
  fi
  text=$(
    awk -F'\t' '
      FILENAME == ARGV[1] { a[$1] = $2; next }
      { b[$1] = $2 }
      END {
        for (k in a) if (!(k in b)) print "    " k ": " a[k] " → (無い)"
        for (k in b) if (!(k in a)) print "    " k ": (無い) → " b[k]; else if (a[k] != b[k]) print "    " k ": " a[k] " → " b[k]
      }
    ' "$1.dotfiles.tsv" "$3.dotfiles.tsv" | sort
  )
  printf '%s\n' "${text:-$5}"
}

cmd_compare() {
  local flake_dir=${default_flake_dir} base="" name="" nd=${nix_dir} private="" out="" pnix old_pin work res side rc
  local old_drv old_out new_drv new_out bare_drv="" host_drv host_side moved gen shared base_shared sides=(old new)
  local same_outside="    (config.dotfiles は同じ。dotfiles の option の外 (local や modules の programs.* など) が違う)"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --base | --private | --name | --flake | --nix-dir | --out)
        [[ $# -ge 2 ]] || die "$1 に値を渡してください"
        case $1 in
          --base) base=$2 ;;
          --private) private=${2%/} ;;
          --name) name=$2 ;;
          --flake) flake_dir=${2%/} ;;
          --nix-dir) nd=${2%/} ;;
          --out) out=${2%/} ;;
        esac
        shift
        ;;
      *) die "compare の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  [[ -n ${base} ]] || die "compare には --base <元にするホスト> が要ります"
  [[ -n ${private} ]] || die "compare には --private <dotfiles-private の作業ツリー> が要ります"
  check_host "${base}"
  if [[ -z ${name} ]]; then
    name=$(this_host_name) || exit 2
  fi
  check_host "${name}"
  if [[ -d ${private}/nix/hosts ]]; then
    pnix=${private}/nix
  elif [[ -d ${private}/hosts ]]; then
    pnix=${private}
  else
    die "dotfiles-private の作業ツリーに nix/hosts/ がありません: ${private}"
  fi
  pnix=$(cd -P -- "${pnix}" && pwd)
  [[ -f ${pnix}/hosts/${name}.nix ]] || die "${pnix}/hosts/${name}.nix がありません (下書きを書いてから比べる)"
  [[ -f ${flake_dir}/flake.nix ]] || die "ローカル flake がありません: ${flake_dir}/flake.nix"
  nd=$(cd -P -- "${nd}" && pwd) || die "--nix-dir がありません: ${nd}"
  check_path "${nd}"
  check_path "${pnix}"
  need_nix
  # ローカル flake の dotfiles-private の入力 (登録した PC なら clone の nix/)
  old_pin=$(input_path "${flake_dir}/flake.nix" dotfiles-private)
  if [[ -n ${old_pin} && -d ${old_pin} ]]; then
    old_pin=$(cd -P -- "${old_pin}" && pwd)
  fi
  if [[ -n ${out} ]]; then
    if [[ -e ${out} ]] && [[ ! -d ${out} || -n $(ls -A "${out}") ]]; then
      die "--out が空でないか、ディレクトリではありません: ${out}"
    fi
    # 作る前に置き場所を確かめる (ローカル flake・dotfiles-private の nix/ の中に作らない)
    work=$(abs_path "${out}")
    case "${work}/" in
      "$(cd -P -- "${flake_dir}" && pwd)/"*) die "--out がローカル flake の中です: ${work} (外に作る)" ;;
      "${pnix}/"*) die "--out が dotfiles-private の作業ツリーの nix/ の中です: ${work} (外に作る)" ;;
    esac
    if [[ -d ${old_pin} ]]; then
      case "${work}/" in
        "${old_pin}/"*) die "--out がローカル flake の読む dotfiles-private の nix/ の中です: ${work} (外に作る)" ;;
      esac
    fi
    mkdir -p "${work}"
  else
    need_tmp
    work="${tmp}/compare"
  fi

  # 旧い形: ローカル flake の写しの本体を --nix-dir に揃える。元のホストが dotfiles-private に登録したホストなら、ローカル
  # flake の読む shared/ を外す (ホストのファイルどうしで比べる)。新しい形: privateHosts だけを出す flake。shared/ に module が
  # あれば、shared/ を外した新しい形 (new-noshared) も作る
  copy_flake "${flake_dir}" "${work}/old"
  set_input "${work}/old/flake.nix" dotfiles "${nd}"
  base_shared=$(strip_base_shared "${work}/old" "${base}") || exit 2
  private_flake "${work}/new" "${nd}" "${pnix}"
  shared=$(shared_modules "${pnix}")
  if [[ -n ${shared} ]]; then
    private_flake "${work}/new-noshared" "${nd}" "${pnix}"
    strip_shared "${work}/new-noshared"
    sides+=(new-noshared)
  fi
  for side in "${sides[@]}"; do
    if [[ ${side} != old && -f ${work}/old/flake.lock ]]; then
      cp "${work}/old/flake.lock" "${work}/${side}/flake.lock"
    fi
    if ! lock_sync "${work}/${side}"; then
      printf '!! 比べるための写し (%s) の lock を、path: の入力に合わせられません:\n' "${side}" >&2
      eval_error_excerpt "${work}/${side}.lock.log" >&2
      exit 2
    fi
  done

  printf '==> 比べる: 旧い形 %s (ローカル flake の写し。前の雛形なら local が当たる) と、新しい形 %s (%s/hosts/%s.nix。ローカル flake の値は当たらない)\n' \
    "${base}" "${name}" "${pnix}" "${name}"
  printf '  本体: %s\n' "${nd}"
  if [[ -n ${shared} ]]; then
    printf '  shared/ の module: %s (%s/shared。登録した全ホストに足す値で、ホストのファイルの外。shared/ を外した新しい形とも比べ、分けて出す)\n' \
      "${shared}" "${pnix}"
  fi
  if [[ -n ${base_shared} ]]; then
    printf '  旧い形 %s は dotfiles-private に登録したホストなので、ローカル flake が読む shared/ (%s) を外して評価する (ホストのファイルどうしで比べる)\n' \
      "${base}" "${base_shared}"
  fi
  echo "  評価しています (1 回 20〜60 秒)…"
  if ! res=$(nix eval --raw "path:${work}/old#homeConfigurations" --apply "$(drv_expr "${base}")" 2>"${work}/old.err"); then
    {
      printf '!! 旧い形 (ローカル flake の %s) を評価できません:\n' "${base}"
      if [[ -n ${base_shared} ]]; then
        printf '   (dotfiles-private に登録したホストなので、shared/ (%s) を外して評価した。ホストのファイルが shared/ に頼っていないか確かめる)\n' \
          "${base_shared}"
      fi
      eval_error_excerpt "${work}/old.err"
    } >&2
    exit 3
  fi
  old_drv=${res%%$'\n'*}
  old_out=${res#*$'\n'}
  if ! res=$(nix eval --raw "path:${work}/new#homeConfigurations" --apply "$(drv_expr "${name}")" 2>"${work}/new.err"); then
    {
      printf '!! 新しい形 (%s/hosts/%s.nix。shared/ があれば足した形) を評価できません (ファイルの誤りを直して比べ直す):\n' "${pnix}" "${name}"
      eval_error_excerpt "${work}/new.err"
    } >&2
    exit 4
  fi
  new_drv=${res%%$'\n'*}
  new_out=${res#*$'\n'}
  if [[ -n ${shared} ]] \
    && res=$(nix eval --raw "path:${work}/new-noshared#homeConfigurations" --apply "$(drv_expr "${name}")" 2>"${work}/new-noshared.err"); then
    bare_drv=${res%%$'\n'*}
  fi
  printf '  旧い形 %s: %s\n' "${base}" "${old_drv}"
  printf '  新しい形 %s: %s\n' "${name}" "${new_drv}"
  [[ -z ${shared} ]] || printf '  新しい形 %s (shared/ を外す): %s\n' "${name}" "${bare_drv:-評価できない}"

  gen=$(current_generation) || gen=""
  if [[ -z ${gen} ]]; then
    echo "  参考: 今の世代が見つからない"
  elif [[ ${gen} == "${old_out}" ]]; then
    printf '  参考: 今の世代 (%s) は旧い形と一致する\n' "${gen}"
  elif [[ ${gen} == "${new_out}" ]]; then
    printf '  参考: 今の世代 (%s) は新しい形と一致する\n' "${gen}"
  elif [[ -n ${base_shared} ]]; then
    printf '  参考: 今の世代 (%s) はどちらとも一致しない (旧い形は shared/ を外して評価した。判定には使わない)\n' "${gen}"
  else
    printf '  参考: 今の世代 (%s) はどちらとも一致しない (本体が最後の switch から進んだ、など。判定には使わない)\n' "${gen}"
  fi

  # 元のホストが登録したホストなら旧い形は shared/ を外してあるので、drvPath が同じでも、clone の shared/ の分は下で見る
  if [[ -z ${base_shared} && ${old_drv} == "${new_drv}" ]]; then
    echo "→ drvPath が同じ。この登録で home-manager の世代の中身は変わらない (元のホストの値を全部写せている)。"
    return 0
  fi
  if [[ -n ${shared} && -z ${bare_drv} ]]; then
    echo "  shared/ を外した新しい形を評価できない (ホストのファイルが shared/ に頼っている、など)。shared/ を含めて比べる:"
    eval_error_excerpt "${work}/new-noshared.err"
  fi
  if [[ -z ${base_shared} && -z ${bare_drv} ]]; then
    echo "→ drvPath が違う (この登録で値が変わる)。config.dotfiles の違い (旧い → 新しい):"
    dotfiles_diff "${work}/old" "${base}" "${work}/new" "${name}" "${same_outside}"
    return 1
  fi

  # ホストのファイルどうしで比べる: 旧い形 (登録したホストなら clone の shared/ を外した形) と、新しい形から shared/ を外した形
  # (作業ツリーに shared/ が無い・外した形を評価できないなら、新しい形そのもの)
  host_drv=${bare_drv:-${new_drv}}
  host_side=new
  [[ -z ${bare_drv} ]] || host_side=new-noshared
  # 元のホストが登録したホストなら、旧い形にも clone の shared/ が当たっていた。clone と作業ツリーの shared/ が同じかで、この登録で
  # shared/ の値が動くかが決まる (同じなら、作業ツリーの shared/ の値は登録で増える値ではない)
  moved=0
  if [[ -n ${base_shared} ]] && ! diff -r "${old_pin}/shared" "${pnix}/shared" >/dev/null 2>&1; then
    moved=1
  fi
  if [[ ${old_drv} == "${host_drv}" ]]; then
    if [[ -n ${base_shared} && ${moved} == 0 ]]; then
      echo "→ 同じ。shared/ を外すと drvPath が同じ (ホストのファイルの値が同じ) で、shared/ も clone と作業ツリーで同じ。この登録で home-manager の世代の中身は変わらない。"
      return 0
    fi
    rc=0
    echo "→ 同じ (shared/ の値だけ違う)。shared/ を外すと drvPath が同じで、ホストのファイルは元のホストの値を全部写せている。"
  else
    rc=1
    if [[ -n ${bare_drv} ]]; then
      echo "→ 違う (shared/ を外しても drvPath が違う。この登録でホストの値が変わる)。config.dotfiles の違い (旧い → shared/ を外した新しい形):"
    else
      echo "→ 違う (ホストのファイルの値が違う。この登録で値が変わる)。config.dotfiles の違い (旧い → 新しい):"
    fi
    dotfiles_diff "${work}/old" "${base}" "${work}/${host_side}" "${name}" "${same_outside}"
  fi
  if [[ -n ${base_shared} ]]; then
    if [[ ${moved} == 0 ]]; then
      echo "  shared/ は clone と作業ツリーで同じ (元のホストにも当たっている。この登録で shared/ の値は変わらない)"
      return "${rc}"
    fi
    printf '  clone と作業ツリーの shared/ が違う (clone: %s/shared。merge のあと clone を取ると、その違いの分も世代が変わりうる)\n' "${old_pin}"
  fi
  [[ -n ${bare_drv} ]] || return "${rc}"
  if [[ -n ${base_shared} ]]; then
    echo "  作業ツリーの shared/ が足す値 (config.dotfiles の、shared/ を外した新しい形 → 新しい形):"
  else
    echo "  shared/ が足す値 (登録でこの PC に増える。登録した全ホストに当たる。config.dotfiles の、shared/ を外した新しい形 → 新しい形):"
  fi
  if [[ ${new_drv} == "${bare_drv}" ]]; then
    echo "    (shared/ はこのホストの値を変えない)"
  else
    dotfiles_diff "${work}/new-noshared" "${name}" "${work}/new" "${name}" \
      "    (config.dotfiles は同じ。shared/ は dotfiles の option の外 (programs.* など) を変えている)"
  fi
  return "${rc}"
}

# summary: 1 ホストの要約を出す (冒頭の「ホストの要約」)
cmd_summary() {
  local flake_dir=${default_flake_dir} host="" nd="" out="" which text
  while [[ $# -gt 0 ]]; do
    case $1 in
      --host | --flake | --nix-dir | --out)
        [[ $# -ge 2 ]] || die "$1 に値を渡してください"
        case $1 in
          --host) host=$2 ;;
          --flake) flake_dir=${2%/} ;;
          --nix-dir) nd=${2%/} ;;
          --out) out=${2%/} ;;
        esac
        shift
        ;;
      *) die "summary の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  if [[ -n ${out} && (-e ${out} || -L ${out}) ]]; then
    die "--out は無い場所を渡してください (在るものは書き換えない): ${out}"
  fi
  [[ -f ${flake_dir}/flake.nix ]] || die "ローカル flake がありません: ${flake_dir}/flake.nix"
  if [[ -z ${host} ]]; then
    if ! which=$(DOTFILES_LOCAL_DIR="${flake_dir}" "${BASH}" "${script_dir}/setup.sh" --which-host 2>/dev/null </dev/null) \
      || [[ -z ${which} ]]; then
      die "対象ホストが決まりません (setup が --host なしで選ぶホストが無い)。--host <ホスト> で選んでください"
    fi
    host=${which%%$'\t'*}
  fi
  check_host "${host}"
  need_nix
  need_tmp
  copy_flake "${flake_dir}" "${tmp}/cur"
  if [[ -n ${nd} ]]; then
    nd=$(cd -P -- "${nd}" && pwd) || die "--nix-dir がありません: ${nd}"
    check_path "${nd}"
    set_input "${tmp}/cur/flake.nix" dotfiles "${nd}"
  fi
  if ! lock_sync "${tmp}/cur"; then
    echo "!! ローカル flake の写しの lock を、path: の入力に合わせられません:" >&2
    eval_error_excerpt "${tmp}/cur.lock.log" >&2
    exit 2
  fi
  if [[ -n ${out} ]]; then
    # 一時の場所に書き出してから移す (評価が途中で落ちても、<dir> に書きかけを残さない)
    if ! nix eval --write-to "${tmp}/pages" "path:${tmp}/cur#homeConfigurations.\"${host}\".hostSummary" \
      --apply "s: s.pages \"${host}\"" 2>"${tmp}/summary.err" </dev/null; then
      summary_eval_failed "${host}" "${flake_dir}"
    fi
    mv "${tmp}/pages" "${out}" || die "--out に書けません: ${out}"
    printf '==> ホスト %s のページを %s に書きました (ローカル flake %s で評価):\n' "${host}" "${out}" "${flake_dir}"
    (cd "${out}" && find . -type f | sed 's|^\./|  |' | LC_ALL=C sort)
    printf '  (図は HTML 版をブラウザで開く。dotfiles-private に登録したホストなら、docs/hosts/ の同じ名前のファイルと同じ中身)\n'
    return 0
  fi
  if ! text=$(nix eval --raw "path:${tmp}/cur#homeConfigurations.\"${host}\".hostSummary" --apply 's: s.text' \
    2>"${tmp}/summary.err" </dev/null); then
    summary_eval_failed "${host}" "${flake_dir}"
  fi
  # $(…) は末尾の改行を落とすので、出すときに 1 つ足す (要約の文は改行で終わる)
  printf '==> ホスト %s の要約 (設定グループ。ローカル flake %s で評価)\n%s\n' "${host}" "${flake_dir}" "${text}"
  echo "  (グループ・道具の switch の直し方は本体の nix/README.md「設定グループ」。グループごとの既定は nix/groups.md。図は --out <dir> で書く HTML 版)"
}

summary_eval_failed() {
  {
    printf '!! ホスト %s の要約を、ローカル flake (%s) の写しで評価できません (ホストの名前が違う・本体が設定グループより前、など):\n' \
      "$1" "$2"
    eval_error_excerpt "${tmp}/summary.err"
  } >&2
  exit 3
}

# summaries の flake: dotfiles-private の nix/ ($3) と win/hosts/ ($4) のホストから、docs/hosts/ に書くファイルの組を出す (本体は $2)
summaries_flake() {
  mkdir -p "$1"
  cat >"$1/flake.nix" <<EOS
# private-host.sh summaries が作った、dotfiles-private のホストの要約 (docs/hosts/ に書くファイル) を出す flake (書き出すための写し)
{
  inputs.dotfiles.url = "path:$2";
  inputs.dotfiles-private.url = "path:$3";
  inputs.dotfiles-private.flake = false;
  inputs.win-hosts.url = "path:$4";
  inputs.win-hosts.flake = false;
  outputs =
    { dotfiles, dotfiles-private, win-hosts, ... }:
    {
      summaryFiles = dotfiles.lib.hostSummaryFiles dotfiles-private win-hosts;
    };
}
EOS
}

# md の 3 行目 (h1 と空行の後ろ) が、Notion に写す道具の書いた「📝 [Notion で開く](https://app.notion.com/p/…)」の行で、4 行目が
# 空なら、その行を出す (無ければ何も出さない)。setup.sh の strip_notion_line と同じ行を見る
notion_line() {
  local l3 l4
  l3=$(sed -n '3p' "$1")
  l4=$(sed -n '4p' "$1")
  if [[ ${l3} == '📝 [Notion で開く](https://app.notion.com/p/'*')' && -z ${l4} ]]; then
    printf '%s' "${l3}"
  fi
}

# $1 のファイル (生成した md) の 2 行目 (h1 の後ろの空行) の後ろに、$2 の行と空行を入れて出す (行は awk -v で渡さない。
# -v はバックスラッシュをエスケープとして解く)
with_notion_line() {
  NOTION_LINE=$2 awk 'NR == 3 { print ENVIRON["NOTION_LINE"]; print "" } { print }' "$1"
}

# summaries: dotfiles-private の作業ツリーの docs/hosts/ に、全ホストの要約のページを書く (冒頭の「ホストの要約」)
cmd_summaries() {
  local private="" nd=${nix_dir} check=0 pnix whosts work want out rel f page line differ=() wrote=() removed=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --private | --nix-dir)
        [[ $# -ge 2 ]] || die "$1 に値を渡してください"
        case $1 in
          --private) private=${2%/} ;;
          --nix-dir) nd=${2%/} ;;
        esac
        shift
        ;;
      --check) check=1 ;;
      *) die "summaries の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  [[ -n ${private} ]] || die "summaries には --private <dotfiles-private の作業ツリー> が要ります"
  [[ -d ${private} ]] || die "dotfiles-private の作業ツリーがありません: ${private}"
  private=$(cd -P -- "${private}" && pwd)
  if [[ ! -d ${private}/nix/hosts && ! -d ${private}/win/hosts ]]; then
    die "dotfiles-private の作業ツリーに nix/hosts/ も win/hosts/ もありません (作業ツリーの root を渡す): ${private}"
  fi
  nd=$(cd -P -- "${nd}" && pwd) || die "--nix-dir がありません: ${nd}"
  check_path "${nd}"
  check_path "${private}"
  need_nix
  need_tmp
  # nix/ か win/hosts/ が無ければ、空の dir を渡す (path: の入力は在る場所しか取れない)
  pnix=${private}/nix
  if [[ ! -d ${pnix} ]]; then
    pnix="${tmp}/no-private-nix"
    mkdir -p "${pnix}"
  fi
  whosts=${private}/win/hosts
  if [[ ! -d ${whosts} ]]; then
    whosts="${tmp}/no-win-hosts"
    mkdir -p "${whosts}"
  fi
  work="${tmp}/summaries"
  summaries_flake "${work}" "${nd}" "${pnix}" "${whosts}"
  if ! lock_sync "${work}"; then
    echo "!! 要約を出す flake の lock を作れません:" >&2
    eval_error_excerpt "${work}.lock.log" >&2
    exit 2
  fi
  want="${tmp}/summaries-out"
  if ! nix eval --write-to "${want}" "path:${work}#summaryFiles" 2>"${work}.err" </dev/null; then
    {
      printf '!! %s のホストの要約を評価できません (ホストのファイルの誤り・本体が設定グループより前、など。本体: %s):\n' \
        "${private}" "${nd}"
      eval_error_excerpt "${work}.err"
    } >&2
    exit 3
  fi
  out=${private}/docs/hosts
  # docs/hosts/ の外に書かないよう、docs/・docs/hosts/ とその中に symlink があれば書かずに止める
  if [[ -L ${private}/docs || -L ${out} ]] || { [[ -d ${out} ]] && [[ -n $(find "${out}" -type l -print 2>/dev/null) ]]; }; then
    die "${private}/docs/hosts/ (か docs/) に symlink があります。summaries は docs/hosts/ の中だけに書くので、symlink を外してから流してください"
  fi
  while IFS= read -r rel; do
    [[ -n ${rel} ]] || continue
    f="${out}/${rel}"
    page="${want}/${rel}"
    # Notion に写す道具が書いた行は残す (無ければ生成したまま)
    if [[ ${rel} == *.md && -f ${f} ]]; then
      line=$(notion_line "${f}")
      if [[ -n ${line} ]]; then
        with_notion_line "${page}" "${line}" >"${work}.page"
        page="${work}.page"
      fi
    fi
    if [[ -f ${f} ]] && cmp -s "${page}" "${f}"; then
      continue
    fi
    differ+=("${rel}")
    if ((check == 0)); then
      mkdir -p "${f%/*}"
      cp "${page}" "${f}"
      wrote+=("${rel}")
    fi
  done < <(cd "${want}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
  # 作らなくなったファイル (ホストのファイルが無くなったページなど)
  if [[ -d ${out} ]]; then
    while IFS= read -r rel; do
      [[ -n ${rel} && ! -f ${want}/${rel} ]] || continue
      differ+=("${rel} (作らないファイル)")
      if ((check == 0)); then
        rm -f -- "${out:?}/${rel}"
        removed+=("${rel}")
      fi
    done < <(cd "${out}" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
    if ((check == 0)); then
      find "${out}" -mindepth 1 -type d -empty -delete
    fi
  fi
  if ((check)); then
    if ((${#differ[@]} == 0)); then
      printf '==> %s の要約は今の設定と同じ (本体: %s)\n' "${out}" "${nd}"
      return 0
    fi
    printf '==> %s の要約が今の設定と違う (本体: %s。出し直すなら --check を外す):\n' "${out}" "${nd}"
    printf '  %s\n' "${differ[@]}"
    return 1
  fi
  if ((${#wrote[@]} == 0 && ${#removed[@]} == 0)); then
    printf '==> %s の要約は今の設定と同じ (書き換えたファイルは無い。本体: %s)\n' "${out}" "${nd}"
    return 0
  fi
  printf '==> %s の要約を出し直しました (本体: %s)\n' "${out}" "${nd}"
  ((${#wrote[@]} == 0)) || printf '  書いた: %s\n' "${wrote[@]}"
  ((${#removed[@]} == 0)) || printf '  消した: %s (作らないファイル)\n' "${removed[@]}"
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
cmd=$1
shift
case ${cmd} in
  name)
    [[ $# -eq 0 ]] || die "name は引数を取りません"
    this_host_name
    ;;
  dir)
    [[ $# -eq 0 ]] || die "dir は引数を取りません"
    private_dir
    echo
    ;;
  input-dir) cmd_input_dir "$@" ;;
  system)
    [[ $# -eq 0 ]] || die "system は引数を取りません"
    this_system
    echo
    ;;
  is-wsl)
    [[ $# -eq 0 ]] || die "is-wsl は引数を取りません"
    if ! is_wsl; then
      printf '!! WSL ではありません (WSL_DISTRO_NAME が無く、/proc/version に microsoft がありません)。\n' >&2
      exit 1
    fi
    ;;
  windows-user)
    [[ $# -eq 0 ]] || die "windows-user は引数を取りません"
    if ! is_wsl; then
      printf '!! WSL ではありません (WSL_DISTRO_NAME が無く、/proc/version に microsoft がありません)。\n' >&2
      exit 1
    fi
    if ! windows_user; then
      # shellcheck disable=SC2016 # 文面の $env:USERNAME は PowerShell の変数の名前
      printf '!! Windows のユーザー名を引けません (pwsh.exe・powershell.exe の $env:USERNAME が返りませんでした。WSL の interop が落ちていないか確かめる)。\n' >&2
      exit 1
    fi
    echo
    ;;
  inspect) cmd_inspect "$@" ;;
  draft) cmd_draft "$@" ;;
  compare) cmd_compare "$@" ;;
  summary) cmd_summary "$@" ;;
  summaries) cmd_summaries "$@" ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
