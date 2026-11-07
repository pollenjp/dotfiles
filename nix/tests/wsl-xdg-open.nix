# dotfiles.wsl.enable のマシンの PATH にだけ入る xdg-open (home/modules/wsl-xdg-open.nix) を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (wsl-xdg-open-state)
# から呼ぶ。Linux の checks にだけ置く (WSL は Linux)。動きそのものは pjp-wsl-xdg-open.test.sh が確かめる。
#
# ## 確かめること
#
#   評価時 (assert)
#     - wsl.enable = true のマシンの home.packages に xdg-open が入る
#     - WSL でないマシン (既定) の home.packages に入らない
#   ビルド時 (このランナーの system だけ)
#     - WSL のマシンの profile の bin/xdg-open は、この package のもの (ほかの package の xdg-open に隠れない)
#     - WSL でないマシンの profile に bin/xdg-open は無い (ほかの package も持ち込まない)
#     - profile の xdg-open は、呼ぶ側の PATH に coreutils が無くても (runtimeInputs で足りる)、URL を rundll32.exe へ渡す
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    wsl:
    (mkHome {
      username = "tester";
      inherit system wsl;
    }).config;

  wslCfg = configWith { enable = true; };
  plainCfg = configWith { };

  isXdgOpen = p: (p.meta.mainProgram or null) == "xdg-open";
  xdgOpenOf = cfg: builtins.filter isXdgOpen cfg.home.packages;

  cases = [
    {
      name = "wsl.enable = true のマシンの home.packages に xdg-open が入る";
      ok = lib.length (xdgOpenOf wslCfg) == 1;
    }
    {
      name = "WSL でないマシンの home.packages に xdg-open は入らない";
      ok = xdgOpenOf plainCfg == [ ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "wsl-xdg-open-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "wsl-xdg-open-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}

  profile=${wslCfg.home.path}/bin/xdg-open
  want=${lib.getExe (lib.head (xdgOpenOf wslCfg))}
  got=$(readlink -f "$profile")
  if [[ $got != "$(readlink -f "$want")" ]]; then
    echo "wsl-xdg-open-state: WSL のマシンの profile の xdg-open が $want でなく $got" >&2
    exit 1
  fi
  echo "ok   WSL のマシンの profile の bin/xdg-open は、この package のもの"

  if [[ -e ${plainCfg.home.path}/bin/xdg-open ]]; then
    echo "wsl-xdg-open-state: WSL でないマシンの profile に bin/xdg-open がある" >&2
    exit 1
  fi
  echo "ok   WSL でないマシンの profile に bin/xdg-open は無い"

  # 偽の rundll32.exe に、受けた引数を書かせる
  {
    printf '#!%s\n' ${lib.escapeShellArg pkgs.runtimeShell}
    printf 'printf "%%s\\n" "$@" >"%s/args"\n' "$TMPDIR"
  } >"$TMPDIR/rundll32.exe"
  chmod +x "$TMPDIR/rundll32.exe"
  env -i PATH=/nonexistent PJP_WSL_XDG_OPEN_RUNDLL32="$TMPDIR/rundll32.exe" \
    "$profile" 'http://localhost/?a=1&b=2'
  seen=$(<"$TMPDIR/args")
  if [[ $seen != $'url.dll,FileProtocolHandler\nhttp://localhost/?a=1&b=2' ]]; then
    echo "wsl-xdg-open-state: rundll32.exe が受けた引数が違う: $seen" >&2
    exit 1
  fi
  echo "ok   呼ぶ側の PATH に coreutils が無くても、URL を rundll32.exe へ渡す"
  touch $out
''
