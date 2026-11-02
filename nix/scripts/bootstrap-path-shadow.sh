#!/usr/bin/env bash
# shellcheck shell=bash
#
# PATH で、Nix が入れる CLI (ntn) より先に来る、Nix のものでない同名のコマンドを警告する。
# 冪等。`setup.sh --update` でも毎回走る。何も書き換えない。
#
# ## なぜ要るのか
#
# ntn (Notion CLI) は、dotfiles が Nix で入れる (nix/pkgs/ntn。版を固定し、公開から 7 日たった版にする) 前は、公式の
# install script (`curl -fsSL https://ntn.dev | bash`) で入れていた。install script は PATH にある ~/.local/bin か
# ~/bin に置き、どちらも home.sessionPath (nix/home/modules/shell-common.nix) で home-manager の profile
# (~/.nix-profile/bin) より前に来る。残っていると、Nix で入れた版が隠れて使われない。
#
# ## 何をするか
#
# 下の commands の名前ごとに PATH を前から見て、シェルが選ぶもの (実行できるふつうのファイル) を拾う。symlink と
# ディレクトリを辿りきった実体が Nix の store の下にあり、実体の名前もその名前なら Nix のもので、そこで止める
# (後ろのものは隠れていて害が無い)。それより前に拾った Nix のものでないものを、消すコマンドと一緒に 1 件の警告に
# する。名前も見るのは、store の別のコマンドへの symlink (Nix で入れた mise の shim: shims/ntn → store の bin/mise)
# を Nix の ntn と読まないため。
#
# - 消さない。ユーザーのファイルで、npm や mise などの道具で入れたものもある
# - 見るのは、この script が受け取った PATH (setup を打ったシェルの PATH)。PATH の空の要素と相対パスは見ない
#   (cwd を指すので、どこで打ったかで変わる)。同じディレクトリ (末尾の / 違い・symlink で別の名前のもの。/bin →
#   /usr/bin など) は 1 度だけ見る (同じファイルを 2 度並べて、rm が 2 度目で失敗しないように)
# - Nix の ntn が PATH に無ければ (switch の前のシェルなど)、消せば Nix の ntn が使われるとは言わず、Nix の ntn が
#   PATH にあることを確かめてから消すよう出す
# - 終了コードは 0 (setup の後ろの手順を止めない)。引数は取らない (渡されたら何も見ずに 2)
#
# Nix で入れるようにした CLI を、前にほかの方法で入れていたことがあれば commands に足す。
#
# macOS の /bin/bash (3.2) でも動くように書く (mapfile・連想配列を使わない。macOS の readlink には -f が無く、
# realpath も無いことがあるので、symlink は手で辿る)。

set -eu -o pipefail

# 見る名前 (dotfiles が Nix で入れる CLI のうち、前にほかの方法で入れていたもの)
commands=(ntn)
# Nix の store。テストで差し替える
store=${BOOTSTRAP_PATH_SHADOW_STORE:-/nix/store}

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
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

if [[ $# -gt 0 ]]; then
  echo "引数は取りません: $*" >&2
  exit 2
fi

# $1 の実体のパス (symlink を辿りきり、途中のディレクトリも実体にしたもの) を出す。辿れなければ 1。
real_path() {
  local p=$1 dir link n=0
  while :; do
    dir=${p%/*}
    dir=$(cd -P -- "${dir:-/}" 2>/dev/null && pwd -P) || return 1
    p="${dir%/}/${p##*/}"
    [[ -L ${p} ]] || break
    link=$(readlink -- "${p}") || return 1
    case ${link} in
      /*) p=${link} ;;
      *) p="${dir%/}/${link}" ;;
    esac
    n=$((n + 1))
    if ((n > 40)); then
      return 1
    fi
  done
  printf '%s\n' "${p}"
}

# store も実体のパスにしておく (macOS の /tmp のように symlink の下にあっても、比べ違えないように)
if [[ -d ${store} ]]; then
  store=$(cd -P -- "${store}" && pwd -P)
fi

# $1 (実行できるファイル) が Nix の $2 か (実体が store の下にあり、実体の名前も $2 か)
is_nix() {
  local real
  real=$(real_path "$1") || return 1
  [[ ${real} == "${store%/}/"* && ${real##*/} == "$2" ]]
}

for cmd in "${commands[@]}"; do
  shadows=()
  count=0
  nix_cmd=""
  seen=""
  # PATH を ":" で 1 つずつ切る (空の要素も切り出す。末尾に ":" を足して最後の要素も拾う)
  rest="${PATH:-}:"
  while [[ -n ${rest} ]]; do
    dir=${rest%%:*}
    rest=${rest#*:}
    # 空の要素と相対パスは cwd を指すので見ない
    case ${dir} in
      /*) ;;
      *) continue ;;
    esac
    dir=${dir%/}
    # 同じディレクトリ (末尾の / 違い・symlink で別の名前のものも) は 1 度だけ見る。入れないディレクトリは見ない
    real_dir=$(cd -P -- "${dir:-/}" 2>/dev/null && pwd -P) || continue
    case ${seen} in
      *"<${real_dir}>"*) continue ;;
    esac
    seen="${seen}<${real_dir}>"
    candidate="${dir}/${cmd}"
    # シェルが選ぶのは、実行できるふつうのファイル (symlink なら指す先) だけ
    [[ -f ${candidate} && -x ${candidate} ]] || continue
    if is_nix "${candidate}" "${cmd}"; then
      nix_cmd=${candidate}
      break
    fi
    shadows+=("${candidate}")
    count=$((count + 1))
  done

  if ((count == 0)); then
    if [[ -n ${nix_cmd} ]]; then
      echo "${cmd}: PATH で最初に来るのは Nix の ${cmd} (${nix_cmd})"
    else
      echo "${cmd}: PATH に ${cmd} は無い"
    fi
    continue
  fi

  # Nix の ntn が PATH にあれば「先に来るもの」、無ければ「Nix のものでない <名前>」として並べる
  if [[ -n ${nix_cmd} ]]; then
    label="先に来るもの"
  else
    label="Nix のものでない ${cmd}"
  fi
  lines=()
  rm_cmd="rm"
  for s in "${shadows[@]}"; do
    lines+=("${label}: ${s}")
    rm_cmd="${rm_cmd} $(printf '%q' "${s}")"
  done
  if [[ -n ${nix_cmd} ]]; then
    warn "PATH で、Nix の ${cmd} より先に Nix のものでない ${cmd} があります (今のシェルではそちらが使われ、dotfiles が Nix で入れた版は使われません)。" \
      "${lines[@]}" \
      "Nix の ${cmd}:   ${nix_cmd}" \
      "setup は消しません。要らなければ消す (新しいシェルから Nix の ${cmd} が使われる):" \
      "  ${rm_cmd}" \
      "npm や mise などの道具で入れたものなら、その道具で外す。"
  else
    warn "PATH に Nix のものでない ${cmd} があり、Nix の ${cmd} は PATH にありません (dotfiles は ${cmd} を Nix で入れます)。" \
      "${lines[@]}" \
      "setup は消しません。switch の後に開いたシェルの \`type -a ${cmd}\` に Nix の ${cmd} (~/.nix-profile/bin/${cmd} など) が出ることを確かめてから消す:" \
      "  ${rm_cmd}" \
      "npm や mise などの道具で入れたものなら、その道具で外す。"
  fi
done
