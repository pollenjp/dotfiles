# WSL で 1Password を使うマシンの PATH に、理由 (--reason) が必須の op と、その記録を見る op-reason-log を入れる。中身は自作の OSS の
# op-reason (pkgs/op-reason。GitHub の Release の静的な実行ファイルを版と SHA-256 で固定したもの)。
#
# WSL から直に op.exe を打つと、1Password の承認がどの pane にも共通の wslhost に付き、1 回の許可が後の呼び出しとほかの pane に
# 効く。op は呼び出しごとに Windows の op-reason.exe (動かないときは launcher.ps1) を起こして承認を閉じ、承認の画面と一緒に呼び手と
# 理由の窓を出して記録する。Windows の側 (op-reason-windows.zip) は、setup --update の nix/scripts/bootstrap-windows-op-reason.sh が
# win/op-reason/Install-OpReason.ps1 で同じ版を入れる (win/ を配るマシンだけ)。使い方と守る決まりは nix/README.md
# 「WSL の op を理由つきで呼ぶ (1Password CLI)」、op-reason の細部はその README (`op-reason --skill` は AI エージェント向けの手引き)。
#
# 入る条件は ssh.nix の ssh・ssh-add の wrapper と同じ (dotfiles.wsl.enable と dotfiles.onePassword.enable が両方 true)。
# option は持たない。Claude の hook (files/claude/hooks/op-reason-guard.sh) はどのマシンにも置くので (claude.nix)、
# この op があるかを ~/.local/state/dotfiles/claude-op-reason.json ({"enable": <bool>}) で知らせる。false でも必ず書く。
# pjp-op-env・pjp-op-ref (home/modules/op-env.nix) と bootstrap-windows-op-reason.sh も、同じファイルを読む。
#
# op・op-reason・op-reason-log は、op-reason の実行ファイルを makeWrapper で包み、既定の環境変数を 2 つ足す (--set-default なので、
# 環境に値があればそちらが勝つ)。home.sessionVariables にしないのは、ログインし直すまで今の shell に入らず、switch の直後の op が
# op-reason.exe を見つけられないため。呼び名で動きが変わる (op-reason-log は記録を見る道具) ので、包みごとに argv[0] を渡す。
#
#   OPREASON_EXE   Windows の op-reason.exe の WSL のパス。Install-OpReason.ps1 の既定の置き場所 (%LOCALAPPDATA%\Programs\op-reason)
#                  を、dotfiles.wsl.windowsUserName (無ければ wsl.onePassword.windowsUserName) で組み立てる。Windows の PATH に
#                  足さずに済み、WSL が Windows の PATH を読み直す (wsl --shutdown) のも待たない。launcher.ps1 はその隣から探す
#   OPREASON_LANG  ja (文・窓・記録の表を日本語にする)
#
# fish の op と op-reason の補完 (op を呼ばない。pkgs/op-reason が出したもの) も、入るマシンにだけ ~/.config/fish/completions に置く。
# fish に同梱の op の補完は、補完を初めて使うときに op completion fish を打ち、wrapper が理由なしとして断った文を端末に出す。fish は
# fish_complete_path の頭にある ~/.config/fish/completions を先に探すので、こちらが読まれる。入らないマシンの fish は、同梱の補完
# (本物の op を呼ぶ) のまま。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles;
  enable = cfg.wsl.enable && cfg.onePassword.enable;
  opReason = pkgs.callPackage ../../pkgs/op-reason { };

  windowsUserName =
    if cfg.wsl.windowsUserName != null then
      cfg.wsl.windowsUserName
    else
      cfg.wsl.onePassword.windowsUserName;
  # win/op-reason/Install-OpReason.ps1 の -InstallDir の既定 (%LOCALAPPDATA%\Programs\op-reason) の op-reason.exe
  exePath =
    if windowsUserName == null then
      null
    else
      "/mnt/c/Users/${windowsUserName}/AppData/Local/Programs/op-reason/op-reason.exe";

  wrapped =
    pkgs.runCommand "op-reason-dotfiles-${opReason.version}"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        inherit (opReason) meta;
        passthru = {
          unwrapped = opReason;
          inherit exePath;
        };
      }
      ''
        mkdir -p "$out/bin" "$out/share"
        for name in op op-reason op-reason-log; do
          makeWrapper ${opReason}/bin/op-reason "$out/bin/$name" --argv0 "$name" \
            --set-default OPREASON_LANG ja ${
              lib.optionalString (exePath != null) "--set-default OPREASON_EXE ${lib.escapeShellArg exePath}"
            }
        done
        ln -s ${opReason}/share/fish "$out/share/fish"
      '';
in
{
  home.packages = lib.optional enable wrapped;

  xdg.configFile = lib.mkIf (enable && config.programs.fish.enable) {
    "fish/completions/op.fish".source = "${opReason}/share/fish/vendor_completions.d/op.fish";
    "fish/completions/op-reason.fish".source =
      "${opReason}/share/fish/vendor_completions.d/op-reason.fish";
  };

  home.file.".local/state/dotfiles/claude-op-reason.json".text =
    builtins.toJSON { inherit enable; } + "\n";
}
