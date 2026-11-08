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
    wsl = {
      enable = true;
      windowsUserName = "alice";
      windowsFiles.enable = true;
    };
  };
}
