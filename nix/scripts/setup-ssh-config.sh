#!/usr/bin/env bash
# shellcheck shell=bash
#
# .ssh submodule の *.ssh_config を ~/.ssh/config.d/ へ張る。冪等。
#
# ## なぜ Nix で配らないのか
#
# 1. **/nix/store は誰でも読める。** 接続先ホスト名・ユーザー名・踏み台の構成を
#    store に置きたくない。store のファイルは 444 なので隠しようがない。
# 2. 実体は `.ssh` submodule にあり **flake root (nix/) の外**なので、
#    そもそも flake から読めない。
#
# Nix 側 (home/modules/ssh.nix) が生成するのは Include の骨組みだけ:
#
#     Include config.d/*.ssh_config
#
# ## 実行のタイミング
#
# **home-manager switch より前**に実行する必要がある。setup.sh の手順でも
# switch の手前に置いてある (bootstrap-*.sh の枠には入れられない。あれは
# switch の後に走るので手遅れになる)。
#
# 理由: ~/.ssh/config が実ファイルとして残っていると home-manager が
#       「Existing file '...' would be clobbered」で **switch ごと中断する**。
#       それをここで config.d へ退避しておく。
#
# 既に switch 済み (= ~/.ssh/config が store への symlink) の場合は
# 退避処理を飛ばし、symlink を張り直すだけ。submodule を更新したあとに
# 張り直す用途でも使うので、何度実行してもよい。

set -eu -o pipefail

ssh_dir="${HOME}/.ssh"
conf="${ssh_dir}/config"
conf_d="${ssh_dir}/config.d"
migrated="${conf_d}/00-local.ssh_config"

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

# 既存の ~/.ssh/config を退避する。
#
# - 実ファイル ... home-manager が上書きを拒んで中断するので config.d へ移す
# - symlink    ... main.bash 経路の名残なら外す。store 指向なら Nix 管理済みなので触らない
if [[ -L ${conf} ]]; then
  if [[ $(readlink -f "${conf}" 2>/dev/null || true) == /nix/store/* ]]; then
    echo "  config: Nix 管理済み (そのまま)"
  else
    echo "  config: 旧経路の symlink を外します"
    unlink "${conf}"
  fi
elif [[ -f ${conf} ]]; then
  if [[ -e ${migrated} ]]; then
    echo "  config: 実ファイルが残っていますが ${migrated##*/} が既にあります" >&2
    echo "          中身を確認して手で退けてください。" >&2
  else
    echo "  config: 実ファイルを ${migrated##*/} へ退避します"
    mv "${conf}" "${migrated}"
    chmod 600 "${migrated}"
  fi
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
