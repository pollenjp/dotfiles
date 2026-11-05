# WSL の eth0 の MTU を上限まで下げ続ける見張り (dotfiles.wsl.mtuGuard)。
#
# VPN のトンネルの実効 MTU が eth0 の MTU より小さく、トンネルの奥から返る ICMP が WSL (NAT) まで届かないと、
# 実効 MTU を超える大きさのパケットが黙って捨てられ続ける (PMTU ブラックホール)。WSL はホスト側のネットワークが
# 変わるたびに eth0 の MTU を設定し直すので、見張り (pkgs/pjp-wsl-mtu-guard) がリンクの変化のたびに上限まで下げる。
#
# MTU を変えるには root (CAP_NET_ADMIN) が要るので、systemd の **system** の unit で動かす。仕組みは
# exe-exec-trace.nix と同じ (ADR 012): home-manager は system の unit を置けないので、ここでは unit ファイルを
# 生成するだけにして、/etc/systemd/system へ入れるのは setup の手順 wsl-mtu-guard (sudo が要る。「既存マシン更新」の
# 最後の方に走る) に任せる。ExecStart は store の固定パスにする (root がユーザーの書き換えられるパスを実行しない)。
# 上限の値を変えると unit の中身が変わり、setup の手順が入れ替えて起こし直す。
#
# 生成する場所 (~/.local/share/dotfiles/systemd/) と unit の名前は scripts/setup.sh と揃えている。変えるなら両方。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  wsl = config.dotfiles.wsl;
  guardEnabled = wsl.enable && wsl.mtuGuard.enable;
  maxMtu = toString wsl.mtuGuard.maxMtu;

  guard = pkgs.callPackage ../../pkgs/pjp-wsl-mtu-guard { };

  # Type=exec: 見張りを exec できたところで起動したことにする。store の見張りが消えていれば systemctl restart が
  # 失敗し、setup の手順がそれで気付く。
  #
  # Restart=always: ip monitor が終わったら (エラーのときだけ終わる) 見張りも終わるので、5 秒おいて起こし直す。
  # StartLimit は付けない (見張りは諦めずに起こし直し続ける。5 秒おきなら既定の 10 秒に 5 回を超えない)。
  #
  # 保護設定は、systemd の下で ip monitor link と ip link set が通ることを WSL で確かめた範囲に留めている。
  # netlink だけで MTU を変えるので、CAP_NET_ADMIN と AF_NETLINK のほかは要らない。network namespace を分けるもの
  # (PrivateNetwork など) は使えない (WSL の eth0 が見えなくなる)。
  unitText = ''
    [Unit]
    Description=dotfiles: WSL の eth0 の MTU を ${maxMtu} 以下に保つ (PMTU ブラックホールを避ける)
    Documentation=https://github.com/pollenjp/dotfiles-private/blob/main/docs/superpowers/specs/2026-11-05-wsl-mtu-guard-design.md
    ConditionVirtualization=wsl
    RequiresMountsFor=/nix/store

    [Service]
    Type=exec
    ExecStart=${lib.getExe guard} eth0 ${maxMtu}
    Restart=always
    RestartSec=5
    SyslogIdentifier=wsl-mtu-guard
    NoNewPrivileges=yes
    CapabilityBoundingSet=CAP_NET_ADMIN
    RestrictAddressFamilies=AF_NETLINK AF_UNIX
    ProtectSystem=strict
    ProtectHome=yes
    PrivateTmp=yes
    PrivateDevices=yes
    ProtectKernelTunables=yes
    ProtectKernelModules=yes
    ProtectKernelLogs=yes
    ProtectControlGroups=yes
    ProtectClock=yes
    ProtectHostname=yes
    RestrictNamespaces=yes
    RestrictRealtime=yes
    RestrictSUIDSGID=yes
    LockPersonality=yes
    MemoryDenyWriteExecute=yes
    SystemCallArchitectures=native

    [Install]
    WantedBy=multi-user.target
  '';
in
{
  # 階層で表現しきれない「親が false なのに子が true」を評価時に止める (exe-exec-trace.nix と同じ)。
  assertions = [
    {
      assertion = wsl.mtuGuard.enable -> wsl.enable;
      message = ''
        dotfiles.wsl.mtuGuard.enable = true は dotfiles.wsl.enable = true のマシンでだけ使えます。
        WSL の eth0 の MTU を上限まで下げ続ける見張りです。
      '';
    }
  ];

  # 本文を text で置く (nix/tests/wsl-mtu-guard.nix が評価時に読む)。home-manager が store のファイルにして
  # symlink を張るので、setup の手順は exe-exec-trace の unit と同じく store の実体まで辿って入れる。
  xdg.dataFile = lib.mkIf guardEnabled {
    "dotfiles/systemd/dotfiles-wsl-mtu-guard.service".text = unitText;
  };
}
