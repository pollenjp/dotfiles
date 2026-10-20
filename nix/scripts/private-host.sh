#!/usr/bin/env bash
# shellcheck shell=bash
#
# この PC を dotfiles-private に登録するときの名前と、dotfiles-private の clone の場所を決める (ADR 025)。
#
# ## 何のために
#
# 実機のホストの定義と値は、private な dotfiles-private の nix/hosts/<user>@<hostname>.nix に 1 PC 1 ファイルで置く。
# ローカル flake (~/dotfiles/flake.nix) の雛形がその nix/ を path: の入力に取り、setup.sh は --host が無ければ
# この PC の名前のファイルのホストを選ぶ。名前と clone の場所の決め方は、この script だけが持つ
# (setup.sh・setup-local-flake.sh・local-flake-migrate.sh はこれを呼ぶ。登録の skill pjp-dotfiles-register-host も)。
#
#   名前        <user>@<短い hostname>。user は $USER (無ければ id -un)。hostname は macOS ならネットワークで変わらない
#               LocalHostName (scutil)、ほかは uname -n の最初の . まで (hostname -s と同じ)。英数字と . _ - だけ
#   clone       $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
#               ~/ghq/github.com/pollenjp/dotfiles-private (bootstrap-dotfiles-private.sh などの private_dir() と同じ)
#   入力の先    clone の nix/ が directory ならそれ、無ければ本体の空の stub (nix/private-stub)。雛形は clone の無い
#               マシンでも入力の行の形を変えずに書く
#
# name・dir・input-dir は bash と uname だけで動く (setup.sh は Nix を入れる前にも呼ぶ。macOS の bash 3.2 でも動く書き方)。
#
# ## 登録の決まった処理 (inspect・draft・compare)
#
# この PC を登録する手順 (skill pjp-dotfiles-register-host) のうち、決まった処理を持つ。判断と確認の取り方は skill。
#
#   inspect   この PC を調べる (名前・WSL・clone と登録・ローカル flake の local と手で足したホスト・setup が選ぶホスト・
#             今の世代と outPath が一致するホスト = 元にするホストの候補)
#   draft     元にするホスト (+ ローカル flake の local) の options.dotfiles から、nix/hosts/<名前>.nix の下書きを描く
#             (nix/lib/host-draft.nix。dotfiles の option の外の local の行は、描かずに頭のコメントで知らせる)
#   compare   旧い形 (ローカル flake の <元のホスト>。local が当たる) と新しい形 (dotfiles-private の <名前>。local は
#             当たらない) を、同じ本体・同じ lock で評価して drvPath を比べる。同じなら、この登録で世代の中身は変わらない
#
# 評価はローカル flake の写しで行い、ユーザーの ~/dotfiles (flake.nix と flake.lock) にも dotfiles-private にも書かない。

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
  private-host.sh inspect [--flake <dir>]
      この PC を調べる: 名前・system・WSL (Windows のユーザー名)・clone と登録・ローカル flake (雛形の版・入力・手で
      足したホスト・local の行)・setup が --host なしで選ぶホスト・今の世代と outPath が一致するホスト
  private-host.sh draft --base <ホスト> [--flake <dir>] [--name <名前>] [--nix-dir <本体の nix>] [--out <ファイル> [--force]]
      元にするホスト (+ local) から nix/hosts/<名前>.nix の下書きを描く。--out が無ければ stdout。在る --out は
      --force が無いと書かない (2)。元のホストを評価できなければ 3
  private-host.sh compare --base <ホスト> --private <dotfiles-private の作業ツリー> [--name <名前>] [--flake <dir>]
                          [--nix-dir <本体の nix>] [--out <作業場所>]
      旧い形 (ローカル flake の <ホスト>) と新しい形 (<作業ツリー>/nix/hosts/<名前>.nix) を同じ本体 (--nix-dir。既定は
      この script の repo の nix/)・同じ lock で評価し、drvPath を比べる。0 = 同じ、1 = 違う (config.dotfiles の違いを
      出す)、2 = 使い方の誤り・登録のファイルが無い、3 = 旧い形が評価できない、4 = 新しい形が評価できない
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

# この PC の system (x86_64-linux など。setup.sh の推測と同じ決め方)
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

is_wsl() {
  [[ -n ${WSL_DISTRO_NAME:-} ]] || grep -qi microsoft /proc/version 2>/dev/null
}

# WSL のホスト側 Windows のユーザー名 (mkHome の wsl.windowsUserName)。調べられなければ 1
windows_user() {
  local exe u
  for exe in pwsh.exe powershell.exe; do
    command -v "${exe}" &>/dev/null || continue
    # shellcheck disable=SC2016 # PowerShell の変数をそのまま渡す
    u=$("${exe}" -NoProfile -Command '$env:USERNAME' 2>/dev/null </dev/null) || continue
    u=${u//$'\r'/}
    u=${u%%$'\n'*}
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

# flake.nix ($1) の inputs.dotfiles.url を path:<$2> に書き換える (比べるための写しで、本体を揃える)
set_main() {
  awk -v nd="$2" '
    !done && /^[[:space:]]*inputs\.dotfiles\.url[[:space:]]*=[[:space:]]*"path:[^"]*"/ {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "inputs.dotfiles.url = \"path:" nd "\";"
      done = 1
      next
    }
    { print }
  ' "$1" >"$1.new" && mv "$1.new" "$1"
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

# ローカル flake ($1) の local の中の、コメントでも空でもない行 (字下げを外して)。local は「local = …」の行から、
# 同じ字下げの「};」の行まで (雛形の形。関数の形 local = { lib, ... }: { … }; でも同じ)
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

# 1 ホストの config.dotfiles を平らにして「パス<TAB>値の JSON」で 1 行ずつ出す式 (local-flake-migrate.sh と同じ)。
# $1: ホスト (check_host 済み)
dotfiles_expr() {
  printf '%s' 'hs: let
    flat = p: v:
      if builtins.isAttrs v && !(v ? outPath) then
        builtins.concatLists (map (k: flat (if p == "" then k else p + "." + k) (builtins.getAttr k v)) (builtins.attrNames v))
      else [ (p + "\t" + (if builtins.isFunction v then "\"<function>\"" else builtins.toJSON v) + "\n") ];
  in builtins.concatStringsSep "" (flat "" (builtins.getAttr "'"$1"'" hs).config.dotfiles)'
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
    echo "  local のコメントでない行:"
    lines=$(local_lines "${f}")
    if [[ -n ${lines} ]]; then
      while IFS= read -r l; do
        printf '    %s\n' "${l}"
      done <<<"${lines}"
    else
      echo "    (無い。local が見つからない)"
    fi
  fi

  if [[ -f ${script_dir}/setup.sh ]]; then
    if which=$(DOTFILES_LOCAL_DIR="${flake_dir}" "${BASH}" "${script_dir}/setup.sh" --which-host 2>/dev/null </dev/null); then
      case ${which#*$'\t'} in
        local) state='ローカル flake で定義' ;;
        private) state='dotfiles-private に登録したこの PC のホスト' ;;
        guess) state='USER と uname からの推測' ;;
        *) state=${which#*$'\t'} ;;
      esac
      printf '==> setup が --host なしで選ぶホスト: %s (%s)\n' "${which%%$'\t'*}" "${state}"
    else
      echo "==> setup が --host なしで選ぶホスト: 決まらない"
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
          echo "  一致するホストはありません (本体が最後の switch から進んだ、など)。setup が選ぶホスト (上) を元にするか、"
          echo "  ユーザーに確かめる"
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
  local flake_dir=${default_flake_dir} base="" name="" nd="" out="" force=0 text lines l
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
  if [[ -n ${nd} ]]; then
    nd=$(cd -P -- "${nd}" && pwd) || die "--nix-dir がありません: ${nd}"
    check_path "${nd}"
  fi
  need_nix
  need_tmp
  copy_flake "${flake_dir}" "${tmp}/cur"
  [[ -z ${nd} ]] || set_main "${tmp}/cur/flake.nix" "${nd}"
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
      eval_error_excerpt "${tmp}/draft.err"
    } >&2
    exit 3
  fi
  if [[ -z ${out} ]]; then
    printf '%s\n' "${text}"
    return 0
  fi
  mkdir -p "$(dirname -- "${out}")"
  printf '%s\n' "${text}" >"${out}"
  printf '==> 下書きを書きました: %s\n' "${out}"
  printf '  元にしたホスト: %s (+ ローカル flake の local)\n' "${base}"
  [[ -z ${lines} ]] || echo "  local に dotfiles の option の外の行があります (下書きの頭のコメント)。要るなら modules に足す"
}

cmd_compare() {
  local flake_dir=${default_flake_dir} base="" name="" nd=${nix_dir} private="" out="" pnix work res
  local old_drv old_out new_drv new_out gen diff_text
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
  if [[ -n ${out} ]]; then
    if [[ -e ${out} ]] && [[ ! -d ${out} || -n $(ls -A "${out}") ]]; then
      die "--out が空でないか、ディレクトリではありません: ${out}"
    fi
    mkdir -p "${out}"
    work=$(cd -P -- "${out}" && pwd)
    case "${work}/" in
      "$(cd -P -- "${flake_dir}" && pwd)/"*) die "--out がローカル flake の中です: ${work} (外に作る)" ;;
    esac
  else
    need_tmp
    work="${tmp}/compare"
  fi

  # 旧い形: ローカル flake の写しの本体を --nix-dir に揃える。新しい形: privateHosts だけを出す flake
  copy_flake "${flake_dir}" "${work}/old"
  set_main "${work}/old/flake.nix" "${nd}"
  mkdir -p "${work}/new"
  cat >"${work}/new/flake.nix" <<EOS
# private-host.sh compare が作った、dotfiles-private の nix/ のホストだけを出す flake (比べるための写し)
{
  inputs.dotfiles.url = "path:${nd}";
  inputs.dotfiles-private.url = "path:${pnix}";
  inputs.dotfiles-private.flake = false;
  outputs =
    { dotfiles, dotfiles-private, ... }:
    {
      homeConfigurations = dotfiles.lib.privateHosts dotfiles-private;
    };
}
EOS
  for side in old new; do
    if [[ ${side} == new && -f ${work}/old/flake.lock ]]; then
      cp "${work}/old/flake.lock" "${work}/new/flake.lock"
    fi
    if ! lock_sync "${work}/${side}"; then
      printf '!! 比べるための写し (%s) の lock を、path: の入力に合わせられません:\n' "${side}" >&2
      eval_error_excerpt "${work}/${side}.lock.log" >&2
      exit 2
    fi
  done

  printf '==> 比べる: 旧い形 %s (ローカル flake の写し。local が当たる) と、新しい形 %s (%s/hosts/%s.nix。local は当たらない)\n' \
    "${base}" "${name}" "${pnix}" "${name}"
  printf '  本体: %s\n' "${nd}"
  echo "  評価しています (1 回 20〜60 秒)…"
  if ! res=$(nix eval --raw "path:${work}/old#homeConfigurations" --apply "$(drv_expr "${base}")" 2>"${work}/old.err"); then
    {
      printf '!! 旧い形 (ローカル flake の %s) を評価できません:\n' "${base}"
      eval_error_excerpt "${work}/old.err"
    } >&2
    exit 3
  fi
  old_drv=${res%%$'\n'*}
  old_out=${res#*$'\n'}
  if ! res=$(nix eval --raw "path:${work}/new#homeConfigurations" --apply "$(drv_expr "${name}")" 2>"${work}/new.err"); then
    {
      printf '!! 新しい形 (%s/hosts/%s.nix) を評価できません (ファイルの誤りを直して比べ直す):\n' "${pnix}" "${name}"
      eval_error_excerpt "${work}/new.err"
    } >&2
    exit 4
  fi
  new_drv=${res%%$'\n'*}
  new_out=${res#*$'\n'}
  printf '  旧い形 %s: %s\n' "${base}" "${old_drv}"
  printf '  新しい形 %s: %s\n' "${name}" "${new_drv}"

  gen=$(current_generation) || gen=""
  if [[ -z ${gen} ]]; then
    echo "  参考: 今の世代が見つからない"
  elif [[ ${gen} == "${old_out}" ]]; then
    printf '  参考: 今の世代 (%s) は旧い形と一致する\n' "${gen}"
  elif [[ ${gen} == "${new_out}" ]]; then
    printf '  参考: 今の世代 (%s) は新しい形と一致する\n' "${gen}"
  else
    printf '  参考: 今の世代 (%s) はどちらとも一致しない (本体が最後の switch から進んだ、など。判定には使わない)\n' "${gen}"
  fi

  if [[ ${old_drv} == "${new_drv}" ]]; then
    echo "→ drvPath が同じ。この登録で home-manager の世代の中身は変わらない (local の値を全部写せている)。"
    return 0
  fi
  if nix eval --raw "path:${work}/old#homeConfigurations" --apply "$(dotfiles_expr "${base}")" >"${work}/d-old.tsv" 2>/dev/null \
    && nix eval --raw "path:${work}/new#homeConfigurations" --apply "$(dotfiles_expr "${name}")" >"${work}/d-new.tsv" 2>/dev/null; then
    diff_text=$(
      awk -F'\t' '
        FNR == NR { a[$1] = $2; next }
        { b[$1] = $2 }
        END {
          for (k in a) if (!(k in b)) print "    " k ": " a[k] " → (無い)"
          for (k in b) if (!(k in a)) print "    " k ": (無い) → " b[k]; else if (a[k] != b[k]) print "    " k ": " a[k] " → " b[k]
        }
      ' "${work}/d-old.tsv" "${work}/d-new.tsv" | sort
    )
    [[ -n ${diff_text} ]] || diff_text="    (config.dotfiles は同じ。dotfiles の option の外 (local の programs.* など) が違う)"
  else
    diff_text="    (config.dotfiles を読めませんでした)"
  fi
  echo "→ drvPath が違う (この登録で値が変わる)。config.dotfiles の違い (旧い → 新しい):"
  printf '%s\n' "${diff_text}"
  return 1
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
  inspect) cmd_inspect "$@" ;;
  draft) cmd_draft "$@" ;;
  compare) cmd_compare "$@" ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
