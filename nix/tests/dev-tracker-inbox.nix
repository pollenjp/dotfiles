# home/options.nix の dotfiles.claude.devTracker.inbox.enable から作られるもの (home/modules/dev-tracker-inbox.nix。
# Dev Tracker のコメントの見回り役の systemd の user service) を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (dev-tracker-inbox-state)
# から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - 既定 (false) では pjp-dev-tracker-inbox の service を置かない (Dev Tracker を使うマシンでも)
#     - devTracker.enable = false のマシンで inbox.enable = true にすると、評価で止まる
#     - true なら service を置き、default.target で起きる
#     - ExecStart は store の bash で ~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh inbox を打つ (実行の bit に頼らない)
#     - ticket.sh とハブ (~/h) が無ければ条件不成立で飛ばす (ConditionPathExists・ConditionPathIsDirectory)。cwd はハブ
#     - 落ちたら 30 秒おいて起こし直すが、終了コード 2 (設定の誤り・inbox の無い古い ticket.sh) では起こし直さない。
#       10 分に 5 回起こしたら諦める。止めるときの SIGTERM は本体にだけ送る (KillMode=mixed)
#     - PATH に ~/bin (ntn)・home-manager の profile (herdr・git)・nix の profile (devShell へ入り直す nix)・/usr/bin を
#       この順で渡し、PYTHONUNBUFFERED=1 で python のログを溜めずに journal へ出させる
#   ビルド時 (Linux だけ。unit ファイルは Linux でしか作られない)
#     - unit ファイルの [Unit]・[Service] に上の値が出る (%h が %% に化けない・Environment が 1 行ずつになる)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    claude:
    (mkHome {
      username = "tester";
      inherit system claude;
    }).config;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  name = "pjp-dev-tracker-inbox";
  ticketSh = "%h/.claude/skills/pjp-dev-tracker/scripts/ticket.sh";

  # 宛先 (notion.profile) も選ぶ。選ばないと claude.nix の warnings が評価のたびに出る
  devTrackerOnly = configWith {
    devTracker.enable = true;
    notion.profile = "personal";
  };
  enabled = configWith {
    devTracker = {
      enable = true;
      inbox.enable = true;
    };
    notion.profile = "personal";
  };
  # home-manager は assertion が落ちていると config を読んだ時点で throw する ("Failed assertions")。
  # 評価で止まれば success が false になる
  withoutDevTracker = builtins.tryEval (configWith { devTracker.inbox.enable = true; }).home.username;

  unit = enabled.systemd.user.services.${name} or null;
  # home-manager は ExecStart などを list にまとめるので、どちらの形でも 1 つの値として比べる
  one = v: lib.toList v;
  envOf = u: one (u.Service.Environment or [ ]);
  path = lib.concatStringsSep ":" [
    "%h/bin"
    "%h/.local/bin"
    "${enabled.home.profileDirectory}/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
  execStart = "${pkgs.runtimeShell} ${ticketSh} inbox";
  unitFile = "${enabled.xdg.configFile."systemd/user/${name}.service".source}";

  cases = [
    {
      name = "既定では Dev Tracker を使うマシンでも service を置かない";
      ok = !(devTrackerOnly.systemd.user.services ? ${name});
    }
    {
      name = "devTracker.enable = false のマシンで inbox.enable = true にすると評価で止まる";
      ok = !withoutDevTracker.success;
    }
    {
      name = "true なら service を置き、default.target で起きる";
      ok = unit != null && unit.Install.WantedBy == [ "default.target" ];
    }
    {
      name = "ExecStart は store の bash で ticket.sh inbox を打つ";
      ok = unit != null && one unit.Service.ExecStart == [ execStart ];
    }
    {
      name = "ticket.sh とハブ (~/h) が無ければ条件不成立で飛ばし、cwd はハブ";
      ok =
        unit != null
        && one unit.Unit.ConditionPathExists == [ ticketSh ]
        && one unit.Unit.ConditionPathIsDirectory == [ "%h/h" ]
        && unit.Service.WorkingDirectory == "%h/h";
    }
    {
      name = "落ちたら 30 秒おいて起こし直すが、終了コード 2 では起こし直さず、10 分に 5 回で諦める";
      ok =
        unit != null
        && unit.Service.Restart == "on-failure"
        && unit.Service.RestartSec == 30
        && unit.Service.RestartPreventExitStatus == 2
        && unit.Unit.StartLimitIntervalSec == 600
        && unit.Unit.StartLimitBurst == 5;
    }
    {
      name = "止めるときの SIGTERM は本体にだけ送る (KillMode=mixed)";
      ok = unit != null && unit.Service.KillMode == "mixed";
    }
    {
      name = "PATH に ~/bin・home-manager の profile・nix の profile・/usr/bin を渡し、python のログを溜めさせない";
      ok =
        unit != null
        &&
          envOf unit == [
            "PATH=${path}"
            "PYTHONUNBUFFERED=1"
          ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "dev-tracker-inbox-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "dev-tracker-inbox-state" { } (
  ''
    echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ''
  + lib.optionalString isLinux ''
    unit=${unitFile}
    for line in \
      ${lib.escapeShellArg "ConditionPathExists=${ticketSh}"} \
      'ConditionPathIsDirectory=%h/h' \
      ${lib.escapeShellArg "ExecStart=${execStart}"} \
      ${lib.escapeShellArg "Environment=PATH=${path}"} \
      'Environment=PYTHONUNBUFFERED=1' \
      'RestartPreventExitStatus=2' \
      'KillMode=mixed' \
      'WantedBy=default.target'; do
      if ! grep -qxF -- "$line" "$unit"; then
        echo "dev-tracker-inbox-state: unit ファイルに次の行が無い: $line" >&2
        cat "$unit" >&2
        exit 1
      fi
    done
    echo "ok   unit ファイルの [Unit]・[Service]・[Install] に値が出る (%h のまま・Environment は 1 行ずつ)"
  ''
  + ''
    touch $out
  ''
)
