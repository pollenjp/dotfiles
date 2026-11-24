#!/usr/bin/env bash
# shellcheck shell=bash
#
# git が追う Cargo.lock を、osv-scanner で OSV (RustSec・GHSA を含む) の既知の脆弱性と照らす。
#
#   check-cargo-lock-vulns.sh [--out-dir <ディレクトリ>]
#
# 照らすのは、repo の root で git ls-files が出す Cargo.lock の全部 (今は win/runner・nix/pkgs/claude-selector・
# nix/pkgs/pjp-ghq-pull)。dotfiles が build する Rust の道具は、どれも Cargo.lock に書いた版で作る (Windows の runner と手順
# claude-selector は cargo の --locked、Linux の pjp-ghq-pull と claude-selector は Nix の cargoLock.lockFile) ので、lock を照らせば
# 入るものを照らせる。Cargo.lock を足しても、git に入れれば (CI では commit すれば) ここを直さずに拾う。
#
# GitHub Actions の cargo-lock-vulns (.github/workflows/cargo-lock-vulns.yml) が、Cargo.lock・Cargo.toml・受け入れを変える PR と
# main への push、毎朝の定期実行 (advisory は lock より後から出る) で流し、落ちることで知らせる。手元でも打てる。落ちたときの
# 直し方は nix/README.md の「Cargo.lock の既知の脆弱性 (osv-scanner)」、決めたわけは dotfiles-private の
# docs/adr/097_cargo_lock_osv_scan_*。
#
# ## 受け入れ
#
# 直せない advisory (直した版が無い・直した版が猶予の 7 日の内側・直すと semver の major をまたぐ) は、その Cargo.lock と同じ
# ディレクトリの osv-scanner.toml に、理由と期限をつけて書く。osv-scanner は -L で渡した lockfile と同じディレクトリの
# osv-scanner.toml だけを読み、ignoreUntil の日の 0 時 (UTC) より前の間だけ、その advisory を外す (その日から再び出て、ここが
# 落ちる)。月 1 回の依存の更新 (pjp-dep-update) も同じ osv-scanner に -L で渡すので、同じ受け入れが効く。
#
#   [[IgnoredVulns]]
#   id = "RUSTSEC-YYYY-NNNN"
#   ignoreUntil = YYYY-MM-DD
#   reason = "受け入れるわけ (直した版が無い・…)"
#
# osv-scanner は reason と ignoreUntil が無くても読み (期限の無い受け入れになる)、読めない書き方のファイルは黙って捨てるので、
# osv-scanner に渡す前にここで書き方を確かめる。書けるのは [[IgnoredVulns]] の表と、その中の id (引用符で囲んだ advisory の ID)・
# ignoreUntil (引用符の無い暦の日付。今日 (UTC) から 90 日先まで)・reason (引用符で囲んだ、空白だけでない文字列) を 1 つずつと、
# # のコメントと空行だけ。ほかの表 (PackageOverrides など)・key・書き方 (複数行の文字列・単引用符・行末のコメント・インラインの表)・
# 同じファイルの同じ id の 2 度目・[[IgnoredVulns]] の無いファイル・隣に git の追う Cargo.lock が無いもの (osv-scanner が読まない)・
# 照らす Cargo.lock の隣にあって git が追っていないもの (osv-scanner は読むが、CI には無い) は書き損じとして止める。ignoreUntil を
# 過ぎた項目は止めずに知らせる (GitHub Actions では ::warning の行)。
#
# ## 終了コード
#
# 0 = 受け入れていない advisory が無い、1 = ある (osv-scanner の表と直し方を出す)、2 = 照らせなかった (git の追う Cargo.lock が
# 無い・受け入れの書き損じ・osv-scanner が無い・落ちた・知らない引数)。GitHub Actions の中では、落ちる理由を ::error の行にも出す。
# --out-dir を渡すと、照らした Cargo.lock・受け入れ・osv-scanner の表を <ディレクトリ>/report.md にも書く (CI が summary に貼る)。
#
# ## 依存
#
# bash (4.4 以上)・git・osv-scanner。osv-scanner が PATH に無ければ、repo の flake (nix/) が固定している nixpkgs の osv-scanner へ
# nix shell で入り直す (スキャナの版も flake.lock の遅延に従う。CI は nix shell の中から直に呼ぶ)。日付は TZ を UTC にして数える
# (CI のランナーと同じ。osv-scanner の ignoreUntil の読み方もそろう)。テストは今の時刻を CHECK_CARGO_LOCK_VULNS_NOW (UNIX 秒) で
# 決める。

set -eu -o pipefail
# 想定外の失敗 (set -e で止まるもの) も「照らせなかった」の 2 で終える (1 は受け入れていない advisory があるときだけ)
set -E
trap 'exit 2' ERR

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
flake_dir=$(dirname "${script_dir}")
repo_dir=$(dirname "${flake_dir}")

# 受け入れの ignoreUntil に書ける、今日から何日先まで
max_accept_days=90
readme_section='nix/README.md の「Cargo.lock の既知の脆弱性 (osv-scanner)」'

usage() {
  cat <<'EOS'
git が追う Cargo.lock を、osv-scanner で OSV (RustSec・GHSA を含む) の既知の脆弱性と照らす。

使い方:
  check-cargo-lock-vulns.sh [--out-dir <ディレクトリ>]

  --out-dir  照らした Cargo.lock・受け入れ・osv-scanner の表を <ディレクトリ>/report.md にも書く

受け入れ (直せない advisory) は、その Cargo.lock と同じディレクトリの osv-scanner.toml に [[IgnoredVulns]] の
id・ignoreUntil (90 日先まで)・reason で書く。

終了コード: 0 = 受け入れていない advisory が無い、1 = ある、2 = 照らせなかった
EOS
}

# GitHub Actions の中なら、::error・::warning の行にも出す (% と改行は workflow command の決まりでエスケープする)。$1: error か warning
annotate() {
  [[ ${GITHUB_ACTIONS-} == true ]] || return 0
  local level=$1 msg=$2
  msg=${msg//'%'/'%25'}
  msg=${msg//$'\r'/'%0D'}
  msg=${msg//$'\n'/'%0A'}
  printf '::%s title=Cargo.lock の既知の脆弱性::%s\n' "${level}" "${msg}"
}

out_dir=
want_out_dir=0
for arg in "$@"; do
  if ((want_out_dir)); then
    out_dir=${arg}
    want_out_dir=0
    continue
  fi
  case ${arg} in
    --out-dir) want_out_dir=1 ;;
    --out-dir=?*) out_dir=${arg#--out-dir=} ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done
if ((want_out_dir)); then
  echo "--out-dir の後ろにディレクトリが要ります" >&2
  usage >&2
  exit 2
fi

if ! command -v osv-scanner &>/dev/null; then
  if [[ -z ${CHECK_CARGO_LOCK_VULNS_REEXEC:-} ]] && command -v nix &>/dev/null; then
    export CHECK_CARGO_LOCK_VULNS_REEXEC=1
    exec nix shell --inputs-from "${flake_dir}" nixpkgs#osv-scanner --command "$0" "$@"
  fi
  echo "!! osv-scanner が要ります。nix があれば、repo の flake (nix/) の nixpkgs の osv-scanner へ自動で入り直します。" >&2
  annotate error "osv-scanner がありません"
  exit 2
fi

export TZ=UTC
now=${CHECK_CARGO_LOCK_VULNS_NOW:-}
if [[ -z ${now} ]]; then
  printf -v now '%(%s)T' -1
fi
if [[ ! ${now} =~ ^[0-9]+$ ]]; then
  echo "!! CHECK_CARGO_LOCK_VULNS_NOW は UNIX 秒 (0 以上の整数) で書きます: ${now}" >&2
  exit 2
fi
printf -v today '%(%Y-%m-%d)T' "${now}"
printf -v accept_until_max '%(%Y-%m-%d)T' "$((now + max_accept_days * 86400))"

if [[ -n ${out_dir} ]]; then
  # 後で repo の root へ移るので、呼んだ所から読んだ絶対のパスにしておく
  if ! mkdir -p -- "${out_dir}" || ! out_abs=$(cd -- "${out_dir}" && pwd -P); then
    echo "!! --out-dir のディレクトリを作れません: ${out_dir}" >&2
    exit 2
  fi
  out_dir=${out_abs}
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/check-cargo-lock-vulns.XXXXXX")
trap 'rm -rf "${work}"' EXIT
report=${work}/report.md

cd -- "${repo_dir}"

# 書いた report を stdout と --out-dir へ出して終わる。$1: 終了コード
finish() {
  cat -- "${report}"
  if [[ -n ${out_dir} ]]; then
    cp -- "${report}" "${out_dir}/report.md"
  fi
  exit "$1"
}

# git の追うファイル (NUL 区切り。パスに何が入っても崩れない)
if ! git ls-files -z -- ':(glob)**/Cargo.lock' >"${work}/lockfiles" \
  || ! git ls-files -z -- ':(glob)**/osv-scanner.toml' >"${work}/accept-files"; then
  echo "!! git の追うファイルを読めません (git の work tree の中の script を打ちます): ${repo_dir}" >&2
  annotate error "git の追うファイルを読めません"
  exit 2
fi
mapfile -d '' -t lockfiles <"${work}/lockfiles"
mapfile -d '' -t accept_files <"${work}/accept-files"
if ((${#lockfiles[@]} == 0)); then
  echo "!! git の追う Cargo.lock がありません (照らすものが無い): ${repo_dir}" >&2
  annotate error "git の追う Cargo.lock がありません"
  exit 2
fi

{
  echo "照らした Cargo.lock (git が追うもの。${#lockfiles[@]} 個):"
  echo
  printf -- "- \`%s\`\n" "${lockfiles[@]}"
  echo
} >"${report}"

# ---- 受け入れ (osv-scanner.toml) の書き方を確かめる ----

problems=()
warnings=()
accepted=()
declare -A tracked_lock=() tracked_accept=() seen_accept=()
for f in "${lockfiles[@]}"; do
  tracked_lock[${f}]=1
done
for f in "${accept_files[@]}"; do
  tracked_accept[${f}]=1
done

# $1: repo の root からのパスと同じディレクトリの、$2 という名前のファイル
beside() {
  if [[ $1 == */* ]]; then
    printf '%s/%s\n' "${1%/*}" "$2"
  else
    printf '%s\n' "$2"
  fi
}

re_kv='^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$'
# 引用符で囲んだ文字列 (TOML の basic string を 1 行で。中の " は \" と書く)
re_str='^"(([^"\\]|\\.)*)"$'
re_id='^[A-Za-z0-9][A-Za-z0-9._:-]*$'
re_date='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'

# $1: YYYY-MM-DD (re_date に合うもの) が暦にある日か
calendar_date() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) last=31
  case ${m} in
    2)
      last=28
      if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then
        last=29
      fi
      ;;
    4 | 6 | 9 | 11) last=30 ;;
  esac
  ((d <= last))
}

# 読んでいる受け入れのファイル (cur_file) と [[IgnoredVulns]] の項目 (e_at: 表の行。0 なら項目の外。e_has: 書いた key)
cur_file=
e_at=0
declare -A e_has=()
open_entry() {
  e_at=$1
  e_id='' e_until='' e_reason='' e_bad=0
  e_has=()
}

# 読んでいる項目を締める
close_entry() {
  local missing=() k
  ((e_at)) || return 0
  for k in id ignoreUntil reason; do
    if [[ -z ${e_has[${k}]+x} ]]; then
      missing+=("${k}")
    fi
  done
  if ((${#missing[@]})); then
    problems+=("${cur_file}:${e_at}: [[IgnoredVulns]] に ${missing[*]} がありません (id・ignoreUntil・reason の 3 つを書く)")
    return 0
  fi
  if ((e_bad)); then
    return 0
  fi
  if [[ -n ${seen_accept["${cur_file}|${e_id}"]+x} ]]; then
    problems+=("${cur_file}:${e_at}: ${e_id} は 2 度目です")
    return 0
  fi
  seen_accept["${cur_file}|${e_id}"]=1
  if [[ ${e_until} > ${accept_until_max} ]]; then
    problems+=("${cur_file}:${e_at}: ${e_id} の ignoreUntil (${e_until}) が ${max_accept_days} 日より先です (${accept_until_max} までにする)")
  elif [[ ${e_until} > ${today} ]]; then
    accepted+=("${cur_file}: ${e_id} (ignoreUntil ${e_until}): ${e_reason}")
  else
    warnings+=("${cur_file}:${e_at}: ${e_id} の ignoreUntil (${e_until}) を過ぎました (今日は ${today}。osv-scanner はもう外しません)。直したなら項目を消し、まだ受け入れるなら理由と期限を書き直します")
  fi
}

# $1: 受け入れのファイル (repo の root からのパス)
check_accept_file() {
  local lineno=0 entries=0 line key value
  cur_file=$1
  e_at=0
  if [[ ! -f ${cur_file} ]]; then
    problems+=("${cur_file}: git が追っているのに、作業ツリーにありません")
    return 0
  fi
  while IFS= read -r line || [[ -n ${line} ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    if [[ -z ${line} || ${line} == '#'* ]]; then
      continue
    fi
    if [[ ${line} == '[[IgnoredVulns]]' ]]; then
      close_entry
      open_entry "${lineno}"
      entries=$((entries + 1))
      continue
    fi
    if [[ ${line} == '['* ]]; then
      problems+=("${cur_file}:${lineno}: 書ける表は [[IgnoredVulns]] だけです: ${line}")
      e_bad=1
      continue
    fi
    if [[ ! ${line} =~ ${re_kv} ]]; then
      problems+=("${cur_file}:${lineno}: 読めない行です (書けるのは [[IgnoredVulns]] と、その中の id・ignoreUntil・reason の行): ${line}")
      e_bad=1
      continue
    fi
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if ((e_at == 0)); then
      problems+=("${cur_file}:${lineno}: [[IgnoredVulns]] の外に値があります: ${line}")
      continue
    fi
    case ${key} in
      id | ignoreUntil | reason) ;;
      *)
        problems+=("${cur_file}:${lineno}: 知らない key です (書けるのは id・ignoreUntil・reason): ${key}")
        e_bad=1
        continue
        ;;
    esac
    if [[ -n ${e_has[${key}]+x} ]]; then
      problems+=("${cur_file}:${lineno}: 1 つの [[IgnoredVulns]] に ${key} が 2 つあります")
      e_bad=1
      continue
    fi
    e_has[${key}]=1
    case ${key} in
      id)
        if [[ ${value} =~ ${re_str} ]] && [[ ${BASH_REMATCH[1]} =~ ${re_id} ]]; then
          e_id=${value:1:${#value}-2}
        else
          problems+=("${cur_file}:${lineno}: id は引用符で囲んだ advisory の ID (\"RUSTSEC-YYYY-NNNN\" など) で書きます: ${value}")
          e_bad=1
        fi
        ;;
      ignoreUntil)
        if [[ ${value} =~ ${re_date} ]] && calendar_date "${value}"; then
          e_until=${value}
        else
          problems+=("${cur_file}:${lineno}: ignoreUntil は引用符の無い暦の日付 (YYYY-MM-DD) で書きます: ${value}")
          e_bad=1
        fi
        ;;
      reason)
        if [[ ${value} =~ ${re_str} ]] && [[ -n ${BASH_REMATCH[1]//[[:space:]]/} ]]; then
          e_reason=${value:1:${#value}-2}
        else
          problems+=("${cur_file}:${lineno}: reason は引用符で囲んだ、空白だけでない文字列で書きます: ${value}")
          e_bad=1
        fi
        ;;
    esac
  done <"${cur_file}"
  close_entry
  if ((entries == 0)); then
    problems+=("${cur_file}: [[IgnoredVulns]] がありません (受け入れが無いなら、ファイルを消します)")
  fi
}

# 照らす Cargo.lock の隣にあるのに git が追っていない受け入れ (osv-scanner は読むが、CI の checkout には無い)
for f in "${lockfiles[@]}"; do
  c=$(beside "${f}" osv-scanner.toml)
  if [[ -e ${c} && -z ${tracked_accept[${c}]+x} ]]; then
    problems+=("${c}: git が追っていない受け入れです (osv-scanner は読むが、CI には無い)。git add するか消します")
  fi
done
for c in "${accept_files[@]}"; do
  l=$(beside "${c}" Cargo.lock)
  if [[ -z ${tracked_lock[${l}]+x} ]]; then
    problems+=("${c}: 隣に git の追う Cargo.lock がありません (osv-scanner は -L で渡した Cargo.lock と同じディレクトリの osv-scanner.toml だけを読む)")
    continue
  fi
  check_accept_file "${c}"
done

{
  if ((${#accepted[@]})); then
    echo "受け入れ (osv-scanner.toml。ignoreUntil の日から再び出る。${#accepted[@]} 件):"
    echo
    printf -- '- %s\n' "${accepted[@]}"
  else
    echo "受け入れ (osv-scanner.toml): なし"
  fi
  echo
  if ((${#warnings[@]})); then
    echo "期限を過ぎた受け入れ (${#warnings[@]} 件。止めない):"
    echo
    printf -- '- ⚠ %s\n' "${warnings[@]}"
    echo
  fi
} >>"${report}"
for w in "${warnings[@]}"; do
  annotate warning "期限を過ぎた受け入れ: ${w}"
done

if ((${#problems[@]})); then
  {
    echo "受け入れ (osv-scanner.toml) の書き損じ (${#problems[@]} 件。照らさずに止めた):"
    echo
    printf -- '- %s\n' "${problems[@]}"
    echo
    echo "書き方は ${readme_section}。"
  } >>"${report}"
  for p in "${problems[@]}"; do
    annotate error "受け入れの書き損じ: ${p}"
  done
  echo "!! 受け入れ (osv-scanner.toml) の書き損じがあるので、照らさずに止めます (下の report)。" >&2
  finish 2
fi

# ---- 照らす ----

# Source の列が repo の root からのパスになるよう、root から相対で渡す。call analysis (Rust は build script を走らせる) は
# 使わない (既定でも Rust は off。既定が変わっても走らせず、結果を toolchain の有無で変えない)
args=(scan source --no-call-analysis=all --format markdown --output-file "${work}/osv.md")
for f in "${lockfiles[@]}"; do
  args+=(--lockfile "${f}")
done
rc=0
osv-scanner "${args[@]}" </dev/null || rc=$?

case ${rc} in
  0 | 1)
    if [[ -s ${work}/osv.md ]]; then
      cat -- "${work}/osv.md" >>"${report}"
    else
      echo "(osv-scanner の表がありません)" >>"${report}"
    fi
    ;;
  *)
    echo "osv-scanner が落ちました (終了コード ${rc})。照らせていません。" >>"${report}"
    echo "!! osv-scanner が落ちました (終了コード ${rc}。上のログを見る)。照らせていません。" >&2
    annotate error "osv-scanner が落ちました (終了コード ${rc})。照らせていません"
    finish 2
    ;;
esac

if ((rc == 1)); then
  {
    echo
    echo "受け入れていない advisory があります (上の表)。直し方は ${readme_section}:"
    echo
    echo "1. 直した版 (Fixed Version) へ上げる: その Cargo.lock のディレクトリで \`cargo update -p <crate>@<今の版> --precise <直した版>\`"
    echo "   (公開から 7 日以上たった版にする)。build と試験を流し、Cargo.lock の差分を PR にする"
    echo "2. 直せない (直した版が無い・猶予の内側・major をまたぐ) なら、同じディレクトリの osv-scanner.toml に理由と期限"
    echo "   (${max_accept_days} 日先まで) をつけて受け入れ、PR にする"
  } >>"${report}"
  annotate error "受け入れていない advisory があります。表は job の summary、直し方は ${readme_section}"
  finish 1
fi
finish 0
