# ntn (Notion CLI) の config.json の keyring (dotfiles.ntn.keyring) を ~/.local/state/dotfiles/ntn.json に置く。
# nix/scripts/bootstrap-ntn.sh が `~/dotfiles/setup --update` のたびに読み、ntn の config.json の keyring だけを
# この値にそろえる (null なら触らない。false なら token を置く config directory を 700・auth.json を 600 にもそろえる)。
#
# config.json を Nix で置かないのは、ntn が自分で書き換えるファイルだから (`ntn login` が既定の workspace を書く。
# store の読み取り専用の symlink にすると ntn が書けずに落ちる)。home.activation で書かない理由は bootstrap-ntn.sh の冒頭。
#
# 形は option の名前のまま。null も書く (ファイルが無いのは「この option を含む世代へまだ switch していない」と
# bootstrap が見分けるため):
#
#   {"keyring": false}
#
# ntn を入れないホスト (dotfiles.ntn.enable が false。既定は設定グループの ③ 個人の道具が off のとき) には置かない
# (setup は bootstrap-ntn を飛ばす)。
{ config, lib, ... }:

lib.mkIf config.dotfiles.ntn.enable {
  home.file.".local/state/dotfiles/ntn.json".text =
    builtins.toJSON { inherit (config.dotfiles.ntn) keyring; } + "\n";
}
