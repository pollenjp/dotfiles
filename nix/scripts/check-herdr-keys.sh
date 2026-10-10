#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr のキーバインドが WSL と Windows で同じかを確かめる。
#
#   check-herdr-keys.sh [<WSL の config.toml> <Windows の config.toml>]
#
# 既定では repo の nix/files/herdr/config.toml (WSL) と win/herdr/config.toml (Windows) を
# 比べる。[keys] の全部と onboarding が同じなら exit 0。違えば、違うキーの名前を出して
# exit 1。Windows 側は [terminal] (default_shell = "fish") を持たないので、比べるのは
# この 2 つだけにしている。
#
# CI の lint ジョブが流す。win/ は flake からは見えない (ローカル flake は本体を
# path:<repo>/nix で読む。ADR 010) ので、flake check ではなく checkout の上で走らせる。
# nix-instantiate だけで動く (TOML は builtins.fromTOML で読むので、devShell も jq も要らない)。

set -eu -o pipefail

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
wsl_file=${1:-${repo_dir}/nix/files/herdr/config.toml}
win_file=${2:-${repo_dir}/win/herdr/config.toml}

if ! command -v nix-instantiate &>/dev/null; then
  echo "nix-instantiate が見つかりません (Nix が入っていないか、PATH に無い)。" >&2
  exit 1
fi

# 同じなら "ok <キーの数>"、違えば "ng <違うキーの名前 ...>" を返す。onboarding が違うときは
# (onboarding) を混ぜる。--json の文字列で受け、前後の引用符だけ外す (キー名は記号を含まない)。
# shellcheck disable=SC2016
if ! out=$(nix-instantiate --eval --strict --json \
  --argstr wslFile "${wsl_file}" \
  --argstr winFile "${win_file}" \
  --expr '{ wslFile, winFile }:
    let
      wsl = builtins.fromTOML (builtins.readFile wslFile);
      win = builtins.fromTOML (builtins.readFile winFile);
      wk = wsl.keys or { };
      xk = win.keys or { };
      names = builtins.attrNames (wk // xk);
      differ = builtins.filter (n: (wk.${n} or null) != (xk.${n} or null)) names;
      onboarding = if (wsl.onboarding or null) == (win.onboarding or null) then [ ] else [ "(onboarding)" ];
      bad = differ ++ onboarding;
    in
    if bad == [ ] then "ok ${toString (builtins.length names)}" else "ng ${builtins.concatStringsSep " " bad}"'); then
  echo "!! herdr の config.toml を読めませんでした (上のエラーを見てください)。" >&2
  exit 1
fi
out=${out#\"}
out=${out%\"}

case ${out} in
  ok\ *)
    echo "herdr のキーバインド: WSL と Windows で同じ (${out#ok } 個)"
    ;;
  *)
    echo "!! herdr の [keys] / onboarding が WSL と Windows で違います: ${out#ng }" >&2
    echo "   WSL:     ${wsl_file}" >&2
    echo "   Windows: ${win_file}" >&2
    echo "   どちらかに合わせてください (Windows だけ違うキーにするなら、この検査から外す)。" >&2
    exit 1
    ;;
esac
