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
# 1. 対象の閉包をビルドする (binary cache があれば実体はダウンロード)
# 2. sbomnix で SBOM (CycloneDX / SPDX / csv) を書き出す
#    (vulnxscan も内部で SBOM を作るが保存しないので、成果物として別に残す)
# 3. vulnxscan で runtime 閉包をスキャンし、whitelist に無い findings があれば
#    終了コード 1 で落ちる (CI のゲート)
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
# ## 依存
#
# nix / coreutils / awk。sbomnix (vulnxscan を同梱) が PATH に無ければ、対象
# flake の **pin された nixpkgs** から `nix shell --inputs-from` で入り直す。
# スキャナ自身の版も flake.lock と同じ遅延ポリシーに従わせるための形。

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

warn() {
  printf '%s!! %s%s\n' "${c_yellow}" "$*" "${c_reset}" >&2
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
無ければカレントディレクトリを対象にする。

whitelist は「安全と確認した」印ではなく増分検知の基準線。列は
"vuln_id","package","comment" で、vuln_id は正規表現 (完全一致)、package は
完全一致。詳細は ADR 006。
EOS
}

##########
# 引数   #
##########

# sbomnix が無いときに同じ引数で入り直すため、解釈前に取っておく。
orig_args=("$@")

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

[[ -n ${whitelist} ]] || whitelist="${flake_dir}/vulnxscan-whitelist.csv"

# 対象属性の既定。dotfiles 本体 (この script の隣の flake) なら home 閉包、
# それ以外なら devShell。「lock が入れる、これから実行するもの」に合わせる。
# 明示指定かどうかは report の挙動に効くので覚えておく (既定属性が無い flake を
# update の自動差し込みで止めないため)。
attr_defaulted=0
if [[ -z ${attr} ]]; then
  attr_defaulted=1
  sibling=""
  if [[ -f "${script_dir}/../flake.nix" ]]; then
    sibling=$(
      cd -- "${script_dir}/.." &>/dev/null
      pwd -P
    )
  fi
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

# PATH に無ければ、対象 flake の pin された nixpkgs から取って入り直す。
# 印 (CLOSURE_SCAN_REEXEC) は無限ループ防止 (pjp-nix-flake skill の再入パターン)。
if ! command -v vulnxscan &>/dev/null || ! command -v sbomnix &>/dev/null; then
  if [[ -z ${CLOSURE_SCAN_REEXEC:-} ]] && command -v nix &>/dev/null; then
    export CLOSURE_SCAN_REEXEC=1
    step "sbomnix が無いので pin された nixpkgs から入り直します"
    exec nix shell --inputs-from "${flake_dir}" 'nixpkgs#sbomnix' \
      --command "$0" "${orig_args[@]}"
  fi
  die "sbomnix / vulnxscan が見つかりません (nix があれば自動で入り直します)。"
fi

##########
# 共通   #
##########

if [[ -z ${out_dir} ]]; then
  out_dir=$(mktemp -d)
fi
mkdir -p "${out_dir}"

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
  local wl_args=()
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

  step "nix build ${flake_dir}#${attr}"
  nix build "${flake_dir}#${attr}" -o "${out_dir}/closure"
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
  # 表は stdout、ログは stderr。表を report.txt に残して CI の summary に使う。
  vulnxscan "${target}" -o "${out_dir}/vulns.csv" ${wl_args[@]+"${wl_args[@]}"} \
    | tee "${out_dir}/report.txt"

  # findings が 1 件も無いと csv 自体が書かれない。
  if [[ ! -f ${out_dir}/vulns.csv ]]; then
    note "findings なし (vulns.csv は書かれませんでした)。"
    : >"${out_dir}/new-findings.txt"
    return 0
  fi
  if [[ -n ${wl_args[*]+x} ]]; then
    # whitelist 列が無い = whitelist が読まれていない (列不足などで黙って無視される)。
    head -n 1 "${out_dir}/vulns.csv" | grep -q '"whitelist"' \
      || die "vulns.csv に whitelist 列がありません。whitelist が読めていない可能性:
${whitelist}"
    csv_pairs "${out_dir}/vulns.csv" new | sort -u >"${out_dir}/new-findings.txt"
  else
    csv_pairs "${out_dir}/vulns.csv" all | sort -u >"${out_dir}/new-findings.txt"
  fi
}

report_paths() {
  note "成果物: ${out_dir}"
  note "  sbom.cdx.json / sbom.spdx.json / sbom.csv (SBOM)"
  note "  vulns.csv (findings 全件。whitelist があれば判定の列つき)"
  note "  report.txt (表示された表)"
  note "  new-findings.txt (whitelist に無い findings。whitelist が無ければ全件)"
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
    && ! nix eval --raw "${flake_dir}#${attr}.drvPath" &>/dev/null; then
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
  local today n added=0 id pkg pair
  # 初回はここで作る (run_scan は whitelist を要求する)。
  if [[ ! -f ${whitelist} ]]; then
    printf '"vuln_id","package","comment"\n' >"${whitelist}"
    note "whitelist を新規に作りました: ${whitelist}"
  fi
  run_scan
  today=$(date -u +%Y-%m-%d)
  # 既存の行と重複させない。既存の vuln_id は正規表現だが、ここでは文字列として
  # 同一の行を弾ければ十分 (regex で既に緩く受けている行があるなら scan の段階で
  # whitelist 済みになっていて new-findings に出てこない)。
  while IFS=$'\t' read -r id pkg; do
    [[ -n ${id} ]] || continue
    pair=$(printf '%s\t%s' "${id}" "${pkg}")
    if whitelist_pairs "${whitelist}" | grep -Fxq "${pair}"; then
      continue
    fi
    printf '"%s","%s","baseline (%s): この時点の既知として受け入れ。理由は棚卸しで追記"\n' \
      "${id}" "${pkg}" "${today}" >>"${whitelist}"
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
