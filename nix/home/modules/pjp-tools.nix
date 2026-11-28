# ハブと子の道具 (pjp hub・pjp child・pjp mark・pjp pack) と入口 pjp (pkgs/pjp-tools。dotfiles-private の ADR 124)。
#
# 入れるのは、hc が入るホスト (dotfiles.herdrCore.enable。子が動く所と Linux のハブ。子は pjp child report・pjp mark を打つ) と、
# claude-skills の道具を使うホスト (dotfiles.claude.privateSkills.enable)。claude-skills の道具 (pjp ticket など) も、入口の pjp から
# claude-skills の shim (pjp-skills。scripts/bootstrap-pjp.sh が ~/.cargo/bin に入れる) へ渡る。入口は公開の pjp の 1 つだけ
# (ホストによって pjp の中身が違う形にしない)
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  pjpTools = pkgs.callPackage ../../pkgs/pjp-tools { };
in
{
  config = lib.mkIf (cfg.herdrCore.enable || cfg.claude.privateSkills.enable) {
    home.packages = [ pjpTools ];
  };
}
