# 1Password の参照 (op://vault/項目/[セクション/]欄) を、vault・項目・セクション・欄の ID の参照に直す pjp-op-ref。動きは
# pjp-op-ref.sh の先頭のコメント、使い方は nix/README.md「参照を ID の形に直す (pjp-op-ref)」。
#
# op item get --format json の出力 (値も含みうる) を jq にだけ流して ID を抜き出すので、jq を runtimeInputs に入れる
# (writeShellApplication が PATH の頭に足す)。op は呼ぶ側の PATH から引く (WSL では pkgs/pjp-op の wrapper、ほかのマシンでは
# 1Password CLI)。home/modules/op-env.nix が dotfiles.onePassword.enable のマシンの PATH に、pjp-op-env と並べて入れる。
#
# errexit を付けずに書いてある (落ちうるコマンドは自分で受ける) ので、bashOptions から外す。
{ writeShellApplication, jq }:

writeShellApplication {
  name = "pjp-op-ref";
  runtimeInputs = [ jq ];
  bashOptions = [
    "nounset"
    "pipefail"
  ];
  text = builtins.readFile ./pjp-op-ref.sh;
}
