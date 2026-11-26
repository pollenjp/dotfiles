# nix/tests/local-flake-tmp.nix と nix/tests/setup-local-flake.test.sh の fixture。ローカル flake の雛形
# (nix/scripts/setup-local-flake.sh) の tmp の例 (描いたあとに差し込む設定グループの選び方の塊も含む) のコメントを 1 段外した
# ものを、attrset の中に置いた形。
# setup-local-flake.test.sh が雛形の本文と同じかを見て、local-flake-tmp.nix がこれを評価する (雛形の例を直したら、
# これも同じに直す)。
{ dotfiles }:
{
  tmp = dotfiles.lib.mkHome {
    username = "pollenjp";
    system = "x86_64-linux";

    # 設定グループ (本体の nix/README.md「設定グループ」と nix/groups.md)。グループは道具の集合で、"minimum"
    # (どの PC にも初めからあってほしいもの。書かなければこれ) と "all" (道具を全部) の 2 つ。ほとんどの PC は
    # "minimum" にして、使う道具を下で 1 つずつ足す (この例は Claude Code 一式・herdr などを足した個人の PC の形)。
    # 道具を足さない PC (客先の PC など) は、下の道具の行を消す。git の名前とメールも入らないので、modules に
    # programs.git.settings.user = { name = "…"; email = "…"; }; を書く (書かなければ git が commit の前に止まる)
    group = "minimum";

    # WSL のマシンだけ書く (書かなければ WSL でないマシン)。
    wsl = {
      enable = true;
      # ホスト側 Windows のユーザー名 (例は作り物)。/mnt/c/Users/<名前>/... の組み立てに使う
      # (1Password の op-ssh-sign のパスと、win/ の配り先)。値はこのマシンで:
      #   pwsh.exe -NoProfile -Command '$env:USERNAME'
      windowsUserName = "alice";
      # repo 直下の win/ を Windows 側へ配る (反映は ~/dotfiles/setup --update)。
      windowsFiles.enable = true;
      # win/ を配るマシンで入れる Windows の道具 (minimum に入らないので足す。使わない行は消す):
      # Claude Code・herdr と herdr-app・ntn・claude-personal と claude-work・Claude Desktop。最後の 2 つは Windows の
      # runner の道具で、WSL の setup は入れない (要約に出る。runner では win/hosts の toml の [tools] に書く)。
      windowsFiles.claudeCode.enable = true;
      windowsFiles.herdr.enable = true;
      windowsFiles.ntn.enable = true;
      windowsFiles.claudeAccounts.enable = true;
      windowsFiles.claudeDesktop.enable = true;
      # WSL から起動された Windows の .exe を、起動元の祖先付きで journald に常時記録する (ADR 012)。
      # unit を /etc へ入れるのは ~/dotfiles/setup --update の最後の手順 exe-exec-trace (中で sudo を呼ぶ)。
      exeExecTrace.enable = true;
    };
    # 1Password で git の署名をする (WSL ならホスト側 Windows の 1Password)。
    onePassword.enable = true;

    claude = {
      # Claude Code 一式 (設定・hook・skill・status line・plugin・mise の claude) と、private な skill 置き場
      # (claude-skills の clone。Dev Tracker の skill もここ)。どちらも minimum に入らないので、使うマシンで足す。
      enable = true;
      privateSkills.enable = true;

      # Notion Dev Tracker (pjp-dev-tracker skill) をこのマシンで使うか。minimum に入らないので、
      # 使うマシンだけ true にする (skill は claude-skills にあるので、上の 2 行が要る)。CLAUDE.md の
      # 「タスク管理」の節と settings.json の skillOverrides の両方がこの値から決まる。
      # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
      devTracker.enable = true;

      # Notion へ書く skill (pjp-dev-tracker・pjp-notion-authoring など) の宛先。
      # 宛先は作業中の repo で決まる: このマシンの routes → claude-skills の profiles.toml の
      # [routes] → この profile (規則に当たらない repo と repo の外で使う既定)。
      # 値は private の claude-skills (skills/pjp-notion-profile/profiles.toml) にあり、
      # ここでは名前を選ぶ ("personal" / "work")。書かなければ null で、規則に当たらない所で
      # skill は止まる (devTracker.enable = true なら、評価のたびに警告も出る)。
      # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
      notion.profile = "personal";
      # このマシンだけ規則を足す・上書きする (例: 会社の PC で pollenjp の repo も work に書く)。
      # 共通の [routes] より先に見る:
      #   notion.routes = { "pollenjp/*" = "work"; };
      # このマシンだけプロファイルの値を差し替える (外側はプロファイルの名前。null はキーを消す):
      #   notion.override = { personal = { scanData = "https://app.notion.com/p/…"; }; };

      # Claude のセッションの git と、fetch 系の abbr / alias (gf・gfp・gpul など) と、
      # setup の取得 (bootstrap の clone / 取得と本体の更新) を、gh の資格情報で GitHub へ
      # HTTPS で通すか (setup の取得は、gh で取れなければ ssh で取り直す)。
      # 本体の既定は true で、gh auth login 済みが前提 (未ログインなら setup が警告する)。
      # gh にログインしないマシンは false にすると、今までどおり ssh を通る。
      # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
      #   gitViaGh.enable = false;

      # 設計を出したとき・PR を作ったときに、解説動画の短尺を答えを待たずに裏で作り始めるか
      # (claude-skills の pjp-video-explainer-offer)。本体の既定は false で、作る前に「解説動画を
      # 作りますか？」と聞き、選ばれたときだけ作る (1 本ごとに token を大きく使うため)。
      # 聞かずに作り始めたいマシンだけ true にする。
      # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
      #   videoOffer.autoStart.enable = true;
    };

    # mkHome の引数に無い option (本体の nix/home/options.nix) と home-manager の設定は、modules に書く。
    modules = [
      {
        # minimum に足す道具 (使わない行は消す): herdr・集約ハブ ~/h・herdr-core (hc。Linux)・cc-pages・
        # ntn (Notion の CLI)・git の名前とメール (個人のアカウント)。
        dotfiles.herdr.enable = true;
        dotfiles.herdr.hub.enable = true;
        dotfiles.herdrCore.enable = true;
        dotfiles.ccPages.enable = true;
        dotfiles.ntn.enable = true;
        dotfiles.git.identity.enable = true;

        # cc-pages (cc-page のページを見せるローカル web ビューア) が待ち受ける port。
        # 書かなければ cc-pages の既定の 7777。7777 がほかと衝突するマシンだけ書く。
        # 反映は ~/dotfiles/setup --update (switch だけでもよい。daemon は switch が再起動する)。
        #   dotfiles.ccPages.port = 7778;
      }
    ];
  };
}
