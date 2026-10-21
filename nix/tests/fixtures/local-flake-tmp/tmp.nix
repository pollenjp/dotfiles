# nix/tests/local-flake-tmp.nix と nix/tests/setup-local-flake.test.sh の fixture。ローカル flake の雛形
# (nix/scripts/setup-local-flake.sh) の tmp の例のコメントを 1 段外したものを、attrset の中に置いた形。
# setup-local-flake.test.sh が雛形の本文と同じかを見て、local-flake-tmp.nix がこれを評価する (雛形の例を直したら、
# これも同じに直す)。
{ dotfiles }:
{
  tmp = dotfiles.lib.mkHome {
    username = "pollenjp";
    system = "x86_64-linux";

    # WSL のマシンだけ書く (書かなければ WSL でないマシン)。
    wsl = {
      enable = true;
      # ホスト側 Windows のユーザー名 (例は作り物)。/mnt/c/Users/<名前>/... の組み立てに使う
      # (1Password の op-ssh-sign のパスと、win/ の配り先)。値はこのマシンで:
      #   pwsh.exe -NoProfile -Command '$env:USERNAME'
      windowsUserName = "alice";
      # repo 直下の win/ を Windows 側へ配る (反映は ~/dotfiles/setup --update)。
      windowsFiles.enable = true;
      # WSL から起動された Windows の .exe を、起動元の祖先付きで journald に常時記録する (ADR 012)。
      # unit を /etc へ入れるのは ~/dotfiles/setup --update の最後の手順 exe-exec-trace (中で sudo を呼ぶ)。
      exeExecTrace.enable = true;
    };
    # 1Password で git の署名をする (WSL ならホスト側 Windows の 1Password)。
    onePassword.enable = true;

    claude = {
      # Notion Dev Tracker (pjp-dev-tracker skill) をこのマシンで使うか。本体の既定は false で、
      # 使うマシンだけ true にする。CLAUDE.md の「タスク管理」の節と settings.json の
      # skillOverrides の両方がこの値から決まる。
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
        # cc-pages (cc-page のページを見せるローカル web ビューア) が待ち受ける port。
        # 書かなければ cc-pages の既定の 7777。7777 がほかと衝突するマシンだけ書く。
        # 反映は ~/dotfiles/setup --update (switch だけでもよい。daemon は switch が再起動する)。
        #   dotfiles.ccPages.port = 7778;
      }
    ];
  };
}
