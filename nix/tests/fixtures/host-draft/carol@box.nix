# この PC (carol@box) のホストの定義と値の全部 (dotfiles の ADR 026)。ホストの名前はファイル名から .nix を除いたもの。
# ローカル flake (~/dotfiles/flake.nix) の値はこのホストには当たらない。値を変えるときはこのファイルを直す。
# 下書きは dotfiles の nix/scripts/private-host.sh draft が描いた (元にしたホスト: carol@generic。ローカル flake で評価した値)。
{ mkHome, ... }:
mkHome {
  username = "carol";
  system = "x86_64-linux";
  onePassword.enable = true;
  claude = {
    devTracker.enable = true;
    notion.profile = "work";
  };
  modules = [
    {
      dotfiles.ccPages.port = 7801;
    }
  ];
}
