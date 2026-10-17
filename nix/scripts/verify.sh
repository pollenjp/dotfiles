#!/usr/bin/env bash
# shellcheck shell=bash
#
# home-manager 設定の検証を一括で実行する。
# 実際の $HOME にも手元の user systemd にも触れず、使い捨ての $HOME に対して activate を試す。
#
# 使い方:
#   ./nix/scripts/verify.sh
#
# ネットワークポリシーで codeload.github.com が遮断された環境では、
# input を差し替えて実行する (flake.nix は変更しない):
#   NIX_OVERRIDE_INPUTS=1 ./nix/scripts/verify.sh

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)
nix_dir=$(dirname "${script_dir}")

sandbox_home="${SANDBOX_HOME:-/tmp/hm-sandbox}"

override_args=()
if [[ ${NIX_OVERRIDE_INPUTS:-0} == "1" ]]; then
  override_args=(
    --override-input nixpkgs "tarball+https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz"
    --override-input home-manager "git+https://github.com/nix-community/home-manager?shallow=1"
  )
  echo "==> input を差し替えて実行します (NIX_OVERRIDE_INPUTS=1)"
fi

cd "${nix_dir}"

# git flake は untracked ファイルを見ないため、先に stage しておく
echo "==> git add (flake は untracked ファイルを認識しないため)"
git add -A .

echo "==> nix flake check --all-systems --no-build"
nix flake check --all-systems --no-build "${override_args[@]}"

echo "==> sandbox の activationPackage をビルド"
result_link=$(mktemp -u /tmp/hm-verify-XXXXXX)
nix build "${override_args[@]}" '.#homeConfigurations.sandbox.activationPackage' -o "${result_link}"

echo "==> 配置されるファイル一覧"
# home-files 自体が store への symlink なので -L が必須。
# 付けないと 1 件も列挙されず「配置物なし」に見えてしまう。
if [[ -e "${result_link}/home-files" ]]; then
  find -L "${result_link}/home-files" -mindepth 1 | sed "s|${result_link}/home-files|  \$HOME|" | sort
else
  echo "  (home-files なし: このステージではファイルを配置しない)"
fi

echo "==> 使い捨て \$HOME (${sandbox_home}) へ activate"
rm -rf "${sandbox_home}"
mkdir -p "${sandbox_home}/.local/state/nix/profiles" "${sandbox_home}/run"
# XDG_RUNTIME_DIR を systemd のソケットが無い場所へ向ける (CI の nix.yml と同じ)。
# activate は `systemctl --user is-system-running` で user systemd に届くかを見て、
# 届かなければ "Skipping reload." で systemd に触れない。
# 向けないと手元の user systemd に届き、sandbox と同じ名前の unit (cc-pages.service
# など) を止めて起こし直す。実 systemd は実 HOME の unit しか見ないので、手元で
# 常駐しているものが 1 回落ちて立ち上がり直す。
HOME="${sandbox_home}" USER=user XDG_RUNTIME_DIR="${sandbox_home}/run" "${result_link}/activate"

echo "==> 冪等性の確認 (2 回目の activate)"
HOME="${sandbox_home}" USER=user XDG_RUNTIME_DIR="${sandbox_home}/run" "${result_link}/activate"

# 配置物は store への symlink なので grep -r では中身まで辿れない。
# 複製元 (nix/files/) を直接検査する方が確実。
echo "==> nix/files/ に ~~/dotfiles 参照が残っていないか"
if grep -rn 'dotfiles/' files/ 2>/dev/null; then
  echo "!! 上記に ~~/dotfiles への参照が残っています (store 管理では解決できません)" >&2
  exit 1
fi
echo "  OK"

echo "==> 世代"
HOME="${sandbox_home}" USER=user "${sandbox_home}/.nix-profile/bin/home-manager" generations

rm -f "${result_link}"
echo
echo "すべて通過しました。"
