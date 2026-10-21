# マシン登録簿。public なので、ここには型 (<user>@<system>) と検証用の sandbox だけを置く。
#
# 実機 (その PC の値の全部を持つホスト) は、private な dotfiles-private の nix/hosts/<user>@<hostname>.nix に
# 置く (ADR 026。登録は pjp-dotfiles-register-host skill)。dotfiles-private を読めない PC は、ローカル flake
# (~/dotfiles/flake.nix) に tmp を足して、その PC の値を書く (README「登録簿に載せずにマシンを足す」)。
# 型は、どちらもまだ無い PC を `~/dotfiles/setup --host <型>` で 1 回当てるためのもの (setup は推測しない。ADR 027)。
#
# home-manager は activate 時に $USER と home.username の不一致で中断するため、
# username は環境変数から取らず明示的に書く。
# (builtins.getEnv は --impure が必要になり `nix flake check` を壊す)
#
# mkHome に渡せるもの (dotfiles-private の nix/hosts/*.nix とローカル flake の tmp でも同じ):
#   username        Linux/macOS 側のユーザー名 (必須)
#   system          x86_64-linux / aarch64-linux / aarch64-darwin (必須)
#   homeDirectory   既定は /home/<username> (darwin は /Users/<username>)
#   wsl             WSL 固有の設定 (下記)。省略すれば非 WSL マシン。
#                   wsl.exeExecTrace.enable = true で、WSL から起動された Windows の .exe を
#                   祖先付きで journald に常時記録する (ADR 012。unit を /etc へ入れるのは
#                   `~/dotfiles/setup --update` の最後の手順 exe-exec-trace。中で sudo を呼ぶ)
#   onePassword     onePassword.enable = true で 1Password を git の署名に使う (ADR 022)。
#                   WSL ならホスト側 Windows の、それ以外はこのマシンの 1Password
#   claude          Claude Code のマシン固有設定。claude.devTracker.enable = true で
#                   Notion Dev Tracker (pjp-dev-tracker) を使うマシンにする (既定は使わない。ADR 027)。
#                   claude.gitViaGh.enable = false で、Claude の git・fetch 系の abbr / alias・
#                   setup の取得を gh の資格情報 (HTTPS) ではなく ssh で GitHub へ通すマシンにする
#                   (既定は gh。gh auth login が前提)。
#                   claude.notion.profile で Notion へ書く skill が既定に使う宛先のプロファイルを選ぶ (既定は null)。
#                   claude.notion.routes で、このマシンだけの宛先の規則 (origin の owner/repo → プロファイル) を足せる。
#                   claude.videoOffer.autoStart.enable = true で、設計・PR のときに解説動画の短尺を答えを
#                   待たずに作り始めるマシンにする (既定は作る前に聞く。token を大きく使うため。ADR 023)。
#   modules         mkHome の引数に無い option (home/options.nix の dotfiles.ccPages.port など) と、
#                   home-manager の設定
#
# wsl は入れ子の attrset。親が有効なときだけ子が意味を持つ、という関係を
# そのまま構造にしてある。git の署名で見ると、組み合わせは次の 4 通り:
#
#   (指定しない)                                                              非 WSL / 1Password 無し
#   onePassword.enable = true;                                                非 WSL / 1Password 有り (ssh-keygen)
#   wsl.enable = true;                                                        WSL / 1Password 無し
#   wsl = { enable = true; windowsUserName = "…"; }; onePassword.enable = true;  WSL / 1Password 有り (op-ssh-sign-wsl.exe)
#
# wsl.windowsFiles.enable = true で、repo 直下の win/ を Windows 側へ配るマシンになる
# (windowsUserName が要る。docs/adr/010_win_files_from_wsl_*)。
{ mkHome }:

{
  "pollenjp@x86_64-linux" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
  };

  "pollenjp@aarch64-linux" = mkHome {
    username = "pollenjp";
    system = "aarch64-linux";
  };

  "pollenjp@aarch64-darwin" = mkHome {
    username = "pollenjp";
    system = "aarch64-darwin";
  };

  # 検証専用。実際の $HOME を汚さずに activate を試すためのもの。
  #   HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox
  sandbox = mkHome {
    username = "user";
    system = "x86_64-linux";
    homeDirectory = "/tmp/hm-sandbox";
    # Dev Tracker を使い、Notion の宛先も選んだマシンとして検証する。Dev Tracker の既定は「使わない」
    # なので、CI の「warnings が空」の確かめがその経路を通るよう明示する。宛先を選ばないと
    # home/modules/claude.nix が warnings を出し、CI の「warnings が空」で落ちる。
    claude = {
      devTracker.enable = true;
      notion.profile = "personal";
    };
  };
}
