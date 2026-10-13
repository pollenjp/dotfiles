#!/usr/bin/env bash
# shellcheck shell=bash
#
# d3.min.js (と plot.umd.min.js) を指定のディレクトリへ写す。cc-pages の standalone
# ページのように、CDN を読めないページで D3 / Observable Plot を動かすときに使う。
#
# ## なぜ写すのか
#
# cc-pages のページの CSP は script-src 'self' 'unsafe-inline' で、外部のオリジン
# (CDN) は止まる。ページの assets/ に置けば 'self' として読める。
#
# store を指す symlink にはしない。GC で store から消えてもページが動き続けるように、
# 中身を複製する。store のファイルは読み取り専用なので、書き込めるモードで置く
# (cp のままだと、次に写し直すときに上書きできない)。
#
# ## 依存
#
# d3 と Plot は、この skill の flake.nix が作る node_modules にある。
# devShell が渡す PJP_D3JS_NODE_MODULES が無ければ、自動で devShell へ入り直す。

set -eu -o pipefail

skill_dir=$(
  cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." &>/dev/null
  pwd -P
)

have() {
  command -v "$1" &>/dev/null
}

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOS'
usage: d3js-vendor.sh [--plot] DIR

DIR (例: cc-pages のページの assets/) に d3.min.js を写す。DIR が無ければ作る。

options:
  --plot       plot.umd.min.js も写す (ページでは d3.min.js の後に読む)
  -h, --help   これ

例:
  d3js-vendor.sh "$dir/assets"          # dir は cc-pages new が返したもの
  d3js-vendor.sh --plot "$dir/assets"
EOS
}

for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
  esac
done

# 印を付けて 1 回だけにする (devShell に入っても揃わない場合の無限ループ防止)。
if [[ -z ${PJP_D3JS_NODE_MODULES:-} ]] || ! have node; then
  if [[ -z ${D3JS_SKILL_REEXEC:-} ]] && have nix; then
    export D3JS_SKILL_REEXEC=1
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  die "d3 の node_modules が見つかりません (PJP_D3JS_NODE_MODULES が空)。
nix があれば devShell へ自動で入り直します。"
fi

plot=0
dest=
while [[ $# -gt 0 ]]; do
  case $1 in
    --plot)
      plot=1
      shift
      ;;
    -*)
      die "知らないオプション: $1 (--help を見る)"
      ;;
    *)
      [[ -z ${dest} ]] || die "DIR は 1 つだけ: ${dest} と $1"
      dest=$1
      shift
      ;;
  esac
done
[[ -n ${dest} ]] || die "写す先の DIR を渡してください (--help を見る)"

nm=${PJP_D3JS_NODE_MODULES}

# 写したものの版 (package.json の version)
version_of() {
  node -p 'require(process.argv[1]).version' "${nm}/$1/package.json"
}

copy() {
  local src=$1 name=$2 pkg=$3
  [[ -f ${src} ]] || die "見つかりません: ${src}"
  install -m 0644 "${src}" "${dest}/${name}"
  echo "==> ${dest}/${name} (${pkg} $(version_of "${pkg}"))"
}

mkdir -p "${dest}"
copy "${nm}/d3/dist/d3.min.js" d3.min.js d3
if ((plot)); then
  copy "${nm}/@observablehq/plot/dist/plot.umd.min.js" plot.umd.min.js @observablehq/plot
fi

dir_name=$(basename "${dest}")
echo
echo "ページ (index.html) からは相対パスで、この順に読む:"
echo "  <script src=\"${dir_name}/d3.min.js\"></script>"
if ((plot)); then
  echo "  <script src=\"${dir_name}/plot.umd.min.js\"></script>"
fi
