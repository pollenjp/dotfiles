# マシン登録簿。1 マシン 1 エントリで追加する。
#
# 実機 (その PC の値の全部を持つホスト) は、private な dotfiles-private の nix/hosts/<user>@<hostname>.nix に
# 置く方向にした (ADR 026。登録は pjp-dotfiles-register-host skill)。ここには型 (<user>@<system>) と検証用の
# sandbox を残す。今ある実機の行 (pollenjp@wsl・pollenjp@wsl-no-1password・pollenjp@laptop) は、実機が全部
# dotfiles-private に移るまで (段階 3) 残す。
#
# home-manager は activate 時に $USER と home.username の不一致で中断するため、
# username は環境変数から取らず明示的に書く。
# (builtins.getEnv は --impure が必要になり `nix flake check` を壊す)
#
# mkHome に渡せるもの:
#   username        Linux/macOS 側のユーザー名 (必須)
#   system          x86_64-linux / aarch64-linux / aarch64-darwin (必須)
#   homeDirectory   既定は /home/<username> (darwin は /Users/<username>)
#   wsl             WSL 固有の設定 (下記)。省略すれば非 WSL マシン。
#                   wsl.exeExecTrace.enable = true で、WSL から起動された Windows の .exe を
#                   祖先付きで journald に常時記録する (ADR 012。unit を /etc へ入れるのは
#                   `~/dotfiles/setup --update` の最後の手順 exe-exec-trace。中で sudo を呼ぶ)
#   onePassword     onePassword.enable = true で 1Password を git の署名に使う (ADR 022)。
#                   WSL ならホスト側 Windows の、それ以外はこのマシンの 1Password
#   claude          Claude Code のマシン固有設定。claude.devTracker.enable = false で
#                   Notion Dev Tracker (pjp-dev-tracker) を使わないマシンにする (既定は使う)。
#                   claude.gitViaGh.enable = false で、Claude の git・fetch 系の abbr / alias・
#                   setup の取得を gh の資格情報 (HTTPS) ではなく ssh で GitHub へ通すマシンにする
#                   (既定は gh。gh auth login が前提)。
#                   claude.notion.profile で Notion へ書く skill が既定に使う宛先のプロファイルを選ぶ (既定は null)。
#                   claude.notion.routes で、このマシンだけの宛先の規則 (origin の owner/repo → プロファイル) を足せる。
#                   claude.videoOffer.autoStart.enable = true で、設計・PR のときに解説動画の短尺を答えを
#                   待たずに作り始めるマシンにする (既定は作る前に聞く。token を大きく使うため。ADR 023)。
#                   会社のマシンのように public に載せたくない差分は、この登録簿ではなく
#                   ローカル flake (~/dotfiles/flake.nix) の local module に書く。雛形は
#                   devTracker.enable = false を既定にしている (README「登録簿に載せずにマシンを足す」)
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

  # WSL + ホスト側 Windows の 1Password。
  # git の署名は Windows 側の op-ssh-sign-wsl.exe を経由する。
  # repo 直下の win/ (Orca の設定など) も Windows 側へ配る。
  "pollenjp@wsl" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    wsl = {
      enable = true;
      # ホスト側 Windows のユーザー名。/mnt/c/Users/<名前>/... の組み立てに使う
      # (1Password の op-ssh-sign のパスと、win/ の配り先)。
      #
      # 値は WSL 上で次を実行すると判る:
      #   pwsh.exe -NoProfile -Command '$env:USERNAME'
      # (pwsh.exe が無ければ powershell.exe でも同じ)
      #
      # Nix の評価は純粋なのでこのコマンドを評価時に実行することはできない。
      # (getEnv や --impure は nix flake check を壊す)。よってここに直接書く。
      windowsUserName = "polle";
      windowsFiles.enable = true;
      # WSL から起動された Windows の .exe (ssh.exe など) を、起動元の祖先付きで journald に
      # 常時記録する (ADR 012)。1Password の承認ダイアログは要求元を「Windows Terminal」と
      # しか出さず、承認後は同じタブのどのプロセスも黙って鍵を使えるため。
      # eBPF に root が要るので、home-manager switch だけでは unit ファイルが置かれるだけで
      # 何も動かない。`~/dotfiles/setup --update` の最後の手順 exe-exec-trace が /etc へ
      # 入れて起こす (中で sudo を呼ぶ)。
      exeExecTrace.enable = true;
    };
    onePassword.enable = true;
  };

  # WSL だがホスト側に 1Password が無いマシン。
  # git の署名設定は一切書き出されない (署名なしで commit できる)。
  # onePassword を書かないので windowsUserName も要らない。
  "pollenjp@wsl-no-1password" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    wsl.enable = true;
  };

  # NixOS の実機 (NEC LaVie、nixos-config の laptop)。system 側は nixos-config が持ち、
  # home はここから standalone で当てる (nixos-config の ADR 002)。
  "pollenjp@laptop" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    # git の署名を lavie の 1Password の鍵で行う (ssh-keygen が SSH_AUTH_SOCK のエージェントで署名する)。
    # SSH_AUTH_SOCK を 1Password へ向けるのは nixos-config (ADR 009)。ssh で入ったときは
    # 転送されてきたエージェント (Windows の 1Password) の同じ鍵で署名する (ADR 022)。
    onePassword.enable = true;
  };

  # 検証専用。実際の $HOME を汚さずに activate を試すためのもの。
  #   HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox
  sandbox = mkHome {
    username = "user";
    system = "x86_64-linux";
    homeDirectory = "/tmp/hm-sandbox";
    # Dev Tracker を使い、Notion の宛先も選んだマシンとして検証する。選ばないと
    # home/modules/claude.nix が warnings を出し、CI の「warnings が空」で落ちる。
    claude.notion.profile = "personal";
  };
}
