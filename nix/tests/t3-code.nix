# home/options.nix の dotfiles.t3Code.enable・clearClaudeEntrypoint と、それが置くもの (home/modules/t3-code.nix・pkgs/t3-code・
# home/modules/claude.nix の既定のアカウント) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (t3-code-state) から呼ぶ。package の build (配布物を落として runtime の形を見る) は checks の t3-code-test (Linux だけ)。
#
# ## 確かめること
#
#   - enable と clearClaudeEntrypoint の既定は false (どのグループでも。personal でも入らない)。off なら launcher・unit・状態ファイル・
#     activation を置かず、claude の既定のアカウントに t3 が無い
#   - Linux で on なら:
#     - unit (~/.config/systemd/user/t3code.service) は t3 0.1.11 が書く unit と同じ文字列 (example-host で `t3 up` が書いたものを tester の home に
#       置き換えたもの)。default.target.wants にも同じものを置く。どちらも force
#     - ~/.local/bin/t3 は t3 の launcher と同じ中身で、実行でき、force
#     - 状態ファイル ~/.local/state/dotfiles/t3-code.json は、版・runtime・clearClaudeEntrypoint と、nix/files/t3-code/managed-settings.json の値
#     - runtime を写す activation (writeBoundary の後) と、前に t3 が書いたふつうのファイルを消す activation (writeBoundary の後・
#       linkGeneration の前) がある
#     - claude の既定のアカウント (claude-accounts.json) に t3 が足される
#     - package は、この system の公式の版つき URL を、固定した sha256 で落とす
#   - claude.enable = false なら、t3Code.enable = true でも何も置かない (requires)
#   - macOS では、enable = true にすると assertion で評価が止まる (module の assertion は Linux でだけ通る)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

  configWith =
    modules:
    (mkHome {
      username = "tester";
      inherit system modules;
    }).config;

  file = cfg: name: cfg.home.file.${name} or null;
  xdg = cfg: name: cfg.xdg.configFile.${name} or null;
  accounts = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/claude-accounts.json".text;

  byDefault = configWith [ ];
  enabled = configWith [
    {
      dotfiles.t3Code = {
        enable = true;
        clearClaudeEntrypoint = true;
      };
    }
  ];
  noClaude = configWith [
    {
      # 段 ② を切って claude.enable を既定で false にする (claude だけを false にすると、② と ③ の両方の skill の置き場が止める)
      dotfiles.aiTools.enable = false;
      dotfiles.t3Code.enable = true;
    }
  ];

  managed = lib.importJSON ../files/t3-code/managed-settings.json;
  pkg = pkgs.callPackage ../pkgs/t3-code { };

  # example-host で t3 0.1.11 の `t3 up` が書いた ~/.config/systemd/user/t3code.service の home を /home/tester に置き換えたもの
  wantUnit = ''
    [Unit]
    Description=T3 Code server
    StartLimitIntervalSec=300
    StartLimitBurst=5

    [Service]
    Type=simple
    WorkingDirectory=%h
    Environment=T3CODE_HOME=/home/tester/.t3
    Environment=T3_BOOT_SERVICE_UNIT=t3code.service
    ExecStart=/home/tester/.t3/runtime/versions/0.1.11/t3 __service-launcher
    KillMode=mixed
    OOMPolicy=continue
    Restart=always
    RestartSec=5
    CPUWeight=1000
    IOWeight=1000
    MemoryLow=1536M
    OOMScoreAdjust=100
    ManagedOOMPreference=avoid
    StandardOutput=append:/home/tester/.t3/userdata/logs/boot-service.log
    StandardError=append:/home/tester/.t3/userdata/logs/boot-service.log

    [Install]
    WantedBy=default.target
  '';

  commonCases = [
    {
      name = "enable と clearClaudeEntrypoint の既定は false";
      ok = !byDefault.dotfiles.t3Code.enable && !byDefault.dotfiles.t3Code.clearClaudeEntrypoint;
    }
    {
      name = "off なら launcher・unit・状態ファイル・activation を置かず、claude の既定のアカウントに t3 が無い";
      ok =
        file byDefault ".local/bin/t3" == null
        && xdg byDefault "systemd/user/t3code.service" == null
        && file byDefault ".local/state/dotfiles/t3-code.json" == null
        && !(byDefault.home.activation ? t3CodeRuntime)
        && !(byDefault.home.activation ? t3CodeLinks)
        && !(builtins.elem "t3" (accounts byDefault));
    }
    {
      name = "claude.enable = false なら、t3Code.enable = true でも何も置かない";
      ok =
        file noClaude ".local/bin/t3" == null
        && xdg noClaude "systemd/user/t3code.service" == null
        && !(noClaude.home.activation ? t3CodeRuntime);
    }
  ];

  linuxCases =
    let
      unit = xdg enabled "systemd/user/t3code.service";
      wants = xdg enabled "systemd/user/default.target.wants/t3code.service";
      launcher = file enabled ".local/bin/t3";
      state = builtins.fromJSON (file enabled ".local/state/dotfiles/t3-code.json").text;
      runtime = enabled.home.activation.t3CodeRuntime;
      links = enabled.home.activation.t3CodeLinks;
      arch = if system == "aarch64-linux" then "arm64" else "x64";
    in
    [
      {
        name = "unit は t3 0.1.11 が書く unit と同じ文字列で、default.target.wants にも同じものを置き、どちらも force";
        ok = unit.text == wantUnit && wants.text == wantUnit && unit.force && wants.force;
      }
      {
        name = "~/.local/bin/t3 は t3 の launcher と同じ中身で、実行でき、force";
        ok =
          launcher.text == "#!/bin/sh\nexec '/home/tester/.t3/runtime/versions/0.1.11/t3' \"$@\"\n"
          && launcher.executable
          && launcher.force;
      }
      {
        name = "状態ファイルは版・runtime・clearClaudeEntrypoint と managed-settings.json の値";
        ok =
          state == {
            version = "0.1.11";
            runtime = "/home/tester/.t3/runtime/versions/0.1.11";
            clearClaudeEntrypoint = true;
            inherit managed;
          };
      }
      {
        name = "runtime を写す activation (writeBoundary の後。.install-complete が版と違うときだけ、一時の名前から mv) がある";
        ok =
          runtime.after == [ "writeBoundary" ]
          && lib.hasInfix "/share/t3-code/runtime" runtime.data
          && lib.hasInfix ".install-complete" runtime.data
          && lib.hasInfix ''run mv -T "$t3_tmp" "$t3_dir"'' runtime.data;
      }
      {
        name = "前に t3 が書いたふつうのファイルを消す activation がある (writeBoundary の後・linkGeneration の前)";
        ok =
          links.after == [ "writeBoundary" ]
          && links.before == [ "linkGeneration" ]
          && lib.hasInfix ''run rm -f "$f"'' links.data
          && lib.hasInfix ''run rm -f "$wants"'' links.data;
      }
      {
        name = "claude の既定のアカウントに t3 が足される";
        ok =
          accounts enabled == [
            "personal"
            "work"
            "t3"
          ];
      }
      {
        name = "package は、この system の公式の版つき URL を、固定した sha256 で落とす";
        ok =
          pkg.src.urls == [
            "https://github.com/pingdotgg/t3code/releases/download/v0.1.11/t3-0.1.11-linux-${arch}.tar.gz"
          ]
          && builtins.match "[0-9a-f]{64}" pkg.src.outputHash != null;
      }
    ];

  darwinCases = [
    {
      name = "macOS では enable = true にすると assertion で評価が止まる";
      ok = !(builtins.tryEval (builtins.seq enabled.home.activationPackage.drvPath true)).success;
    }
  ];

  cases = commonCases ++ (if isLinux then linuxCases else darwinCases);
  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "t3-code-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "t3-code-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
