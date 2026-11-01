# ntn (Notion CLI) の config.json の keyring (dotfiles.ntn.keyring) を ~/.local/state/dotfiles/ntn.json に置く。
# nix/scripts/bootstrap-ntn.sh が `~/dotfiles/setup --update` のたびに読み、ntn の config.json の keyring だけを
# この値にそろえる (null なら触らない)。
#
# config.json を Nix で置かないのは、ntn が自分で書き換えるファイルだから (`ntn login` が既定の workspace を書く。
# store の読み取り専用の symlink にすると ntn が書けずに落ちる)。home.activation で書かない理由は bootstrap-ntn.sh の冒頭。
#
# 形は option の名前のまま。null も書く (ファイルが無いのは「この option を含む世代へまだ switch していない」と
# bootstrap が見分けるため):
#
#   {"keyring": false}
{ config, ... }:

{
  home.file.".local/state/dotfiles/ntn.json".text =
    builtins.toJSON { inherit (config.dotfiles.ntn) keyring; } + "\n";
}
