# Windows 側へ配るかどうかと、配り先の Windows のホームを bootstrap に伝える。
#
# 置くものは 2 つ:
#
#   1. ~/.local/state/dotfiles/windows-files.json (全ホスト)
#
#        {"enable":true,"version":1,"windowsHome":"/mnt/c/Users/<名前>"}
#
#   2. PATH の pjp-google-ime (windowsFiles.enable のホストだけ)。Google 日本語入力の
#      設定とテキストを行き来させる道具で、nix/scripts/bootstrap-windows-google-ime.sh が
#      PATH から呼ぶ (ADR 015)
#
# 配る中身 (repo 直下の win/) はここでは読まない。ローカル flake は本体を
# path:<repo>/nix で読むので、この評価から win/ は見えない (ADR 010 §1 の 3)。
# win/ を読んで /mnt/c へコピーするのは nix/scripts/bootstrap-windows-files.sh、Google 日本語入力の
# 設定を組み立てて置くのは nix/scripts/bootstrap-windows-google-ime.sh。
#
# windows-files.json は全ホストで置く。enable = false でも置くのは、bootstrap が
# 「まだ switch していない (ファイルが無い)」と「このマシンは配らない」を区別できる
# ようにするため (claude-skill-overrides.json が "on" でも書くのと同じ)。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  wsl = config.dotfiles.wsl;
  enable = wsl.windowsFiles.enable;
  # Google 日本語入力の設定とテキストを行き来させる道具 (ADR 015)。bootstrap-windows-google-ime.sh が
  # PATH から呼ぶ。win/ を配るマシンでだけ要る
  googleIme = pkgs.callPackage ../../pkgs/pjp-google-ime { };
in
{
  # 階層で表現しきれない「親が false なのに子が true」を評価時に止める (git.nix と同じ)。
  assertions = [
    {
      assertion = enable -> wsl.enable;
      message = ''
        dotfiles.wsl.windowsFiles.enable が true ですが dotfiles.wsl.enable が false です。
        win/ は WSL から /mnt/c 越しに配るので、WSL のマシンでだけ有効にしてください。
      '';
    }
    {
      assertion = enable -> wsl.windowsUserName != null;
      message = ''
        dotfiles.wsl.windowsFiles.enable が true ですが dotfiles.wsl.windowsUserName が未設定です。
        配り先 (/mnt/c/Users/<名前>) を組み立てられません。
        hosts/default.nix の wsl.windowsUserName を指定してください。
      '';
    }
  ];

  home.packages = lib.optional enable googleIme;

  home.file.".local/state/dotfiles/windows-files.json".text =
    builtins.toJSON {
      version = 1;
      inherit enable;
      # 名前が無いときに null の補間で先に落ちると、上の assertion のメッセージが
      # 見えなくなる。null にしておいて assertion に止めさせる。
      windowsHome =
        if enable && wsl.windowsUserName != null then "/mnt/c/Users/${wsl.windowsUserName}" else null;
    }
    + "\n";
}
