#!/usr/bin/env bash
# shellcheck shell=bash
#
# home 閉包を SBOM 化し、複数の脆弱性データベース (OSV / GHSA / NVD) でスキャンする。
#
# ## なぜ要るのか
#
# flake.lock の pin には最小経過日数を課している (flake-lock-age.sh / ADR 005)。
# この遅延は「未発覚の侵害を誰かが先に踏む時間」を稼ぐが、裏返しとして
# **発覚済みの侵害バージョンを 7 日間固定し続ける**リスクを新しく作る。
# 発覚済みのものは advisory (主に OSV / GHSA) に載るので、pin した結果として
# 実際に入る閉包をスキャンして照合するのがこの script。役割分担は ADR 006。
#
# vulnix 単体にしないのは、vulnix が NVD (CVE) しか見ないため。npm や GitHub
# Release 由来のサプライチェーン侵害は CVE 採番が無いか大幅に遅れることが多く、
# 主戦場は OSV / GHSA になる。そこで sbomnix 同梱の vulnxscan (OSV + Grype +
# vulnix の束) を使い、vulnix は補助線の位置づけにする。
#
# ## 何をするか
#
# 1. sbomnix (vulnxscan を同梱) を用意する (PATH に無ければ nixpkgs の pin から組む。
#    下の「依存」と「sbomnix (vulnxscan) の用意」の節)
# 2. 対象の閉包をビルドする (binary cache があれば実体はダウンロード)
# 3. sbomnix で SBOM (CycloneDX / SPDX / csv) を書き出す
#    (vulnxscan も内部で SBOM を作るが保存しないので、成果物として別に残す)
# 4. vulnxscan で runtime 閉包をスキャンし、findings の表 (whitelist に無いもの) を
#    vulns.csv から作って出す (report.txt にも残す。CI は summary に貼る)
# 5. whitelist に無い findings があれば終了コード 1 で落ちる (CI のゲート)
#
# whitelist は「安全と確認した」印ではなく **増分検知の基準線**。閉包には既知
# CVE が常に数十件あるので、全 findings で落とすとゲートは初日から赤いままに
# なる。導入時点の findings を baseline として受け入れ、以後の**新規** findings
# だけを人間の判断 (pin を動かすか、意図して受け入れて whitelist へ足すか) に
# 回す。受け入れは git 管理の csv への追記なので、PR の diff がそのまま監査線に
# なる。
#
# ## 使い方
#
#   closure-scan.sh scan     [<flake ディレクトリ>]  スキャンして基準線と照合 (CI 用)
#   closure-scan.sh report   [<flake ディレクトリ>]  スキャンして表示するだけ (ゲートしない)
#   closure-scan.sh baseline [<flake ディレクトリ>]  今の findings を whitelist へ追記
#
# report は「lock を作った直後、そのツールを実行する前に何が入るか見る」ための形。
# flake-lock-age.sh update が完了時に自動で差し込む (whitelist があれば scan、
# 無ければ report)。whitelist が無くても通り、あれば適用して「基準線に無いもの
# だけ」を表示する。
#
# オプションは --help を参照。既定の対象は、この script の隣の flake (dotfiles
# 本体) なら homeConfigurations.sandbox の activationPackage (CI がビルドして
# いるものと同じ。登録簿のホストはパッケージ集合がこれとほぼ同一で、差は設定
# ファイル側にしか無い)。それ以外の flake なら devShells.<system>.default
# (「これから実行するツール」は devShell に入っているものなので)。
#
# flake だけのディレクトリ (下にディレクトリを持たない) は path: で読む。素のパスで
# 渡すと、git の repo の中では repo 全体が /nix/store へ写る (作業ツリーが変わるたびに
# 別の写し)。下にディレクトリを持つ flake は、今までどおり素のパスで読む。
#
# ## 依存
#
# nix / coreutils / awk (git は前の pin をさかのぼるときだけ)。sbomnix (vulnxscan を
# 同梱) が PATH に無ければ、対象 flake の **pin された nixpkgs** から組む。スキャナ
# 自身の版も flake.lock と同じ遅延ポリシーに従わせるための形。対象の pin で組めな
# ければ、dotfiles の pin、対象の flake.lock の git の履歴にある前の pin の順に退く
# (どれも遅延を守って入れた pin。退いたら警告する)。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)

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

step() {
  printf '%s+ %s%s\n' "${c_cyan}" "$*" "${c_reset}"
}

# 止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh の手順 (flake-lock-age.sh 経由) から走るときは、最後の「警告のまとめ」にも
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
使い方: closure-scan.sh [オプション] <scan|report|baseline> [<flake ディレクトリ>]

  scan      閉包を SBOM 化してスキャンし、whitelist に無い findings があれば
            終了コード 1 (CI 用のゲート。whitelist が無いと落ちる)
  report    同じスキャンをして表示するだけ (findings では落ちない)。whitelist は
            無くてもよく、あれば適用して基準線に無いものだけを表示する
  baseline  scan と同じスキャンを行い、whitelist に無い findings を whitelist へ
            追記する (導入時と、新規 findings を意図して受け入れるとき)

オプション:
  --attr ATTR       ビルドする属性。既定は flake で変わる:
                    dotfiles 本体 -> homeConfigurations.sandbox.activationPackage
                    それ以外     -> devShells.<system>.default
  --whitelist CSV   whitelist の場所 (既定 <flake ディレクトリ>/vulnxscan-whitelist.csv)
  --out-dir DIR     SBOM・findings・レポートの書き出し先 (既定 mktemp -d)
  -h, --help        この使い方を出す

ディレクトリを省くと、この script の隣 (<script>/../flake.nix) があればそこ、
無ければカレントディレクトリを対象にする。flake だけのディレクトリ (下にディレクトリを
持たない) は path: で読む (git の repo の中でも、repo を /nix/store へ写さない)。

sbomnix (vulnxscan 同梱) が PATH に無ければ、対象の pin → dotfiles の pin →
対象の flake.lock の git の履歴にある前の pin (新しい順に 3 つまで) の順に組み、
最初に組めたもので照らす。対象の pin でなければ警告する。どれで照らしたかは
成果物の scanner.txt に残す。

whitelist は「安全と確認した」印ではなく増分検知の基準線。列は
"vuln_id","package","comment" で、vuln_id は正規表現 (完全一致)、package は
完全一致。詳細は ADR 006。
EOS
}

##########
# 引数   #
##########

cmd=""
flake_dir=""
attr="" # 空なら flake に合わせて後で決める (dotfiles 本体か否か)
whitelist=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --attr)
      [[ $# -ge 2 ]] || die '--attr には属性名が要ります。'
      attr=$2
      shift 2
      ;;
    --whitelist)
      [[ $# -ge 2 ]] || die '--whitelist にはファイルパスが要ります。'
      whitelist=$2
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die '--out-dir にはディレクトリが要ります。'
      out_dir=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    scan | report | baseline)
      [[ -z ${cmd} ]] || die "動作は 1 つだけ指定すること (${cmd} と $1 が指定されました)。"
      cmd=$1
      shift
      ;;
    -*)
      usage >&2
      die "不明なオプション: $1"
      ;;
    *)
      [[ -z ${flake_dir} ]] || die "flake ディレクトリは 1 つだけ指定すること。"
      flake_dir=$1
      shift
      ;;
  esac
done

if [[ -z ${cmd} ]]; then
  usage >&2
  exit 2
fi

# 省略時の既定は flake-lock-age.sh と同じ規則 (script の隣、無ければカレント)。
if [[ -z ${flake_dir} ]]; then
  if [[ -f "${script_dir}/../flake.nix" ]]; then
    flake_dir="${script_dir}/.."
  else
    flake_dir=.
  fi
fi
[[ -d ${flake_dir} ]] || die "flake ディレクトリがありません: ${flake_dir}"
[[ -f ${flake_dir}/flake.nix ]] || die "flake.nix がありません: ${flake_dir}/flake.nix"
# 絶対パスにするのは、`--inputs-from` や installable が相対名を registry 名と
# 解釈しないようにするため ("nix" とだけ渡されると flake registry を引きに行く)。
flake_dir=$(
  cd -- "${flake_dir}" &>/dev/null
  pwd -P
)

# ディレクトリ ($1) が下にディレクトリを持つか (隠しディレクトリも数える。ディレクトリへの symlink は数えない)。
has_subdir() {
  local e
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [[ -d ${e} && ! -L ${e} ]]; then
      return 0
    fi
  done
  return 1
}

# nix に渡す flake ref (--inputs-from・nix build・nix eval)。flake だけのディレクトリ (下にディレクトリを持たない) は
# path: で読む。素のパスで渡すと、git の repo の中では nix が repo 全体 (追跡しているファイル。commit していない変更も)
# を /nix/store へ写してから評価し、作業ツリーが変わるたびに写しが増える。path: は git を見ずにディレクトリの中身を
# 全部写すので、下にディレクトリを持つ flake (dotfiles の nix/・skill のディレクトリ・repo の root) は今までどおり
# 素のパスで読む (書き出しや .git まで写さないため)。ファイル (whitelist・flake.lock・git の履歴) は flake_dir で読む。
flake_ref=${flake_dir}
if ! has_subdir "${flake_dir}"; then
  flake_ref="path:${flake_dir}"
fi

[[ -n ${whitelist} ]] || whitelist="${flake_dir}/vulnxscan-whitelist.csv"

# この script の隣の flake (dotfiles 本体。チェックアウトから叩いたときだけある)。
# 既定の属性と、sbomnix の退き先 (dotfiles の pin) に使う。
sibling=""
if [[ -f "${script_dir}/../flake.nix" ]]; then
  sibling=$(
    cd -- "${script_dir}/.." &>/dev/null
    pwd -P
  )
fi

# 対象属性の既定。dotfiles 本体 (この script の隣の flake) なら home 閉包、
# それ以外なら devShell。「lock が入れる、これから実行するもの」に合わせる。
# 明示指定かどうかは report の挙動に効くので覚えておく (既定属性が無い flake を
# update の自動差し込みで止めないため)。
attr_defaulted=0
if [[ -z ${attr} ]]; then
  attr_defaulted=1
  if [[ -n ${sibling} && ${flake_dir} == "${sibling}" ]]; then
    attr="homeConfigurations.sandbox.activationPackage"
  else
    system=$(nix eval --raw --impure --expr builtins.currentSystem) \
      || die "builtins.currentSystem が取れませんでした。"
    attr="devShells.${system}.default"
  fi
fi

################################
# sbomnix (vulnxscan) の用意   #
################################

# sbomnix (vulnxscan を同梱) が PATH に無ければ、nixpkgs の pin から組んで PATH の先頭に
# 足す (ensure_sbomnix。run_scan の始めに呼ぶ)。試す pin の順は:
#
#   1. 対象の pin。スキャナの版も、対象と同じ遅延の決まり (flake-lock-age.sh) に従わせる
#   2. dotfiles の pin。対象と違う pin のときだけ。チェックアウトから叩けばこの script の
#      隣の flake.lock、store の app (nix run …#closure-scan) なら flake.nix が store へ
#      写して渡す flake.lock (CLOSURE_SCAN_DOTFILES_FLAKE_LOCK にそのパス)
#   3. 対象の flake.lock の git の履歴にある前の pin。first-parent (merge された pin だけ)
#      を新しい順に、history_max_tries 個まで
#
# 2 と 3 も遅延を守って入れた pin (今の pin と同じか古い) なので、どれから取ってもスキャナ
# の遅延は守られる。nixpkgs で sbomnix の依存が壊れた pin でも (2026-10 の typepy 2.0.0)、
# スキャンそのものを落とさないための退き先。dotfiles 自身のスキャン (CI と setup の
# flake-update) では 2 が対象と同じ pin になるので、3 で前の pin へ退く (CI は履歴を全部
# 取る)。1 から取れなければ警告し、どこから取ったかは毎回 scanner.txt に残す。ADR 040。
#
# 2 と 3 の flake.lock を nix eval で読めなければ、黙って飛ばさず、わけを組めなかった pin に
# 並べて次へ進む (退いたときの警告と、止まるときの文に出る)。

# 前の pin をいくつまで試すか (同じ pin は数えず、読めなかった flake.lock は 1 つと数える) と、
# 履歴の commit をいくつまで見るか。
history_max_tries=3
history_max_commits=50

sbomnix_store=""    # 組めた sbomnix の store のパス
sbomnix_failures=() # 組めなかった pin の行 (「見出し ref (わけ)」)
sbomnix_tried=" "   # 組んだ pin の鍵 (nixpkgs の narHash)。同じ pin を二度組まない

# CLOSURE_SCAN_LOCK の flake.lock から、root の input nixpkgs の locked を「narHash<TAB>flake ref」
# で出す (nixpkgs の pin が無ければ空。JSON として読めなければ nix eval が落ちる)。narHash は同じ
# pin かを比べる鍵、ref は nix build に渡す形。
# flakeRefToString の無い古い nix では、github の形だけを組み立てる。
# shellcheck disable=SC2016 # Nix の式をそのまま書く (${…} は Nix の差し込み)
lock_nixpkgs_expr='
let
  lock = builtins.fromJSON (builtins.readFile (builtins.getEnv "CLOSURE_SCAN_LOCK"));
  node = lock.nodes.${lock.root}.inputs.nixpkgs or null;
  l = if builtins.isString node then lock.nodes.${node}.locked or { } else { };
  ref =
    if builtins ? flakeRefToString then builtins.flakeRefToString l
    else if (l.type or "") == "github" then "github:${l.owner}/${l.repo}/${l.rev}"
    else "";
in
if l ? narHash && ref != "" then "${l.narHash}\t${ref}" else ""
'

# nix eval のログ ($1) から、読めなかったわけを 1 行で出す。最後の error: の行 (いちばん内側のわけ。頭の
# error: は外す)、無ければ終了コード ($2)。
eval_failure_reason() {
  local line
  line=$(awk '
    /^[[:space:]]*error:[[:space:]]*[^[:space:]]/ { l = $0 }
    END {
      sub(/^[[:space:]]*error:[[:space:]]*/, "", l)
      print l
    }
  ' "$1")
  if [[ -n ${line} ]]; then
    printf '%s' "${line:0:200}"
    return 0
  fi
  printf 'nix eval の終了コード %s' "$2"
}

# flake.lock のファイル ($1。絶対パス) の nixpkgs の pin を、lock_row に「narHash<TAB>flake ref」で入れる
# (ファイルか pin が無ければ空)。nix eval で読めなければ、わけを lock_error に入れて 1 を返す。$(…) で
# 呼ばずにグローバルへ置くのは、pin とわけを分けて受け取るため。
lock_row=""
lock_error=""
read_lock_nixpkgs() {
  local eval_log rc=0
  lock_row=""
  lock_error=""
  [[ -f $1 ]] || return 0
  eval_log=$(mktemp "${out_dir}/lock-eval.XXXXXX")
  lock_row=$(CLOSURE_SCAN_LOCK=$1 nix eval --raw --impure --expr "${lock_nixpkgs_expr}" </dev/null 2>"${eval_log}") \
    || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    lock_row=""
    lock_error=$(eval_failure_reason "${eval_log}" "${rc}")
    rm -f "${eval_log}"
    return 1
  fi
  rm -f "${eval_log}"
}

# GitHub Actions の中なら、実行の画面の先頭に出る警告 (workflow command) を出す。本文の % と
# 改行は、GitHub の決まりどおりに書き換える。
annotate_warning() {
  local m=$1
  [[ ${GITHUB_ACTIONS-} == true ]] || return 0
  m=${m//'%'/'%25'}
  m=${m//$'\r'/'%0D'}
  m=${m//$'\n'/'%0A'}
  printf '::warning title=closure-scan::%s\n' "${m}"
}

# nix build のログ ($1) から、組めなかったわけを 1 行で出す。最初に組めなかった derivation
# の名前、無ければ最初の error: の行、それも無ければ終了コード ($2)。
build_failure_reason() {
  local log=$1 rc=$2 drv line
  drv=$(grep -o -m 1 -E "(Cannot build|builder for) '[^']*\.drv'" "${log}") || drv=""
  if [[ -n ${drv} ]]; then
    drv=${drv#*\'}
    drv=${drv%\'}
    drv=${drv##*/}
    drv=${drv#*-}
    printf '%s を組めない' "${drv%.drv}"
    return 0
  fi
  line=$(grep -m 1 '^error:' "${log}") || line=""
  if [[ -n ${line} ]]; then
    printf '%s' "${line:0:200}"
    return 0
  fi
  printf 'nix build の終了コード %s' "${rc}"
}

# sbomnix を 1 つの pin から組む。$1: 見出し、$2: pin の鍵 (空なら控えない)、$3: pin の ref
# (出す文のため)、残り: nix build の installable の引数。組めたら sbomnix_store を入れて 0、
# 組めなければ sbomnix_failures に足して 1。成果物のディレクトリに out-link (GC root) を張る
# ので、スキャンの途中で GC に消されない。nix の出力はその場に流し、わけを拾うために控える。
build_sbomnix() {
  local label=$1 key=$2 ref=$3 log captured rc=0
  shift 3
  if [[ -n ${key} ]]; then
    sbomnix_tried+="${key} "
  fi
  log=$(mktemp "${out_dir}/sbomnix-build.XXXXXX")
  step "sbomnix を組む (${label}): nix build $*"
  captured=$({ nix build --print-out-paths -o "${out_dir}/sbomnix" "$@" 2>&1 1>&3 | tee "${log}" >&2; } 3>&1 </dev/null) \
    || rc=$?
  captured=${captured%%$'\n'*}
  if [[ ${rc} -eq 0 && -x ${captured}/bin/sbomnix && -x ${captured}/bin/vulnxscan ]]; then
    sbomnix_store=${captured}
    rm -f "${log}"
    return 0
  fi
  if [[ ${rc} -eq 0 ]]; then
    sbomnix_failures+=("${label} ${ref} (組めたが bin/sbomnix か bin/vulnxscan が無い: ${captured})")
  else
    sbomnix_failures+=("${label} ${ref} ($(build_failure_reason "${log}" "${rc}"))")
  fi
  rm -f "${log}"
  return 1
}

# scanner.txt に、照らす sbomnix と出どころ、組めなかった pin を書く。$1: 1 行目 (sbomnix)、
# $2: 出どころの行 (空なら書かない)。
write_scanner() {
  local f
  {
    printf '%s\n' "$1"
    if [[ -n $2 ]]; then
      printf '出どころ: %s\n' "$2"
    fi
    for f in ${sbomnix_failures[@]+"${sbomnix_failures[@]}"}; do
      printf '組めなかった pin: %s\n' "${f}"
    done
  } >"${out_dir}/scanner.txt"
}

# 組めた sbomnix を PATH の先頭に足し、scanner.txt に残す。対象の pin でなければ警告する。
# $1: 見出し、$2: pin の ref。
use_sbomnix() {
  local label=$1 ref=$2 sbomnix_name f lines=()
  sbomnix_name=${sbomnix_store##*/}
  sbomnix_name=${sbomnix_name#*-}
  PATH="${sbomnix_store}/bin:${PATH}"
  write_scanner "${sbomnix_name} (${sbomnix_store})" "${label} ${ref}"
  if [[ ${label} == "対象の pin" ]]; then
    note "sbomnix: ${sbomnix_name} (対象の pin)"
    return 0
  fi
  lines=("sbomnix を対象の pin で組めなかったので、${label} の ${sbomnix_name} で照らします。"
    "取った pin: ${ref}")
  for f in ${sbomnix_failures[@]+"${sbomnix_failures[@]}"}; do
    lines+=("組めなかった pin: ${f}")
  done
  lines+=("findings の判定は変わりません。対象の pin で組めるようになれば (nixpkgs の直しが入った pin へ上げれば)、退かずに済みます。")
  warn "${lines[@]}"
  annotate_warning "$(printf '%s\n' "${lines[@]}")"
}

# sbomnix と vulnxscan を用意する。PATH にあればそれ、無ければ上の順に pin から組む。どれでも
# 組めなければ、試した pin とわけを並べて止まる。
ensure_sbomnix() {
  local key ref dotfiles_lock="" history_note="" c blob short label lock_copy tries=0 seen=" " f message
  local path_sbomnix version
  if path_sbomnix=$(command -v sbomnix) && command -v vulnxscan &>/dev/null; then
    version=$(sbomnix --version 2>/dev/null </dev/null) || version=""
    version=${version%%$'\n'*}
    write_scanner "sbomnix${version:+-${version}} (${path_sbomnix})" "PATH"
    note "sbomnix: PATH の ${path_sbomnix}"
    return 0
  fi
  command -v nix &>/dev/null \
    || die "sbomnix / vulnxscan が見つかりません (nix があれば nixpkgs の pin から組みます)。"

  # 1. 対象の pin。flake.lock を読めなくても --inputs-from で組む (読めないなら、組むときに nix が
  #    わけを出して落ちる)。読めた pin は、2 と 3 で同じ pin を二度組まないための鍵にする
  read_lock_nixpkgs "${flake_dir}/flake.lock" || true
  key=${lock_row%%$'\t'*}
  ref=${lock_row#*$'\t'}
  if build_sbomnix "対象の pin" "${key}" "${ref:-${flake_dir} の nixpkgs}" \
    --inputs-from "${flake_ref}" 'nixpkgs#sbomnix'; then
    use_sbomnix "対象の pin" "${ref:-${flake_dir} の nixpkgs}"
    return 0
  fi

  # 2. dotfiles の pin (対象と同じ pin なら組まない)
  if [[ -n ${sibling} ]]; then
    dotfiles_lock="${sibling}/flake.lock"
  else
    dotfiles_lock=${CLOSURE_SCAN_DOTFILES_FLAKE_LOCK-}
  fi
  if [[ -n ${dotfiles_lock} ]]; then
    if ! read_lock_nixpkgs "${dotfiles_lock}"; then
      sbomnix_failures+=("dotfiles の pin ${dotfiles_lock} (flake.lock を読めない: ${lock_error})")
    else
      key=${lock_row%%$'\t'*}
      ref=${lock_row#*$'\t'}
      if [[ -n ${lock_row} && ${sbomnix_tried} != *" ${key} "* ]] \
        && build_sbomnix "dotfiles の pin" "${key}" "${ref}" "${ref}#sbomnix"; then
        use_sbomnix "dotfiles の pin" "${ref}"
        return 0
      fi
    fi
  fi

  # 3. 対象の flake.lock の git の履歴にある前の pin
  if ! command -v git &>/dev/null \
    || ! git -C "${flake_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    history_note="対象は git の repo の中に無いので、前の pin はさかのぼっていません。"
  else
    lock_copy="${out_dir}/history-flake.lock"
    while read -r c; do
      [[ ${tries} -lt ${history_max_tries} ]] || break
      blob=$(git -C "${flake_dir}" rev-parse --verify --quiet "${c}:./flake.lock" </dev/null) || continue
      [[ ${seen} != *" ${blob} "* ]] || continue
      seen+="${blob} "
      git -C "${flake_dir}" cat-file blob "${blob}" >"${lock_copy}" </dev/null || continue
      short=$(git -C "${flake_dir}" rev-parse --short "${c}" </dev/null)
      label="対象の前の pin (commit ${short} の flake.lock)"
      # 読めない lock も 1 つと数える (nix が読めないわけがどの lock でも同じなら、並べすぎないため)
      if ! read_lock_nixpkgs "${lock_copy}"; then
        tries=$((tries + 1))
        sbomnix_failures+=("${label} (flake.lock を読めない: ${lock_error})")
        continue
      fi
      key=${lock_row%%$'\t'*}
      ref=${lock_row#*$'\t'}
      [[ -n ${lock_row} && ${sbomnix_tried} != *" ${key} "* ]] || continue
      tries=$((tries + 1))
      if build_sbomnix "${label}" "${key}" "${ref}" "${ref}#sbomnix"; then
        use_sbomnix "${label}" "${ref}"
        return 0
      fi
    done < <(git -C "${flake_dir}" log --first-parent --format=%H -n "${history_max_commits}" -- flake.lock 2>/dev/null)
    if [[ ${tries} -ge ${history_max_tries} ]]; then
      history_note="前の pin は新しい順に ${history_max_tries} つまで試しました。"
    elif [[ $(git -C "${flake_dir}" rev-parse --is-shallow-repository 2>/dev/null) == true ]]; then
      history_note="clone の履歴が浅い (shallow) ので、前の pin をさかのぼれませんでした。CI なら actions/checkout に fetch-depth: 0 を渡す。"
    else
      history_note="対象の flake.lock の git の履歴に、ほかの pin はありませんでした。"
    fi
  fi

  write_scanner "(sbomnix を組めなかった)" ""
  message="sbomnix を組めませんでした。試した pin:"
  for f in ${sbomnix_failures[@]+"${sbomnix_failures[@]}"}; do
    message+=$'\n'"  ${f}"
  done
  message+=$'\n'"${history_note}"
  message+=$'\n'"組める版の sbomnix (vulnxscan 同梱) を PATH に置けば、それで照らします。"
  die "${message}"
}

##########
# 共通   #
##########

if [[ -z ${out_dir} ]]; then
  out_dir=$(mktemp -d)
fi
mkdir -p "${out_dir}"
# 絶対パスにする。前の pin の flake.lock をここへ写して nix の式 (builtins.readFile) で読むが、readFile は
# 相対パスを受けない ("string './…' doesn't represent an absolute path")。CI は --out-dir に相対パスを渡す。
out_dir=$(cd -- "${out_dir}" && pwd -P) || die "--out-dir のディレクトリに入れません: ${out_dir}"

# vulnxscan の csv は全フィールドが quote される (pandas の QUOTE_ALL)。
# `","` で切って残った quote を剥ぐ。フィールドに `","` を含む値は入らない前提
# (vuln_id / URL / パッケージ名 / 数値と、自分たちで書く comment だけ)。
#
# findings を「vuln_id<TAB>package」で出す (重複あり)。
# mode=new は whitelist 列が False の行だけ、all は全行。
csv_pairs() {
  awk -F'","' -v mode="$2" '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        f = $i
        gsub(/"/, "", f)
        col[f] = i
      }
      next
    }
    {
      i = col["vuln_id"]
      p = col["package"]
      id = $i
      pkg = $p
      gsub(/"/, "", id)
      gsub(/"/, "", pkg)
      if (mode == "new") {
        w = col["whitelist"]
        wl = $w
        gsub(/"/, "", wl)
        if (wl != "False") next
      }
      print id "\t" pkg
    }
  ' "$1"
}

# vulns.csv ($1) から findings の表 (report.txt の中身) を出す。whitelist の列があれば、それが False の行
# (whitelist に無い findings。門と同じ判定) を表にし、受け入れた findings は件数だけを添える (一覧は vulns.csv)。
# 列が無ければ (whitelist を当てない report) 全部の行を表にする。件数は門 (new-findings.txt) と同じく vuln_id と
# package の組で数え、同じ組の版ちがいで行が増えたら行の数も添える。列は名前で引く (vulnxscan の版で並びや
# 有無が変わる。版の列は version_local、古い形は version)。
report_table() {
  awk -F'","' '
    function field(c, v) {
      if (!(c in col)) return ""
      v = $(col[c])
      gsub(/"/, "", v)
      return v
    }
    BEGIN {
      split("vuln_id package version severity scanner url", head, " ")
      split("grype osv vulnix", scanner_name, " ")
      for (j = 1; j <= 6; j++) {
        cell[0, j] = head[j]
        w[j] = length(head[j])
      }
    }
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        f = $i
        gsub(/"/, "", f)
        col[f] = i
      }
      version = ("version_local" in col) ? "version_local" : "version"
      has_wl = ("whitelist" in col)
      next
    }
    $0 == "" { next }
    {
      id = field("vuln_id")
      pkg = field("package")
      if (has_wl && field("whitelist") != "False") {
        if (!((id, pkg) in accepted)) {
          accepted[id, pkg] = 1
          n_accepted++
        }
        next
      }
      if (!((id, pkg) in pairs)) {
        pairs[id, pkg] = 1
        n_pairs++
      }
      # 照らしたスキャナの列 (1 か 0) のうち、見つけたものを並べる
      scanners = ""
      for (k = 1; k <= 3; k++) {
        v = field(scanner_name[k])
        if (v + 0 > 0 || v == "True") scanners = scanners (scanners == "" ? "" : ", ") scanner_name[k]
      }
      n_rows++
      cell[n_rows, 1] = id
      cell[n_rows, 2] = pkg
      cell[n_rows, 3] = field(version)
      cell[n_rows, 4] = field("severity")
      cell[n_rows, 5] = scanners
      cell[n_rows, 6] = field("url")
      for (j = 1; j <= 6; j++) {
        if (length(cell[n_rows, j]) > w[j]) w[j] = length(cell[n_rows, j])
      }
    }
    END {
      label = has_wl ? "whitelist に無い findings" : "findings"
      notes = ""
      if (n_rows > n_pairs) notes = "版ごとに " n_rows " 行"
      if (!has_wl) notes = notes (notes == "" ? "" : "。") "whitelist は当てていない"
      if (n_pairs > 0) {
        printf "%s: %d 件", label, n_pairs
      } else {
        printf "%s: なし", label
      }
      if (notes != "") printf " (%s)", notes
      printf "\n"
      if (n_rows > 0) {
        sep = "|"
        for (j = 1; j <= 6; j++) {
          dashes = ""
          for (k = 0; k < w[j] + 2; k++) dashes = dashes "-"
          sep = sep dashes (j < 6 ? "+" : "|")
        }
        printf "\n"
        for (r = 0; r <= n_rows; r++) {
          line = "|"
          for (j = 1; j <= 6; j++) line = line sprintf(" %-" w[j] "s |", cell[r, j])
          print line
          if (r == 0) print sep
        }
      }
      if (has_wl) {
        printf "\n"
        if (n_accepted > 0) {
          printf "whitelist で受け入れた findings: %d 件 (一覧は vulns.csv)\n", n_accepted
        } else {
          print "whitelist で受け入れた findings: なし"
        }
      }
    }
  ' "$1"
}

# findings の表を report.txt に書き、stdout にも出す (CI は summary に貼る)。vulnxscan も表を出すが、版によって
# stdout にも stderr (ログ) にも出る (sbomnix 1.8.0・1.9.0 は INFO のログとして stderr) ので拾わず、vulns.csv から
# 作る。vulns.csv が無ければ (findings が 1 件も無いと vulnxscan は書かない)「なし」と書く。
write_report() {
  step "findings の表 (vulns.csv から作り、report.txt に書く)"
  if [[ -f ${out_dir}/vulns.csv ]]; then
    report_table "${out_dir}/vulns.csv" >"${out_dir}/report.txt"
  else
    printf 'findings: なし (vulnxscan は vulns.csv を書かなかった)\n' >"${out_dir}/report.txt"
  fi
  cat "${out_dir}/report.txt"
}

# whitelist csv の既存 (vuln_id, package) を同じ形で出す (baseline の重複防止用)。
whitelist_pairs() {
  awk -F'","' '
    NR == 1 { next }
    {
      id = $1
      pkg = $2
      gsub(/"/, "", id)
      gsub(/"/, "", pkg)
      print id "\t" pkg
    }
  ' "$1"
}

# scan / baseline は 1 (whitelist 必須・照合)、report は 0 (あれば適用するだけ)。
scan_gate=1

run_scan() {
  local wl_args=() header
  # 前の実行の findings と表を消す。--out-dir を使い回すと、vulns.csv を書かない実行 (findings が 0 件) が
  # 前の vulns.csv を読んでしまう。途中で落ちた実行に、前の表を残さないためでもある。
  rm -f "${out_dir}/vulns.csv" "${out_dir}/report.txt" "${out_dir}/new-findings.txt"
  if [[ -f ${whitelist} ]]; then
    wl_args=(--whitelist "${whitelist}")
  elif [[ ${scan_gate} -eq 1 ]]; then
    # baseline は先にヘッダだけのファイルを作ってからここへ来る。
    die "whitelist がありません: ${whitelist}
(初回は closure-scan.sh baseline で作ること。空の基準線から始めるならヘッダ行
\"vuln_id\",\"package\",\"comment\" だけのファイルを置く。ゲートせず眺めるだけなら
report を使う。)"
  else
    note "whitelist が無いので全 findings を表示します。"
  fi

  # 閉包のビルド (長い) より先に用意する。組めなければ閉包を組まずに止まる。
  ensure_sbomnix

  step "nix build ${flake_ref}#${attr}"
  nix build "${flake_ref}#${attr}" -o "${out_dir}/closure"
  target=$(readlink -f "${out_dir}/closure")
  note "閉包: ${target}"

  step "sbomnix (SBOM の書き出し)"
  sbomnix "${target}" \
    --csv "${out_dir}/sbom.csv" \
    --cdx "${out_dir}/sbom.cdx.json" \
    --spdx "${out_dir}/sbom.spdx.json"

  if [[ -n ${wl_args[*]+x} ]]; then
    step "vulnxscan (OSV + Grype + vulnix, whitelist 適用)"
  else
    step "vulnxscan (OSV + Grype + vulnix)"
  fi
  # 出力はそのまま流す。report.txt の表は、vulnxscan の出力からではなく vulns.csv から作る (write_report)。
  vulnxscan "${target}" -o "${out_dir}/vulns.csv" ${wl_args[@]+"${wl_args[@]}"}

  # findings が 1 件も無いと csv 自体が書かれない。
  if [[ ! -f ${out_dir}/vulns.csv ]]; then
    : >"${out_dir}/new-findings.txt"
    write_report
    return 0
  fi
  if [[ -n ${wl_args[*]+x} ]]; then
    # whitelist 列が無い = whitelist が読まれていない (列不足などで黙って無視される)。
    # 1 行目を変数に読んでから比べる (パイプの先の grep -q が合った時点で抜けると、
    # head が SIGPIPE で落ち、pipefail で「列が無い」に見えることがあるため)。
    IFS= read -r header <"${out_dir}/vulns.csv" || header=""
    [[ ${header} == *'"whitelist"'* ]] \
      || die "vulns.csv に whitelist 列がありません。whitelist が読めていない可能性:
${whitelist}"
    csv_pairs "${out_dir}/vulns.csv" new | sort -u >"${out_dir}/new-findings.txt"
  else
    csv_pairs "${out_dir}/vulns.csv" all | sort -u >"${out_dir}/new-findings.txt"
  fi
  write_report
}

report_paths() {
  note "成果物: ${out_dir}"
  note "  sbom.cdx.json / sbom.spdx.json / sbom.csv (SBOM)"
  note "  vulns.csv (findings 全件。whitelist があれば判定の列つき)"
  note "  report.txt (上に出した findings の表。vulns.csv から作る。CI は summary に貼る)"
  note "  new-findings.txt (whitelist に無い findings。whitelist が無ければ全件)"
  note "  scanner.txt (照らした sbomnix と、どの pin から取ったか)"
}

cmd_scan() {
  local n
  run_scan
  report_paths
  # wc の出力は BSD だと空白詰めなので数値に正規化する。
  n=$(($(wc -l <"${out_dir}/new-findings.txt")))
  if [[ ${n} -gt 0 ]]; then
    die "whitelist に無い findings が ${n} 件あります (上の表)。
対応は 2 択:
  1. pin を動かして直るか見る: flake-lock-age.sh resolve / update
     (修正が下限日数より新しい側にしか無いなら --min-age-days を下げる判断も含む)
  2. 意図して受け入れる: closure-scan.sh baseline で whitelist へ追記し、
     追記された comment に理由を書いてから commit する"
  fi
  printf 'OK: whitelist に無い findings はありません。\n'
}

cmd_report() {
  local n
  scan_gate=0
  # 既定属性が無い flake は黙って通す。flake-lock-age.sh update が完了時に自動で
  # ここを差し込むので、スキャン対象を持たない flake (devShell の無い flake など)
  # で update まで失敗させないため。--attr で明示されたときは普通に落ちる。
  if [[ ${attr_defaulted} -eq 1 ]] \
    && ! nix eval --raw "${flake_ref}#${attr}.drvPath" &>/dev/null; then
    warn "${flake_dir} に ${attr} が無いのでスキャンを飛ばします (--attr で指定すれば見ます)。"
    return 0
  fi
  run_scan
  report_paths
  n=$(($(wc -l <"${out_dir}/new-findings.txt")))
  if [[ ${n} -eq 0 ]]; then
    printf '表示すべき findings はありません。\n'
    return 0
  fi
  # findings があっても落とさないのが report の仕様 (眺めるための形)。
  if [[ -f ${whitelist} ]]; then
    printf '%s 件の findings が whitelist の外にあります (上の表)。\n' "${n}"
    printf 'ゲートに載せるなら closure-scan.sh baseline で受け入れてから scan を使う。\n'
  else
    printf '%s 件の findings があります (上の表)。ツールを実行する前に目を通すこと。\n' "${n}"
    printf '基準線を作ってゲート化するなら closure-scan.sh baseline。\n'
  fi
}

cmd_baseline() {
  local today n added=0 id pkg pair existing
  # 初回はここで作る (run_scan は whitelist を要求する)。
  if [[ ! -f ${whitelist} ]]; then
    printf '"vuln_id","package","comment"\n' >"${whitelist}"
    note "whitelist を新規に作りました: ${whitelist}"
  fi
  run_scan
  today=$(date -u +%Y-%m-%d)
  # 既存の行と重複させない。既存の vuln_id は正規表現だが、ここでは文字列として
  # 同一の行を弾ければ十分 (regex で既に緩く受けている行があるなら scan の段階で
  # whitelist 済みになっていて new-findings に出てこない)。既存の組は変数に取って
  # から比べ、足した組も足していく (パイプの先に grep -q を置くと、合った時点で抜けた
  # grep に awk が SIGPIPE で落ち、pipefail で「無い」に見えて二重に足すことがあるため)。
  existing=$(whitelist_pairs "${whitelist}")
  while IFS=$'\t' read -r id pkg; do
    [[ -n ${id} ]] || continue
    pair=$(printf '%s\t%s' "${id}" "${pkg}")
    if grep -Fxq -- "${pair}" <<<"${existing}"; then
      continue
    fi
    printf '"%s","%s","baseline (%s): この時点の既知として受け入れ。理由は棚卸しで追記"\n' \
      "${id}" "${pkg}" "${today}" >>"${whitelist}"
    existing+=$'\n'"${pair}"
    added=$((added + 1))
  done <"${out_dir}/new-findings.txt"
  report_paths
  n=$(($(wc -l <"${out_dir}/new-findings.txt")))
  if [[ ${added} -eq 0 ]]; then
    printf 'whitelist への追記はありません (新規 findings %s 件)。\n' "${n}"
    return 0
  fi
  printf '%s 件を whitelist へ追記しました: %s\n' "${added}" "${whitelist}"
  printf 'git diff で内容を確認し、comment に受け入れの理由を書いてから commit すること。\n'
}

case ${cmd} in
  scan) cmd_scan ;;
  report) cmd_report ;;
  baseline) cmd_baseline ;;
esac
