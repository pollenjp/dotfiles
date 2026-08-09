# starship プロンプト。
#
# settings は **あえて使わない**。
#
# programs.starship.settings に fromTOML した内容を渡すと、home-manager が
# Nix の attrset から TOML を書き戻すことになる。complete/starship.toml は
# 複数行の format 文字列 (罫線素片入り)、TOML のリテラル文字列 ('...') 内の
# エスケープ (\[ など)、行継続のバックスラッシュを含んでおり、
# 往復変換で壊れる危険に見合う利点がない。
#
# settings が空のとき home-manager は ~/.config/starship.toml を生成しないため、
# Stage 3 で入れた xdg.configFile による素のファイル配置がそのまま残る。
# それでいて enable = true にしておけば starship 本体が入り、
# Stage 5 でシェル統合を有効にするときはフラグを反転するだけで済む。
{ ... }:

{
  programs.starship = {
    enable = true;

    # シェル設定を home-manager が所有するのは Stage 5 から。
    # それまで有効にすると、まだ管理していない rc に init を差し込もうとする。
    enableBashIntegration = false;
    enableFishIntegration = false;
    # zsh は Nix の対象外なので常に false
    enableZshIntegration = false;
  };
}
