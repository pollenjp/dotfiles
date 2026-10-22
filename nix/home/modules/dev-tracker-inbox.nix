# Dev Tracker のチケットに書いたコメントを、ハブ (~/h) の会話へ届ける見回り役の常駐設定
# (dotfiles.claude.devTracker.inbox.enable。TKT-306。仕組みの設計は TKT-302)。
#
# 見回り役の本体は private な claude-skills の pjp-dev-tracker にある `ticket.sh inbox`。herdr で動いているハブの
# 会話のチケットのページへのコメントを 30 秒ごとに読み、ユーザーが書いたものをその会話の入力欄へ打つ
# (herdr agent prompt)。ここではそれを systemd の user service (pjp-dev-tracker-inbox) として常駐させる。
#
#   ~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh inbox
#
# 本体と同じく、ticket.sh も Nix ではなく claude-skills の作業クローンにある (bootstrap-claude-skills.sh の
# 「なぜ Nix (flake input) で管理しないのか」)。Nix が置くのは unit だけ。
#
# ## 呼ぶ口 (claude-skills と決めたこと。設計の 3.10)
#
#   - 常駐し、SIGTERM・SIGINT で終了コード 0 で終わる。見回りの間隔は --interval <秒> (既定 30)
#   - 設定の誤り (ユーザーの Notion の id が無い・プロファイルが決まらない) は終了コード 2
#   - 1 回の見回りの失敗 (ntn・herdr の一時的な失敗) では終わらない
#   - ログは標準出力・標準エラー (journal に入る)。何もしなかった見回りでは出さない
#   - Notion の API キーは ticket.sh が自分で ~/.config/pjp/env から読む (unit では渡さない)
#
# ## 使うホストだけに置く
#
# dotfiles-private に登録したホストは 4 台とも Dev Tracker を使い、うち 3 台が同じ personal の Dev Tracker を見る。
# 全部で動かすと、herdr に会話の無いチケットへ「会話が止まっています」と返す見回り (設計の 3.5) を、そのチケットの
# 会話を持たない別のマシンもしてしまう。そこで devTracker.enable とは別の option にし、使うホストだけ true を書く
# (home/options.nix)。devTracker.enable が false のマシンで true にしたら評価で止める。
#
# ## 置かれていないときは飛ばす
#
# ConditionPathExists で ticket.sh を、ConditionPathIsDirectory でハブ (~/h) を見る。claude-skills を取れない・
# ハブがまだ無いマシンでは、failed で残らず「条件不成立でスキップ」になる (cc-pages.nix と同じ考え方)。ハブが無い
# マシンには届け先の会話も無い。cwd もハブにする (ticket.sh は cwd の repo で Notion の宛先を決めるので、ハブの
# 会話と同じ宛先になる)。
#
# ## 再起動
#
# 落ちたら 30 秒 (見回りの間隔と同じ) おいて起こし直す。ただし終了コード 2 では起こし直さない
# (RestartPreventExitStatus)。直すまで何度起こしても同じところで止まるため。inbox がまだ無い ticket.sh も、
# argparse が知らないサブコマンドを終了コード 2 で断るので止まったまま待つ (claude-skills より先に
# dotfiles を switch しても、再起動を繰り返さない)。2 以外で落ち続ける (python3 も nix も無いなど) ときのために、
# 10 分に 5 回起こしたら諦める (StartLimitBurst)。
#
# 止まったものを起こし直すのは setup (nix/scripts/bootstrap-dev-tracker-inbox.sh)。claude-skills を進めても
# unit ファイルは変わらないので、switch (sd-switch) は再起動しない。動いている見回り役は古いコードのまま残り、
# 2 で止まっていれば止まったまま。setup --update の bootstrap-dev-tracker-inbox.sh (order 70) が、
# bootstrap-claude-skills.sh (50) が clone を進めた後に reset-failed して restart する。
#
# 止めるとき (switch で unit が消える・restart) は SIGTERM を本体 (python3。ticket.sh は exec でつなぐ) にだけ送る
# (KillMode=mixed)。打っている途中の herdr agent prompt・ntn を巻き込まない。本体が終われば残りは SIGKILL。
#
# ## PATH
#
# systemd の user manager の PATH は /usr/bin などだけで、ticket.sh が使う ntn (~/bin)・herdr と git
# (home-manager の profile)・nix (python3 が 3.11 より古いと claude-skills の devShell へ入り直す) が無い。
# ログインシェルと同じ順に並べて渡す。herdr は HERDR_* の無い環境でも既定の socket で server に届く。
#
# ## SSH を全部切っても止まらないか (linger)
#
# このユーザーは linger しない (Linger=no)。それでも、herdr の server が動いている間は止まらない: logind は
# KillUserProcesses=false で、SSH を切っても server の残る login session は closing のまま残り、その session が
# user manager (user@<uid>.service) を生かす。2026-10-21 の GCP の VM では、SSH が 1 本も無い 10 時間あまりの間、
# 同じ形の cc-pages.service が止まらなかった (TKT-306)。止まるのは server が落ちて SSH も無いときだけで、その間は
# 届ける先の会話も無い (次に SSH で入ると user manager とともに上がり、溜まったコメントを拾う)。
#
# macOS には systemd が無いので常駐しない (launchd の agent は置いていない)。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.claude.devTracker;
  ticketSh = "%h/.claude/skills/pjp-dev-tracker/scripts/ticket.sh";
  hub = "%h/h";
in
{
  # 階層で表現しきれない「親が false なのに子が true」を評価時に止める (exe-exec-trace.nix と同じ)。
  assertions = [
    {
      assertion = cfg.inbox.enable -> cfg.enable;
      message = ''
        dotfiles.claude.devTracker.inbox.enable = true は dotfiles.claude.devTracker.enable = true のマシンでだけ使えます。
        Dev Tracker のチケットのコメントを、ハブの会話へ届ける見回り役です (pjp-dev-tracker の ticket.sh inbox)。
      '';
    }
  ];

  systemd.user.services.pjp-dev-tracker-inbox = lib.mkIf (cfg.enable && cfg.inbox.enable) {
    Unit = {
      Description = "pjp-dev-tracker inbox — Dev Tracker のチケットのコメントをハブの会話へ届ける見回り役";
      # claude-skills を取れない・ハブがまだ無いマシンでは静かにスキップする (上の「置かれていないときは飛ばす」)。
      # ticket.sh は bash で打つので、実行の bit は見ない
      ConditionPathExists = ticketSh;
      ConditionPathIsDirectory = hub;
      # 2 以外で落ち続けたら、10 分に 5 回起こしたところで諦める (上の「再起動」)。
      StartLimitIntervalSec = 600;
      StartLimitBurst = 5;
    };

    Service = {
      # 実行の bit と /usr/bin/env に頼らず、store の bash で打つ (bootstrap-herdr-hub.sh が hub-init.sh を打つのと同じ)。
      ExecStart = "${pkgs.runtimeShell} ${ticketSh} inbox";
      WorkingDirectory = hub;
      Environment = [
        # 上の「PATH」。/run/current-system/sw/bin は NixOS の system の profile
        "PATH=${
          lib.concatStringsSep ":" [
            "%h/bin"
            "%h/.local/bin"
            "${config.home.profileDirectory}/bin"
            "/nix/var/nix/profiles/default/bin"
            "/run/current-system/sw/bin"
            "/usr/local/bin"
            "/usr/bin"
            "/bin"
          ]
        }"
        # journal は pipe なので、python は標準出力を溜めてから書く。見回りのログをその場で出させる
        "PYTHONUNBUFFERED=1"
      ];
      SyslogIdentifier = "pjp-dev-tracker-inbox";
      Restart = "on-failure";
      RestartSec = 30;
      RestartPreventExitStatus = 2;
      KillMode = "mixed";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
