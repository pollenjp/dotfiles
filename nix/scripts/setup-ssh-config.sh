#!/usr/bin/env bash
# shellcheck shell=bash
#
# .ssh submodule の *.ssh_config を ~/.ssh/config.d/ へ張る。冪等。
#
# Nix 側 (home/modules/ssh.nix) が生成するのは Include の骨組みだけ:
#
#     Include config.d/*.ssh_config
#
# 中身を Nix で配らない理由 (store が誰でも読めること / submodule が flake root の
# 外にあること) は ADR 003 を参照:
#   docs/adr/003_nix_ssh_config_20260810T210714JST/README.md
#
# ## このスクリプトは ~/.ssh/config を触らない
#
# 実ファイルとして残っていると home-manager が「would be clobbered」で switch を
# 中断するが、その退避は setup.sh の `-b` (--backup) に任せる。~/.bashrc などと
# 同じ扱いにして、「switch を邪魔する既存ファイル」の退き方を 1 つに統一するため。
#
# かつてはここで ~/.ssh/config.d/00-local.ssh_config へ移していたが、旧い設定が
# submodule の設定を上書きしてしまうためやめた (経緯と実測は ADR 003)。
#
# ## 実行のタイミング
#
# いつでもよい。setup.sh では switch の手前に置いてあるが、これは switch 直後から
# ssh が引けるようにするためで、順序の制約ではない。

set -eu -o pipefail

ssh_dir="${HOME}/.ssh"
conf="${ssh_dir}/config"
conf_d="${ssh_dir}/config.d"
# $0 が symlink 経由でも実体の場所を返す。
# macOS の readlink には -f が無いので手で辿る。
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
repo_dir=$(dirname "$(dirname "${script_dir}")")
src_dir="${repo_dir}/.ssh"

echo "==> ${conf_d}"
mkdir -p "${conf_d}"
# ssh は自分と親ディレクトリのパーミッションを見る。緩いと黙って設定を無視する。
chmod 700 "${ssh_dir}" "${conf_d}"

# ~/.ssh/config には触らない (上の設計メモを参照)。状態だけ報告する。
if [[ -L ${conf} ]]; then
  if [[ $(readlink -f "${conf}" 2>/dev/null || true) == /nix/store/* ]]; then
    echo "  config: Nix 管理済み"
  else
    echo "  config: Nix 管理外の symlink です。preflight-unlink.sh が外します" >&2
  fi
elif [[ -f ${conf} ]]; then
  echo "  config: 実ファイルがあります。switch は退避が要ります (setup.sh の --backup)" >&2
  echo "          退避後、残したい Host は config.d/ へ手で移してください" >&2
else
  echo "  config: まだありません (switch が作ります)"
fi

# submodule から張る。
echo "==> ${src_dir}"
if [[ ! -d ${src_dir} ]]; then
  # ここで落とさない。ssh の骨組み (~/.ssh/config) と config.d は既に整っており、
  # 手で置いた設定はそのまま効く。submodule はあくまで追加分なので、
  # 未取得を理由に setup 全体を止める必要はない。
  echo "  .ssh submodule がありません。使うなら次で取得してください:" >&2
  echo "    git -C \"${repo_dir}\" submodule update --init .ssh" >&2
  echo "    (取得後にこのスクリプトを再実行する)" >&2
  exit 0
fi

# 先に submodule 由来の symlink を落としてから張り直す。
# submodule 側でファイル名が変わったときに、消えたファイルを指す symlink が
# 残って Include され続けるのを防ぐ。
#
# **submodule を指す symlink だけ**が対象。手で置いた設定ファイルや、
# 別の場所を指す symlink には触らない。
stale=0
for link in "${conf_d}"/*; do
  [[ -L ${link} ]] || continue
  case "$(readlink -- "${link}")" in
    "${src_dir}"/*)
      # 張り直す前に、参照先が消えているものだけ報告する
      # (残っているものは下で同じ内容に張り直されるので黙って落とす)
      [[ -e ${link} ]] || stale=$((stale + 1))
      unlink "${link}"
      ;;
  esac
done
[[ ${stale} -gt 0 ]] && echo "  参照先が消えた symlink を ${stale} 個外しました"

linked=0
for src in "${src_dir}"/*.ssh_config; do
  [[ -f ${src} ]] || continue
  ln -sfn "${src}" "${conf_d}/$(basename "${src}")"
  linked=$((linked + 1))
done

if [[ ${linked} -eq 0 ]]; then
  echo "  *.ssh_config が見つかりません (submodule が空かもしれません)" >&2
else
  echo "  ${linked} 個を張りました"
fi

echo
echo "--- ${conf_d} ---"
ls -la "${conf_d}"
echo
echo "実際に読まれる設定の確認:"
echo "  ssh -G <ホスト名>"
