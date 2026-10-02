# 使わなくなった Nix の store path・古い世代と、mise の使っていない版を週 1 回消す
# (dotfiles.cleanup.enable)。
#
# どちらも消す仕組みが無く、増える一方だった。2026-10-02 に WSL のマシンで手で消したとき
# (TKT-65) は、どの GC root からも辿れない store path が 70 GiB 超、mise の使っていない版が
# 7 GiB 超あった。
#
# # Nix: home-manager の nix.gc
#
# `nix-collect-garbage --delete-older-than 14d` を回す。このユーザーの profile
# (home-manager と ~/.nix-profile の両方) の 14 日より古い世代を消してから、どこからも
# 辿れない path を消す。GC そのものは daemon 経由で store 全体に効く。
#
# services.home-manager.autoExpire (`home-manager expire-generations`) は採らない。
# home-manager の世代しか消さず、~/.nix-profile の世代が古い package を握ったまま残る。
#
# root を張っていない devShell や `nix build` の結果も消えるので、次に使うときは
# 取り直し (手元でビルドするものは再ビルド) になる。
#
# # mise: mise-prune
#
# `mise prune` は、使ったことのある設定ファイル (~/.local/state/mise/tracked-configs) の
# どれもが指していない版を消す。"latest" や "24" のような指定は、入っている版のうち
# 一番新しいものを残す。mise が古い版を自分で消すのは `mise upgrade` のときだけで、
# `mise use` や自動インストールで新しい版が入っても、古い版は残り続ける。
#
# downloads/ には、インストールの後もアーカイブを残すツールがある (gcloud は 1 版で
# 200 MB 前後)。prune では消えないので、ここで消す。インストール中のものに触れない
# よう、7 日より前に更新されたものに限る。mise の always_keep_download が true の
# マシンでは、残すのが意図なので消さない。
#
# どちらも週 1 回 (systemd の weekly = 月曜 0:00) 動く。Persistent なので、マシンを
# 止めていて逃した回は次に起動したときに走る。systemd の unit は Linux で、launchd の
# agent は darwin でだけ使われる (home-manager の nix.gc と同じ書き方)。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # unit からしか呼ばないので PATH には入れない。
  # 今すぐ回すなら `systemctl --user start mise-prune.service`。
  misePrune = pkgs.writeShellApplication {
    name = "pjp-mise-prune";
    runtimeInputs = [
      config.programs.mise.package
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      mise prune --yes

      if [[ $(mise settings get always_keep_download) == true ]]; then
        exit 0
      fi
      downloads="''${MISE_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/mise}/downloads"
      if [[ -d $downloads ]]; then
        find "$downloads" -mindepth 1 -maxdepth 1 -mtime +7 -print -exec rm -rf -- {} +
      fi
    '';
  };
in
lib.mkIf config.dotfiles.cleanup.enable {
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  systemd.user.services.mise-prune = {
    Unit.Description = "mise: どの設定も指していない版と、downloads/ の古いアーカイブを消す";
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe misePrune;
    };
  };

  systemd.user.timers.mise-prune = {
    Unit.Description = "mise: 使っていない版を週 1 回消す";
    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
      Unit = "mise-prune.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  launchd.agents.mise-prune = {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe misePrune) ];
      StartCalendarInterval = lib.hm.darwin.mkCalendarInterval "weekly";
      ProcessType = "Background";
    };
  };
}
