# 設定グループ (dotfiles.group) と道具の switch の値を ~/.local/state/dotfiles/group.json に置き、道具どうしの依存を
# 評価で確かめる (dotfiles-private の docs/adr/109_host_groups_minimum_all_*。表は lib/groups.nix)。
#
#   {"group":"minimum","tools":{"ccPages":false,"claude":true,…},"version":2}
#
#   tools  lib/groups.nix の表の各行の key と、その option の値そのもの (効く条件 requires はかけない。環境の条件 env は既定に
#          入っているので、グループの既定から来た値ならそのマシンで効く道具だけが true)
#
# version 1 (ADR 057) は段の tiers も持っていた。setup は tools の字だけを見るので、どちらの版でも同じに読む。
#
# setup.sh が読み、bootstrap-*.sh の冒頭の見出し (# tool: <key>) の key が false なら、その手順を飛ばす。setup.sh は Nix より
# 前にも走るので jq を使わず、"<key>":false の文字で見る (builtins.toJSON は空白を入れない)。bootstrap-mise.sh も
# tools.claude を読んで、claude を入れるかを決める。
#
# どのホストにも置く。ファイルが無いのは「この仕組みの前の世代へ switch したまま」で、setup は今までどおり全部流す
# (windows-files.json・cursor-agent.json と同じく、無いことと off を見分ける)。
{ config, lib, ... }:

let
  groups = import ../../lib/groups.nix;
  cfg = config.dotfiles;
in
{
  # 道具を 1 つずつ足すホスト (minimum + 道具) で、足し忘れを評価で気づけるようにする。道具が全部 on の all では成り立つ
  assertions = [
    {
      assertion = cfg.claude.privateSkills.enable -> cfg.claude.enable;
      message = ''
        dotfiles.claude.privateSkills.enable が true ですが dotfiles.claude.enable が false です。
        claude-skills は ~/.claude に繋ぐ Claude Code の skill 置き場なので、Claude Code を入れるホストでだけ有効にしてください
        (claude.enable = true; も書く)。グループ all で Claude Code を外すなら、claude.privateSkills.enable = false; と、それに頼る
        道具 (claude.devTracker.enable・dotfiles.herdr.hub.enable) の false も書いてください。
      '';
    }
    {
      assertion = cfg.claude.devTracker.enable -> cfg.claude.privateSkills.enable;
      message = ''
        dotfiles.claude.devTracker.enable が true ですが dotfiles.claude.privateSkills.enable が false です。
        Dev Tracker の skill (pjp-dev-tracker) は claude-skills にあるので、claude.privateSkills.enable = true; も書いてください
        (設定グループが minimum のホストでは、既定で false です)。グループ all で claude-skills を外すなら、claude.devTracker.enable = false;
        も書いてください。
      '';
    }
    {
      assertion = cfg.herdr.hub.enable -> (cfg.herdr.enable && cfg.claude.privateSkills.enable);
      message = ''
        dotfiles.herdr.hub.enable が true ですが dotfiles.herdr.enable か dotfiles.claude.privateSkills.enable が false です。
        集約ハブ ~/h は herdr の会話の受け口で、作る hub-init.sh は claude-skills にあります。両方を true にしてください
        (グループ all で herdr か claude-skills を外すなら、dotfiles.herdr.hub.enable = false; を書く)。
      '';
    }
  ];

  home.file.".local/state/dotfiles/group.json".text =
    builtins.toJSON {
      version = 2;
      inherit (cfg) group;
      tools = builtins.listToAttrs (
        map (t: {
          name = t.key;
          value = lib.getAttrFromPath t.option cfg;
        }) groups.tools
      );
    }
    + "\n";
}
