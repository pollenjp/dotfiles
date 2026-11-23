# T3 Code の CLI (t3) と、そのサーバーを常駐させる systemd の user service (t3code.service) を入れる (dotfiles.t3Code.enable。
# claude.enable も true のときだけ。dotfiles-private の docs/adr/091_t3_code_opt_in_*)。
#
# 置くもの (どれも t3 0.1.11 の公式の installer・`t3 up` が置くものと同じ場所・同じ中身):
#
#   ~/.t3/runtime/versions/<版>/          pkgs/t3-code の runtime の写しと .install-complete (中身は版と改行)。activation が、.install-complete
#                                          が版と違うときだけ写す (store を直に指す link にしない。pkgs/t3-code の冒頭)
#   ~/.local/bin/t3                        t3 の launcher (`#!/bin/sh` と `exec '<runtime>/t3' "$@"`。t3 の posixLauncherScript)
#   ~/.config/systemd/user/t3code.service  t3 の renderBootServiceUnit が書くのと同じ文字列。t3 は unit の中身を自分の書くものと文字で比べ、
#                                          runtime の .install-complete・runtime/service-state.json の activeVersion と合えば「current」と
#                                          読んで書き換えない (`t3 up`・`t3 connect` も)。home-manager の systemd.user.services で書くと
#                                          書式が変わり、t3 が書き換える
#   ~/.config/systemd/user/default.target.wants/t3code.service  `systemctl --user enable` の代わり
#
# unit と wants の link は、名前が t3code.service の store のファイル (unitFile) を指させる。xdg.configFile の text だけで置くと、
# home-manager は /nix/store/<hash>-hm_systemdusert3code.service に書き、systemd は link をたどった先のファイル名が unit の名前と
# 違うので別の unit の別名と見て、is-enabled に alias を返す (起動では default.target.wants から起きる)。t3 は is-enabled が enabled で
# ないと「service-disabled」(t3 service status の needs an update or repair) と読むので、名前をそろえて enabled にする。
#   ~/.local/state/dotfiles/t3-code.json   setup の手順 bootstrap-t3-code.sh が読む値 (settings.json に合わせる値・ENTRYPOINT・版・runtime)
#
# launcher・unit・wants は force で置き、前に t3 が書いたふつうのファイル (と、wants の home-manager のものでない link) は、link を張る前に
# 消す (中身が同じだと home-manager は置き換えない)。t3 が後から書き換えても (`t3 update`・`t3 service install` で中身が変わったとき)、
# 次の switch で dotfiles のものに戻る。
#
# switch で service が起き直る (home-manager の reloadSystemd の sd-switch が Stopping・Starting units: t3code.service と出す) のは、
# 前の世代の home-manager の unit と中身が変わったときと、unit が世代に初めて入るとき (前の世代に無い unit は、中身が前に t3 の書いた
# ものと同じでも、新しい unit として起こし直す)。link の先が変わっても中身が同じなら起き直らない (sd-switch は中身で比べる)。起き直ると
# 動いている T3 のスレッドは止まるので、そうなる switch はスレッドが動いていない時に当てる。
#
# settings.json (~/.t3/userdata/settings.json) は t3 も書くので、ここでは置かず、bootstrap-t3-code.sh が決めたキーだけを合わせる (値は
# nix/files/t3-code/managed-settings.json。Windows の runner の t3-code-settings と同じ 1 か所)。claude のアカウント t3 は home/modules/claude.nix が
# 既定のアカウントに足す。~/.t3/userdata・service-state.json・service.env (`t3 up` の選んだ経路) には触らない。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.t3Code;
  on = cfg.enable && config.dotfiles.claude.enable;
  t3Code = pkgs.callPackage ../../pkgs/t3-code { };
  inherit (t3Code) version;
  home = config.home.homeDirectory;
  baseDir = "${home}/.t3";
  runtimeDir = "${baseDir}/runtime/versions/${version}";
  entry = "${runtimeDir}/t3";
  logPath = "${baseDir}/userdata/logs/boot-service.log";

  # t3 の quoteSystemdValue は空白・引用符・\ を含む値を引用符で囲み、% を %% にする。そうなる home では t3 と同じ文字列を作らないので止める
  # (t3 自身も、systemd に書けない値の base dir は断る)
  plainPath = p: builtins.match ".*[[:space:]\"'\\\\%].*" p == null;

  # t3 0.1.11 の renderBootServiceUnit (src/cloud/bootService.ts) と同じ文字列。T3CODE_INSTALL_BIN_DIR の行は、t3 が env で渡されたときだけ書く
  # (渡さない)。版を上げて t3 の書く unit が変わったら、ここも合わせる (tests/t3-code.nix が 0.1.11 の文字列と照らす)
  unit = lib.concatStringsSep "\n" [
    "[Unit]"
    "Description=T3 Code server"
    "StartLimitIntervalSec=300"
    "StartLimitBurst=5"
    ""
    "[Service]"
    "Type=simple"
    "WorkingDirectory=%h"
    "Environment=T3CODE_HOME=${baseDir}"
    "Environment=T3_BOOT_SERVICE_UNIT=t3code.service"
    "ExecStart=${entry} __service-launcher"
    "KillMode=mixed"
    "OOMPolicy=continue"
    "Restart=always"
    "RestartSec=5"
    "CPUWeight=1000"
    "IOWeight=1000"
    "MemoryLow=1536M"
    "OOMScoreAdjust=100"
    "ManagedOOMPreference=avoid"
    "StandardOutput=append:${logPath}"
    "StandardError=append:${logPath}"
    ""
    "[Install]"
    "WantedBy=default.target"
    ""
  ];
  # t3 0.1.11 の posixLauncherScript と同じ中身
  launcher = "#!/bin/sh\nexec '${entry}' \"$@\"\n";
  # 名前が t3code.service の store のファイル (冒頭のコメント。systemd に alias と読ませない)
  unitFile = "${pkgs.writeTextDir "t3code.service" unit}/t3code.service";

  managed = lib.importJSON ../../files/t3-code/managed-settings.json;
in
{
  config = lib.mkIf on {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "dotfiles.t3Code.enable は Linux のホストだけ (t3 の公式の Linux 版を入れ、systemd の user service で常駐させる)";
      }
      {
        assertion = plainPath home;
        message = "dotfiles.t3Code.enable: home (${home}) に空白・引用符・\\・% があると、t3 の書く unit と同じ文字列を作れない";
      }
    ];

    home.file.".local/bin/t3" = {
      text = launcher;
      executable = true;
      force = true;
    };

    # text は中身の印 (tests/t3-code.nix が照らす)。置くのは source の unitFile (text から作る既定の source は mkDefault なので、こちらが勝つ)
    xdg.configFile."systemd/user/t3code.service" = {
      text = unit;
      source = unitFile;
      force = true;
    };
    xdg.configFile."systemd/user/default.target.wants/t3code.service" = {
      text = unit;
      source = unitFile;
      force = true;
    };

    home.file.".local/state/dotfiles/t3-code.json".text =
      builtins.toJSON {
        inherit version;
        runtime = runtimeDir;
        inherit (cfg) clearClaudeEntrypoint;
        inherit managed;
      }
      + "\n";

    # 前に t3 が書いたふつうのファイルと、home-manager のものでない wants の link を、link を張る前に消す (上の冒頭のコメント)
    home.activation.t3CodeLinks = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
      for f in "$HOME/.local/bin/t3" "''${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/t3code.service"; do
        if [[ -e $f && ! -L $f ]]; then
          verboseEcho "t3-code: 前に t3 が書いた $f を消す (dotfiles のものへの link にする)"
          run rm -f "$f"
        fi
      done
      wants="''${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/default.target.wants/t3code.service"
      if [[ -L $wants && $(readlink "$wants") != /nix/store/* ]]; then
        verboseEcho "t3-code: systemctl --user enable が張った $wants を外す (dotfiles のものへの link にする)"
        run rm -f "$wants"
      fi
    '';

    # runtime を ~/.t3/runtime/versions/<版>/ へ写す (.install-complete が版と同じなら何もしない)。途中で止まった写し (.install-complete の
    # 無い dir) は消さずによける。写しは同じ dir の一時の名前に作ってから mv する (t3 が途中の dir を runtime と読まないよう)
    home.activation.t3CodeRuntime = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      t3_dir=${lib.escapeShellArg runtimeDir}
      t3_versions=$(dirname "$t3_dir")
      if [[ $(cat "$t3_dir/.install-complete" 2>/dev/null) != ${lib.escapeShellArg version} ]]; then
        run mkdir -p "$t3_versions"
        if [[ -e $t3_dir || -L $t3_dir ]]; then
          t3_aside="$t3_versions/.dotfiles-incomplete-${version}-$(date +%Y%m%dT%H%M%S)"
          echo "t3-code: $t3_dir に .install-complete が無い (途中で止まった写し?) ので、$t3_aside へよけてから写し直す"
          run mv -T "$t3_dir" "$t3_aside"
        fi
        t3_tmp="$t3_versions/.dotfiles-${version}-$$"
        run rm -rf "$t3_tmp"
        run cp -R ${t3Code}/${t3Code.runtimeSubdir} "$t3_tmp"
        run chmod -R u+w "$t3_tmp"
        if [[ -v DRY_RUN ]]; then
          echo "t3-code: (dry-run) $t3_tmp/.install-complete に ${version} を書く"
        else
          printf '%s\n' ${lib.escapeShellArg version} >"$t3_tmp/.install-complete"
        fi
        run mv -T "$t3_tmp" "$t3_dir"
        echo "t3-code: T3 Code ${version} の runtime を $t3_dir に置いた (service が前の版で動いていれば、t3 service install で揃える)"
      fi
    '';
  };
}
