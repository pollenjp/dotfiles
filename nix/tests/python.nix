# nixpkgs の python3 と、uv に自分で入れた python だけを使わせる ~/.config/uv/uv.toml (home/modules/python.nix) を
# 確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (python-state) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - home.packages に nixpkgs の python3 があり、uv は無い (uv 本体はプロジェクトの mise などが入れる)
#     - ~/.config/uv/uv.toml を置く
#   ビルド時 (このランナーの system)
#     - 置く uv.toml は python-preference = "only-managed" の 1 行だけ
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  home = mkHome {
    username = "tester";
    inherit system;
  };
  cfg = home.config;
  uvToml = cfg.xdg.configFile."uv/uv.toml" or null;

  cases = [
    {
      name = "home.packages に nixpkgs の python3 がある";
      ok = builtins.elem home.pkgs.python3 cfg.home.packages;
    }
    {
      name = "home.packages に uv は無い";
      ok = !(builtins.any (p: lib.getName p == "uv") cfg.home.packages);
    }
    {
      name = "~/.config/uv/uv.toml を置く";
      ok = uvToml != null && uvToml.enable;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "python-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "python-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  toml=${uvToml.source}
  if [ "$(cat "$toml")" != 'python-preference = "only-managed"' ]; then
    echo "python-state: uv.toml が python-preference = \"only-managed\" の 1 行だけでない:" >&2
    cat "$toml" >&2
    exit 1
  fi
  echo 'ok   置く uv.toml は python-preference = "only-managed" の 1 行だけ'
  touch $out
''
