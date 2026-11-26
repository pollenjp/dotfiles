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
#   group           設定グループ (道具の集合)。minimum (どの PC にも初めからあってほしいもの。既定)・all (道具を全部)。
#                   グループに入る道具の switch が既定で on になる。道具の switch (claude.enable・dotfiles.ntn.enable など)
#                   で足す・外す (nix/README.md「設定グループ」)
#   wsl             WSL 固有の設定 (下記)。省略すれば非 WSL マシン。
#                   wsl.exeExecTrace.enable = true で、WSL から起動された Windows の .exe を
#                   祖先付きで journald に常時記録する (ADR 012。unit を /etc へ入れるのは
#                   `~/dotfiles/setup --update` の最後の手順 exe-exec-trace。中で sudo を呼ぶ)。
#                   wsl.mtuGuard.enable = true で、eth0 の MTU を上限 (wsl.mtuGuard.maxMtu。既定 1350) まで
#                   下げ続ける見張りを置く (VPN の PMTU ブラックホールを避ける。unit を /etc へ入れるのは
#                   `~/dotfiles/setup --update` の手順 wsl-mtu-guard。中で sudo を呼ぶ)
#   onePassword     onePassword.enable = true で 1Password を git の署名に使う (ADR 022)。
#                   WSL ならホスト側 Windows の、それ以外はこのマシンの 1Password
#   claude          Claude Code のマシン固有設定。claude.devTracker.enable = true で
#                   Notion Dev Tracker (pjp-dev-tracker) を使うマシンにする (既定は使わない。ADR 027)。
#                   claude.devTracker.inbox.enable = true で、チケットのコメントをハブ (~/h) の会話へ届ける
#                   見回り役 (ticket.sh inbox) を systemd の user service で常駐させる (Linux。既定は置かない)。
#                   claude.gitViaGh.enable = false で、Claude の git・fetch 系の abbr / alias・
#                   setup の取得を gh の資格情報 (HTTPS) ではなく ssh で GitHub へ通すマシンにする
#                   (既定は gh。gh auth login が前提)。
#                   claude.notion.profile で Notion へ書く skill が既定に使う宛先のプロファイルを選ぶ (既定は null)。
#                   claude.notion.routes で、このマシンだけの宛先の規則 (origin の owner/repo → プロファイル) を足せる。
#                   claude.videoOffer.autoStart.enable = true で、設計・PR のときに解説動画の短尺を答えを
#                   待たずに作り始めるマシンにする (既定は作る前に聞く。token を大きく使うため。ADR 023)。
#                   claude.heavyJobs.limitPercent で、重い処理 (動画の書き出し・推論など) が使ってよい CPU と
#                   メモリの、マシン全体に対する割合 (%) を決める (既定 70。claude-skills の skill pjp-heavy-jobs が
#                   systemd の user slice に上限を付け、会話をまたいだ合計に効かせる。ADR 043)。
#                   claude.iacGuard.enable = false で、Claude が打つ terraform・tofu・terragrunt の apply など (実物を
#                   変える操作) を止める hook を外す (既定は止める。agent が sandbox で自分で apply するマシンだけ)。
#   modules         mkHome の引数に無い option (home/options.nix の dotfiles.ccPages.port など) と、
#                   home-manager の設定。dotfiles.linger.enable (既定は herdr-core と同じ) は、systemd の linger を
#                   `~/dotfiles/setup --update` の手順 linger が有効にするか (中で sudo を呼ぶ。要らないホストは false)
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
# (windowsUserName が要る。dotfiles-private の docs/adr/010_win_files_from_wsl_*)。
# そのうえで wsl.windowsFiles.typeClipboard.enable = true にすると、Windows に自作の type-clipboard を
# 固定した版で入れる (minimum では既定で入れない。入れるのは `~/dotfiles/setup --update` の bootstrap。win/README.md の「type-clipboard」)。
# Windows の道具 (wsl.windowsFiles.<道具>.enable) は、グループ all のマシンでだけ既定で入る (minimum のマシンは使うものを true にする):
# ntn と Claude Code と herdr (winget などで固定した版。win/README.md の「ntn」「Claude Code」「herdr」)・Tailscale (VPN の道具。
# win/README.md の「Tailscale」)・sshd (OpenSSH Server。PC に外から入る口で、鍵は wsl.windowsFiles.sshd.authorizedKeys。Tailscale と
# localhost からだけ、鍵でだけ入れる。win/README.md の「sshd」)・type-clipboard。T3 Code と Claude Desktop (MSIX) と claude-personal・
# claude-work は Windows の runner だけが入れる (Windows のホストの値の [tools]。win/README.md の「T3 Code」「Claude Desktop」)。
{ mkHome }:

# 型と sandbox は minimum に、前の既定 (ADR 057 の personal) で入っていた道具を足した形 (Claude Code 一式・claude-skills・herdr・集約ハブ・
# herdr-core (Linux だけ)・cc-pages・ntn・git の名前とメール)。グループを minimum・all にしたとき (dotfiles-private の ADR 109)、入るものを
# 変えないように書き直した。macOS の型は herdr-core (Linux だけ) を書かない (linger も herdrCore に従って off のまま)
{
  "pollenjp@x86_64-linux" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    group = "minimum";
    claude = {
      enable = true;
      privateSkills.enable = true;
    };
    modules = [
      {
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.herdrCore.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;
      }
    ];
  };

  "pollenjp@aarch64-linux" = mkHome {
    username = "pollenjp";
    system = "aarch64-linux";
    group = "minimum";
    claude = {
      enable = true;
      privateSkills.enable = true;
    };
    modules = [
      {
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.herdrCore.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;
      }
    ];
  };

  "pollenjp@aarch64-darwin" = mkHome {
    username = "pollenjp";
    system = "aarch64-darwin";
    group = "minimum";
    claude = {
      enable = true;
      privateSkills.enable = true;
    };
    modules = [
      {
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;
      }
    ];
  };

  # 検証専用。実際の $HOME を汚さずに activate を試すためのもの。
  #   HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox
  sandbox = mkHome {
    username = "user";
    system = "x86_64-linux";
    homeDirectory = "/tmp/hm-sandbox";
    group = "minimum";
    # Dev Tracker を使い、Notion の宛先も選んだマシンとして検証する。Dev Tracker は minimum に入らない (使うホストが書く) ので、
    # CI の「warnings が空」の確かめがその経路を通るよう明示する。宛先を選ばないと home/modules/claude.nix が warnings を出し、
    # CI の「warnings が空」で落ちる。Dev Tracker の skill に要る Claude Code と claude-skills と、型と同じ道具も書く
    claude = {
      enable = true;
      privateSkills.enable = true;
      devTracker.enable = true;
      notion.profile = "personal";
    };
    modules = [
      {
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.herdrCore.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;
      }
    ];
  };
}
