# home/options.nix の dotfiles.claude.videoRender.limitPercent から作られる
# ~/.local/state/dotfiles/claude-video-limits.json を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-video-limits-state) から呼ぶ。
#
# ## 確かめること
#
#   - videoRender.limitPercent の既定は 70 で、mkHome の claude 引数で 40 を渡せる
#   - claude-video-limits.json は {"limitPercent":<option の値>} と改行だけ。claude-skills の動画の雛形の tools/limit.sh が
#     これを読み、キーが違う・読めないときは 70 で縛るので、キーの名前と形をここで固定する
#   - 1〜100 の外 (0・101・-1) と整数でない値 (40.5・"40") は、型の誤りとして評価で止まる
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

  state = cfg: cfg.home.file.".local/state/dotfiles/claude-video-limits.json".text;

  # その値を書くと、JSON を作るところで評価が止まる (型の誤りの throw を tryEval で拾う)
  rejects =
    v:
    let
      cfg = configWith { videoRender.limitPercent = v; };
    in
    !(builtins.tryEval (builtins.deepSeq (state cfg) true)).success;

  byDefault = configWith { };
  forty = configWith { videoRender.limitPercent = 40; };

  cases = [
    {
      name = "videoRender.limitPercent の既定は 70";
      ok = byDefault.dotfiles.claude.videoRender.limitPercent == 70;
    }
    {
      name = "mkHome の claude 引数で videoRender.limitPercent = 40 を渡せる";
      ok = forty.dotfiles.claude.videoRender.limitPercent == 40;
    }
    {
      name = "既定の claude-video-limits.json は {\"limitPercent\":70} と改行だけ";
      ok = state byDefault == "{\"limitPercent\":70}\n";
    }
    {
      name = "limitPercent = 40 の claude-video-limits.json は limitPercent が 40";
      ok = builtins.fromJSON (state forty) == { limitPercent = 40; };
    }
    {
      name = "claude-video-limits.json は改行で終わる";
      ok = lib.hasSuffix "\n" (state forty);
    }
    {
      name = "1〜100 の外 (0・101・-1) は評価で止まる";
      ok = rejects 0 && rejects 101 && rejects (-1);
    }
    {
      name = "整数でない値 (40.5・\"40\") は評価で止まる";
      ok = rejects 40.5 && rejects "40";
    }
    {
      name = "端の値 (1・100) は通る";
      ok = !(rejects 1) && !(rejects 100);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-video-limits-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-video-limits-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
