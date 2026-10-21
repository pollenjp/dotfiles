# 前の雛形 (ADR 007〜026 の版) のローカル flake が呼ぶ lib.hostsWith を、今の本体で評価時に確かめる (ADR 027)。
# 今の雛形は local を持たないが、まだ移していない PC の ~/dotfiles/flake.nix は hostsWith [ local ] で登録簿のホストに local を
# 当てる。本体で option を消す・改名すると、その PC の switch が評価で止まるので、ここで気づけるようにする。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (hosts-with-state) から呼ぶ。評価の重さを抑えるため、その system の型のホストだけを見る。
#
# ## 確かめること
#
#   - hostsWith [ ] は、本体の homeConfigurations と同じホストの名前を持つ
#   - 前の雛形 (ADR 026 の版) の local の既定 (devTracker.enable = false・notion.profile = null) を hostsWith で当てた型のホストは
#     評価でき、activationPackage の drvPath が出る (sandbox は local の値とぶつかるので見ない。setup も対象にしない)
#   - その drvPath は、local を当てない本体の同じホストと同じ (local の既定は本体の既定と同じなので、前の雛形のまま
#     新しい本体へ上げても、型のホストの世代は変わらない)
{
  lib,
  pkgs,
  system,
  hostsWith,
  homeConfigurations,
}:

let
  # 前の雛形 (ADR 026 の版) の local の既定
  local = {
    dotfiles.claude.devTracker.enable = false;
    dotfiles.claude.notion.profile = null;
  };
  withLocal = hostsWith [ local ];
  # この system の型のホスト (sandbox を除く)
  types = builtins.filter (
    n: n != "sandbox" && homeConfigurations.${n}.pkgs.stdenv.hostPlatform.system == system
  ) (builtins.attrNames homeConfigurations);
  drvOf = h: h.activationPackage.drvPath;

  cases = [
    {
      name = "hostsWith [ ] は本体の homeConfigurations と同じホストの名前を持つ";
      ok = builtins.attrNames (hostsWith [ ]) == builtins.attrNames homeConfigurations;
    }
    {
      name = "この system の型のホストがある";
      ok = types != [ ];
    }
    {
      name = "前の雛形の local を当てた型のホストは評価でき、drvPath が出る";
      ok = builtins.all (n: lib.hasSuffix ".drv" (drvOf withLocal.${n})) types;
    }
    {
      name = "前の雛形の local の既定は本体の既定と同じなので、型のホストの drvPath は変わらない";
      ok = builtins.all (n: drvOf withLocal.${n} == drvOf homeConfigurations.${n}) types;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "hosts-with-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "hosts-with-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
