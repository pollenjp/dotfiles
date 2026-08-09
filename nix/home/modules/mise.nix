# mise との役割分担を宣言する。
#
#   グローバルな CLI ツール   -> Nix (home/modules/packages.nix)
#   言語ランタイム (go/node) -> mise
#   プロジェクト毎のツール固定 -> mise (mise.toml)
#
# レガシー経路の shell/060_mise.sh と .fish/060_mise.fish は、シェル起動のたびに
# ~/.config/mise/config.toml を sed -i で書き換えて 16 個のパッケージを注入する。
# Nix が CLI ツールを持つ環境ではこれを止めたい。
#
# 止める合図に環境変数ではなくマーカーファイルを使っている。
# home.sessionVariables はシェルが hm-session-vars.sh を読み込んで初めて届くが、
# それは home-manager が rc を所有する Stage 5 以降の話であり、
# Stage 4 の時点では届かないため。
# ファイルなら bash / zsh / fish のどれからでも、今すぐ読める。
#
# マーカーが存在しない環境 (= Nix 未導入のマシン) の挙動は従来どおり。
{ ... }:

{
  home.file.".local/state/dotfiles/package-manager".text = "nix\n";
}
