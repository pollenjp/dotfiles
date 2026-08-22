#!/usr/bin/env bash
# shellcheck shell=bash
#
# 自分の閉包を「flake.lock の pin」と「nixpkgs チャンネル先端」の両方で組み、
# 入るパッケージの版差分を人間が読む形で出す。
#
# ## なぜ要るのか
#
# pin には最小経過日数を課している (flake-lock-age.sh / ADR 005) ので、pin は
# 常にチャンネル先端より数日古い。サプライチェーン侵害が発覚したとき、advisory
# (OSV / GHSA) への掲載より先に **nixpkgs 側の対応** (バージョン bump・revert・
# knownVulnerabilities 追加) が入ることがよくある。つまり「pin と先端の間で、
# 自分の閉包のパッケージに変更が入っていないか」は、advisory 未採番の窓を塞ぐ
# 手がかりになる。スキャン (closure-scan.sh) との役割分担は ADR 006。
#
# **差分があっても fail しない。** 版が動くこと自体は日常 (通常の更新も同じ形)
# なので、機械では侵害対応と区別できない。このレポートの使い方は「pin を更新する
# PR で、動いたパッケージのうち見覚えの無いものだけ nixpkgs のコミットログを
# 確認する」という人間の作業を数十秒にすること。
#
# ## 測り方
#
# 比較先はチャンネル先端 (channels.nixos.org が指す公開) であって git master の
# HEAD ではない。master は Hydra を通っていない commit を含み binary cache が
# 揃わないし、将来の pin が辿り着く先もチャンネル公開だけなので、比較先も同じ
# 一覧から選ぶ (flake-lock-age.sh と同じ理由)。nixpkgs 側の対応がチャンネルへ
# 出るまでの 1〜3 日は、このレポートにも映らない。
#
# 差分は `nix store diff-closures` で取る。runtime 閉包どうしの比較なので、
# 実際にディスクへ載るものだけが出る。両側ともチャンネル公開なので実体は
# ほぼ binary cache からのダウンロードになる。
#
# ## 使い方
#
#   closure-head-diff.sh [オプション] [<flake ディレクトリ>]
#
# オプションは --help を参照。pin を読むので flake.lock が要る。
#
# ## 依存
#
# nix / coreutils / curl / sed。jq は使わない (flake.lock は nix 自身に読ませる)。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)

# 追跡しているチャンネル (flake-lock-age.sh と同じ前提)。
channel=nixpkgs-unstable
channel_url="https://channels.nixos.org/${channel}"
releases_url="https://releases.nixos.org/nixpkgs"

c_dim=$'\033[2m'
c_red=$'\033[31m'
c_cyan=$'\033[36m'
c_reset=$'\033[0m'
if [[ ! -t 1 ]]; then
  c_dim="" c_red="" c_cyan="" c_reset=""
fi

note() {
  printf '  %s%s%s\n' "${c_dim}" "$*" "${c_reset}"
}

step() {
  printf '%s+ %s%s\n' "${c_cyan}" "$*" "${c_reset}"
}

die() {
  printf '%sERROR: %s%s\n' "${c_red}" "$*" "${c_reset}" >&2
  exit 1
}

usage() {
  cat <<'EOS'
使い方: closure-head-diff.sh [オプション] [<flake ディレクトリ>]

pin された nixpkgs と現在のチャンネル先端の両方で閉包を組み、入るパッケージの
版差分を出す。pin を更新する PR で、動いたパッケージのコミットログを人間が
確認するためのレポート。差分があっても fail しない。

オプション:
  --attr ATTR    ビルドする属性
                 (既定 homeConfigurations.sandbox.activationPackage)
  --out-dir DIR  build 結果とレポートの書き出し先 (既定 mktemp -d)
  -h, --help     この使い方を出す

ディレクトリを省くと、この script の隣 (<script>/../flake.nix) があればそこ、
無ければカレントディレクトリを対象にする。
EOS
}

##########
# 引数   #
##########

flake_dir=""
attr="homeConfigurations.sandbox.activationPackage"
out_dir=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --attr)
      [[ $# -ge 2 ]] || die '--attr には属性名が要ります。'
      attr=$2
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

if [[ -z ${flake_dir} ]]; then
  if [[ -f "${script_dir}/../flake.nix" ]]; then
    flake_dir="${script_dir}/.."
  else
    flake_dir=.
  fi
fi
[[ -d ${flake_dir} ]] || die "flake ディレクトリがありません: ${flake_dir}"
[[ -f ${flake_dir}/flake.nix ]] || die "flake.nix がありません: ${flake_dir}/flake.nix"
flake_dir=$(
  cd -- "${flake_dir}" &>/dev/null
  pwd -P
)
[[ -f ${flake_dir}/flake.lock ]] || die "flake.lock がありません: ${flake_dir}/flake.lock
(pin と先端を比べる script なので、pin がまだ無いなら flake-lock-age.sh update で作ること。)"

if [[ -z ${out_dir} ]]; then
  out_dir=$(mktemp -d)
fi
mkdir -p "${out_dir}"

################
# pin 側の rev #
################

# flake.lock から root 直下の nixpkgs input の pin を読む。jq は使わない。
# 追跡先がチャンネル以外なら、比較先の決め方 (チャンネル先端) が成り立たないので
# 止める (flake-lock-age.sh の classify_input と同じ理屈)。
pinned=$(
  nix eval --raw --impure --expr "
    let
      lock = builtins.fromJSON (builtins.readFile \"${flake_dir}/flake.lock\");
      root = lock.nodes.\${lock.root};
      key = root.inputs.nixpkgs or (throw \"root に nixpkgs input がありません\");
      node = lock.nodes.\${key};
    in
    \"\${node.locked.rev}\t\${node.original.ref or \"\"}\"
  "
) || die "flake.lock から nixpkgs の pin を読めませんでした: ${flake_dir}/flake.lock"
pinned_rev=${pinned%%$'\t'*}
pinned_ref=${pinned#*$'\t'}
if [[ ${pinned_ref} != "${channel}" ]]; then
  die "nixpkgs が ${channel} を追っていません (ref=${pinned_ref:-なし})。
比較先をチャンネル先端に固定しているので、追跡先を変えたならこの script も直すこと。"
fi

#################
# 先端側の rev  #
#################

# channels.nixos.org は現在の公開ディレクトリへ 302 する。その git-revision が
# チャンネル先端の commit (flake-lock-age.sh と同じ取り方)。
head_release=$(
  curl -fsSI "${channel_url}" \
    | tr -d '\r' \
    | sed -n 's|^[Ll]ocation:.*/nixpkgs/\(nixpkgs-[^/[:space:]]*\).*|\1|p' \
    | head -n 1
)
[[ -n ${head_release} ]] || die "チャンネル ${channel} の現在の公開名が取れませんでした。"
head_rev=$(curl -fsS "${releases_url}/${head_release}/git-revision" | tr -d '\r\n')
[[ -n ${head_rev} ]] || die "${head_release} の git-revision が取れませんでした。"

printf '%s==> %s (%s)%s\n' "${c_cyan}" "${flake_dir}" "${attr}" "${c_reset}"
note "pin:  ${pinned_rev}"
note "先端: ${head_rev} (${head_release})"

compare_url="https://github.com/NixOS/nixpkgs/compare/${pinned_rev}...${head_rev}"

if [[ ${pinned_rev} == "${head_rev}" ]]; then
  printf 'pin はチャンネル先端と同じです。差分はありません。\n' | tee "${out_dir}/head-diff.txt"
  exit 0
fi

##########
# 比較   #
##########

step "nix build (pin 側)"
nix build "${flake_dir}#${attr}" -o "${out_dir}/closure-pin"

step "nix build (先端側: --override-input nixpkgs github:NixOS/nixpkgs/${head_rev})"
# --no-write-lock-file を明示する。ここで lock を動かしたら本末転倒。
nix build "${flake_dir}#${attr}" \
  --override-input nixpkgs "github:NixOS/nixpkgs/${head_rev}" \
  --no-write-lock-file \
  -o "${out_dir}/closure-head"

step "nix store diff-closures (pin -> 先端)"
# diff-closures は端末でなくても色を出すので剥ぐ (レポートを CI の summary に
# そのまま貼るため)。エスケープ文字は printf で作る (BSD sed は \x1b を解さない)。
esc=$(printf '\033')
NO_COLOR=1 nix store diff-closures \
  "$(readlink -f "${out_dir}/closure-pin")" \
  "$(readlink -f "${out_dir}/closure-head")" \
  | sed "s/${esc}\[[0-9;]*m//g" \
  | tee "${out_dir}/head-diff.txt"

if [[ ! -s ${out_dir}/head-diff.txt ]]; then
  printf 'pin と先端で、閉包に入るパッケージの版差分はありません。\n' \
    | tee "${out_dir}/head-diff.txt"
  exit 0
fi

printf '\n'
note "読み方: 「名前: pin の版 → 先端の版」。見覚えの無い動きだけコミットログを確認する:"
note "${compare_url}"
note "レポート: ${out_dir}/head-diff.txt"
