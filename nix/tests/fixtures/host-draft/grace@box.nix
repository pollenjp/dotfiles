# この PC (grace@box) のホストの定義と値の全部 (dotfiles の ADR 026)。ホストの名前はファイル名から .nix を除いたもの。
# ローカル flake (~/dotfiles/flake.nix) の値はこのホストには当たらない。値を変えるときはこのファイルを直す。
{ mkHome, ... }:
mkHome {
  username = "grace";
  system = "x86_64-linux";
  group = "minimum";
  claude = {
    devTracker.enable = true;
    enable = true;
    notion.profile = "work";
    privateSkills.enable = true;
  };
  modules = [
    {
      dotfiles.git.identity.enable = true;
      dotfiles.ntn.enable = true;
    }
  ];
}
