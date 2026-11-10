# cursor-agent (Cursor の CLI) を入れるか (dotfiles.cursorAgent.enable) を ~/.local/state/dotfiles/cursor-agent.json に置く。
# nix/scripts/bootstrap-mise.sh が `~/dotfiles/setup --update` のたびに読み、true なら版を決めて mise の宣言
# (~/.config/mise/conf.d/dotfiles-cursor-agent.toml) に版そのものを書いて入れ、false なら setup が前に書いた宣言を消す。
#
# 宣言を home-manager で置かないのは、版を setup のたびに決めて書き換えるため (latest を宣言すると、素の mise install が
# 遅延で落ちる。bootstrap-mise.sh の cursor-agent の節)。false のホストにも置くのは、bootstrap が「false」と「この option を
# 含む世代へまだ switch していない (ファイルが無い)」を見分けるため (ntn.json・windows-files.json と同じ)。
#
# 形は option の名前のまま:
#
#   {"enable": false}
{ config, ... }:

{
  home.file.".local/state/dotfiles/cursor-agent.json".text =
    builtins.toJSON { inherit (config.dotfiles.cursorAgent) enable; } + "\n";
}
