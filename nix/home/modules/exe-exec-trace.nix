# WSL から起動された Windows の .exe を常時記録するトレーサ (pjp-exe-exec-trace) と、
# 1Password の承認ダイアログが出ている間に要求元をたどる pjp-who-is-asking (ADR 012)。
#
# # 1. pjp-who-is-asking
#
# dotfiles.wsl.enable のマシンの PATH に置く。root は要らないので option は設けない。
#
# # 2. pjp-exe-exec-trace (dotfiles.wsl.exeExecTrace.enable)
#
# eBPF には root が要るので、systemd の **system** の unit で動かす。home-manager は
# system の unit を置けないので、ここでは unit ファイルを生成するだけにして、
# /etc/systemd/system へ入れるのは setup の手順 exe-exec-trace (sudo が要る) に任せる。
#
# ExecStart は store の固定パスにする。~/.nix-profile/bin を指すと、root がユーザーの
# 書き換えられるパスを実行することになり、同じユーザーの他のプロセスがトレーサを
# 差し替えられる (記録したい相手に記録を止められる)。その代わり、トレーサを更新したら
# 手順を打ち直す (ずれていれば setup の最後に知らせる)。
#
# 生成する場所 (~/.local/share/dotfiles/systemd/) と unit の名前は scripts/setup.sh と
# 揃えている。変えるなら両方。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  wsl = config.dotfiles.wsl;
  traceEnabled = wsl.enable && wsl.exeExecTrace.enable;

  exeExecTrace = pkgs.callPackage ../../pkgs/pjp-exe-exec-trace { };
  whoIsAsking = pkgs.callPackage ../../pkgs/pjp-who-is-asking { };

  # ExecStart は lib.getExe (writeShellApplication の name = meta.mainProgram) で引く。
  # bin の名前を直書きすると、コマンド名を変えたときに無いパスを指したまま build が通ってしまう。
  #
  # Type=notify: トレーサは BPF を読み込み終えてから READY=1 を送る。systemctl restart は
  # それまで待ち、読み込みに失敗すれば restart 自体が失敗する (setup の手順がそれで気付く)。
  #
  # StartLimit*: 起動に失敗し続けたら (WSL のカーネルの更新で BPF が読み込めなくなったとき
  # など) 諦めて failed にする。既定 (10 秒に 5 回) は RestartSec=10 では決して超えないので、
  # 付けないと clang のコンパイルを 10 秒おきに無限に繰り返す。
  #
  # 保護設定は、systemd の下で bcc が動くことを確かめた範囲に留めている (ADR 012 の検証)。
  #
  #   PrivateTmp          bcc はカーネルヘッダ (kheaders) を /tmp/kheaders-<release> へ展開する。
  #                       root が共有の /tmp の決まった名前へ書くのを避ける (起動のたびに展開し直す)
  #   ProtectHome         トレーサが /proc/<pid>/cwd で読むのはリンクの文字列だけで、中身は読まない
  #   ProtectKernelModules は付けない。kheaders を modprobe で読み込むため
  unit = pkgs.writeText "dotfiles-exe-exec-trace.service" ''
    [Unit]
    Description=dotfiles: WSL から起動された Windows の .exe を祖先付きで記録する (eBPF)
    Documentation=https://github.com/pollenjp/dotfiles/blob/main/docs/adr/012_wsl_exe_exec_trace_service_20260930T153253JST/README.md
    ConditionVirtualization=wsl
    RequiresMountsFor=/nix/store
    StartLimitIntervalSec=10min
    StartLimitBurst=5

    [Service]
    Type=notify
    ExecStart=${lib.getExe exeExecTrace} --json
    Restart=on-failure
    RestartSec=10
    SyslogIdentifier=exe-exec-trace
    NoNewPrivileges=yes
    PrivateTmp=yes
    ProtectHome=read-only
    ProtectSystem=full

    [Install]
    WantedBy=multi-user.target
  '';
in
{
  # 階層で表現しきれない「親が false なのに子が true」を評価時に止める (git.nix と同じ)。
  assertions = [
    {
      assertion = wsl.exeExecTrace.enable -> wsl.enable;
      message = ''
        dotfiles.wsl.exeExecTrace.enable = true は dotfiles.wsl.enable = true のマシンでだけ使えます。
        WSL から起動された Windows の .exe を記録する道具です (ADR 012)。
      '';
    }
  ];

  home.packages = lib.optional wsl.enable whoIsAsking ++ lib.optional traceEnabled exeExecTrace;

  xdg.dataFile = lib.mkIf traceEnabled {
    "dotfiles/systemd/dotfiles-exe-exec-trace.service".source = unit;
  };
}
