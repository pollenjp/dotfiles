# home/options.nix の dotfiles.wsl.mtuGuard から作られるもの (home/modules/wsl-mtu-guard.nix。WSL の eth0 の MTU を
# 上限まで下げ続ける見張りの system の unit ファイル) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (wsl-mtu-guard-state)
# から呼ぶ。見張りは iproute2 (Linux だけ) を使うので、Linux の checks にだけ置く。
#
# ## 確かめること
#
#   - 既定では unit ファイルを置かない (WSL のマシンでも)。上限の既定は 1350
#   - wsl.enable = false のマシンで mtuGuard.enable = true にすると、評価で止まる
#   - true なら ~/.local/share/dotfiles/systemd/dotfiles-wsl-mtu-guard.service を置き (/etc へ入れるのは setup の手順
#     wsl-mtu-guard)、WSL でだけ動き (ConditionVirtualization=wsl)、/nix/store が使えるのを待ち、見張りを exec できたら
#     起動したことにし (Type=exec)、いつ終わっても 5 秒おいて起こし直し、multi-user.target で起きる
#   - ExecStart は store の見張り (pjp-wsl-mtu-guard) に eth0 と上限を渡す (root がユーザーの書き換えられるパスを
#     実行しない)
#   - 上限を変えると ExecStart と Description の値が変わる (unit の中身が変わるので、setup の手順が入れ替える)
#   - network namespace を分ける保護設定 (PrivateNetwork など) を使わない (分けると WSL の eth0 が見えない)
#   - 上限は 1280 (IPv6 の最小の MTU) から 1500 まで。外の値は評価で止まる
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    wsl:
    (mkHome {
      username = "tester";
      inherit system wsl;
    }).config;

  unitPath = "dotfiles/systemd/dotfiles-wsl-mtu-guard.service";
  unitText = cfg: cfg.xdg.dataFile.${unitPath}.text;
  lines = cfg: lib.splitString "\n" (unitText cfg);
  hasLine = cfg: line: lib.elem line (lines cfg);
  lineWith = cfg: prefix: lib.findFirst (lib.hasPrefix prefix) "" (lines cfg);
  # 評価で止まるか。上限の型の誤りは、unit の本文を作るとき (値を読んだとき) に throw になる
  rejects = cfg: !(builtins.tryEval (unitText cfg)).success;
  withMax =
    maxMtu:
    configWith {
      enable = true;
      mtuGuard = {
        enable = true;
        inherit maxMtu;
      };
    };

  wslOnly = configWith { enable = true; };
  enabled = configWith {
    enable = true;
    mtuGuard.enable = true;
  };
  # home-manager は assertion が落ちていると config を読んだ時点で throw する ("Failed assertions")。
  # 評価で止まれば success が false になる
  withoutWsl = builtins.tryEval (configWith { mtuGuard.enable = true; }).home.username;

  storeGuard = "/nix/store/[a-z0-9]{32}-pjp-wsl-mtu-guard/bin/pjp-wsl-mtu-guard";

  cases = [
    {
      name = "既定では WSL のマシンでも unit ファイルを置かず、上限の既定は 1350";
      ok = !(wslOnly.xdg.dataFile ? ${unitPath}) && wslOnly.dotfiles.wsl.mtuGuard.maxMtu == 1350;
    }
    {
      name = "wsl.enable = false のマシンで mtuGuard.enable = true にすると評価で止まる";
      ok = !withoutWsl.success;
    }
    {
      name = "true なら unit ファイルを置き、WSL でだけ動き、/nix/store を待ち、exec できたら起動したことにし、いつ終わっても 5 秒おいて起こし直し、multi-user.target で起きる";
      ok =
        enabled.xdg.dataFile ? ${unitPath}
        && lib.all (hasLine enabled) [
          "ConditionVirtualization=wsl"
          "RequiresMountsFor=/nix/store"
          "Type=exec"
          "Restart=always"
          "RestartSec=5"
          "WantedBy=multi-user.target"
        ];
    }
    {
      name = "ExecStart は store の見張りに eth0 と上限 1350 を渡す";
      ok = builtins.match "ExecStart=${storeGuard} eth0 1350" (lineWith enabled "ExecStart=") != null;
    }
    {
      name = "上限を 1300 にすると ExecStart と Description の値が変わる";
      ok =
        builtins.match "ExecStart=${storeGuard} eth0 1300" (lineWith (withMax 1300) "ExecStart=") != null
        && lib.hasInfix "MTU を 1300 以下に保つ" (lineWith (withMax 1300) "Description=");
    }
    {
      name = "network namespace を分ける保護設定を使わない";
      ok =
        !lib.any (l: lib.hasPrefix "PrivateNetwork=" l || lib.hasPrefix "NetworkNamespacePath=" l) (
          lines enabled
        );
    }
    {
      name = "上限は 1280 から 1500 まで (1279 と 1501 は評価で止まる)";
      ok =
        rejects (withMax 1279)
        && rejects (withMax 1501)
        && !(rejects (withMax 1280))
        && !(rejects (withMax 1500));
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "wsl-mtu-guard-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "wsl-mtu-guard-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
