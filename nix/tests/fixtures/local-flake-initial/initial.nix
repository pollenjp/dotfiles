# nix/tests/local-flake-initial.nix・nix/tests/setup-local-flake.test.sh と、flake の checks の home-wsl-initial-example の
# fixture。setup-local-flake.sh --initial がローカル flake に差し込む初期用のホスト initial の塊を、作り物の値
# (username pollenjp・system x86_64-linux・Windows のユーザー名 alice) で書き、attrset の中に置いた形。
# setup-local-flake.test.sh が差し込んだ塊と同じかを見て、local-flake-initial.nix がこれを評価する (塊を直したら、
# これも同じに直す)。
{ dotfiles }:
{
  initial = dotfiles.lib.mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    # 設定グループは minimum に、新しい PC の手順で使う道具 (Claude Code 一式・dotfiles の skill の claude-skills・herdr・
    # Windows の Claude Code と herdr など) を足す
    group = "minimum";
    wsl = {
      enable = true;
      windowsUserName = "alice";
      windowsFiles.enable = true;
      windowsFiles.claudeCode.enable = true;
      windowsFiles.herdr.enable = true;
      # claude-personal・claude-work と Claude Desktop は Windows の runner の道具 (WSL の setup は入れない。要約に出る)
      windowsFiles.claudeAccounts.enable = true;
      windowsFiles.claudeDesktop.enable = true;
      windowsFiles.ntn.enable = true;
    };
    claude = {
      enable = true;
      privateSkills.enable = true;
    };
    modules = [
      {
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.herdrCore.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;
      }
    ];
  };
}
