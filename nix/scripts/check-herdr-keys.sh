#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr のキーバインドと [ui] (sidebar の幅と行・toast) が WSL と Windows で同じかを確かめる。
#
#   check-herdr-keys.sh [<WSL の config.toml> <Windows の config.toml>]
#
# 既定では repo の nix/files/herdr/config.toml (WSL) と win/herdr/config.toml (Windows) を
# 比べる。[keys] の全部・onboarding・[ui] の全部 ([ui.sidebar]・[ui.toast] も含む) が同じなら
# exit 0。違えば、違うキーの名前を出して exit 1。Windows 側は [terminal] (default_shell = "fish")
# を持たず、[update] は Windows 側にだけあるので、比べるのはこの 3 つだけにしている。
#
# [ui] を比べるのは、Windows から herdr --remote (hr) で attach したときも、sidebar や toast を
# 描くのは Windows の herdr で、Windows の設定を読むため。片方だけ直すと、ずれに気付けない
# (TKT-305 で [ui.sidebar] を、TKT-319 で [ui] の全部を比べるようにした)。2 つで違ってよい [ui] の
# キーが出てきたら、そのキーだけをここで外す。名前はキーだけを比べていたころのまま。
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
# (onboarding) を、[ui] が違うときは (ui.<[ui] の直下の名前>) (sidebar_width や、[ui.sidebar] なら
# sidebar) を混ぜる。--json の文字列で受け、前後の引用符だけ外す (キー名は記号を含まない)。
# shellcheck disable=SC2016
if ! out=$(nix-instantiate --eval --strict --json \
  --argstr wslFile "${wsl_file}" \
  --argstr winFile "${win_file}" \
  --expr '{ wslFile, winFile }:
    let
      wsl = builtins.fromTOML (builtins.readFile wslFile);
      win = builtins.fromTOML (builtins.readFile winFile);
      differ = a: b: builtins.filter (n: (a.${n} or null) != (b.${n} or null)) (builtins.attrNames (a // b));
      wk = wsl.keys or { };
      xk = win.keys or { };
      names = builtins.attrNames (wk // xk);
      onboarding = if (wsl.onboarding or null) == (win.onboarding or null) then [ ] else [ "(onboarding)" ];
      ui = map (n: "(ui.${n})") (differ (wsl.ui or { }) (win.ui or { }));
      bad = differ wk xk ++ onboarding ++ ui;
    in
    if bad == [ ] then "ok ${toString (builtins.length names)}" else "ng ${builtins.concatStringsSep " " bad}"'); then
  echo "!! herdr の config.toml を読めませんでした (上のエラーを見てください)。" >&2
  exit 1
fi
out=${out#\"}
out=${out%\"}

case ${out} in
  ok\ *)
    echo "herdr のキーバインドと [ui]: WSL と Windows で同じ (キー ${out#ok } 個)"
    ;;
  *)
    echo "!! herdr の [keys] / onboarding / [ui] が WSL と Windows で違います: ${out#ng }" >&2
    echo "   WSL:     ${wsl_file}" >&2
    echo "   Windows: ${win_file}" >&2
    echo "   どちらかに合わせてください (Windows だけ違うキーにするなら、この検査から外す)。" >&2
    exit 1
    ;;
esac
