# mise の遅延 (dotfiles.mise.minimumReleaseAge) と、期間を区切った上書き (dotfiles.mise.releaseAgeOverrides) を
# ~/.local/state/dotfiles/mise-release-age.json に置く。nix/scripts/bootstrap-mise.sh が `~/dotfiles/setup --update` の
# たびに読み、今日の日付 (Asia/Tokyo) から ~/.config/mise/config.toml の minimum_release_age に書く値を決める。
#
# 上書きが始まったか・終わったかをここ (Nix) で決めないのは、home-manager の評価が pure で今日の日付を読めないため。
# config.toml を Nix で置かないのは、mise が実行時に書き換えるファイルだから (bootstrap-mise.sh の冒頭)。
#
# 形は option の名前のまま。項目は既定を埋めた from・zeroDays・reason の 3 つの欄だけを書く:
#
#   {"minimumReleaseAge": "9d", "releaseAgeOverrides": [{"from": "2026-10-22", "zeroDays": 3, "reason": "…"}]}
{ config, ... }:

let
  cfg = config.dotfiles.mise;
in
{
  home.file.".local/state/dotfiles/mise-release-age.json".text =
    builtins.toJSON {
      inherit (cfg) minimumReleaseAge;
      releaseAgeOverrides = map (o: { inherit (o) from zeroDays reason; }) cfg.releaseAgeOverrides;
    }
    + "\n";
}
