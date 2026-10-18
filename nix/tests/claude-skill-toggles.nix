# home/options.nix の dotfiles.claude.devTracker.enable と videoOffer.enable から作られる、
# ~/.claude/CLAUDE.md の節と ~/.local/state/dotfiles/claude-skill-overrides.json を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-skill-toggles) から呼ぶ。
#
# ## 確かめること
#
#   - videoOffer.enable の既定は false で、mkHome の claude 引数で true を渡せる
#   - CLAUDE.md の「解説動画を作る」の節は videoOffer.enable のときだけ、「タスク管理」の節は
#     devTracker.enable のときだけあり、ほかの節 (「命名」など) はいつもある
#   - 両方あるときは「解説動画を作る」が「タスク管理」より前。どの組み合わせでも節の前は空行 1 つで、
#     改行が 3 つ続かず、改行 1 つで終わる (両方 true なら分割前の CLAUDE.md と同じ並び)
#   - claude-skill-overrides.json は pjp-dev-tracker と pjp-video-explainer-offer の on / off を
#     option どおりに持ち、改行で終わる。nix/scripts/bootstrap-claude-skill-overrides.sh がこれを
#     ~/.claude/settings.json の skillOverrides へ写す
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

  md = cfg: cfg.home.file.".claude/CLAUDE.md".text;
  overrides = cfg: cfg.home.file.".local/state/dotfiles/claude-skill-overrides.json".text;

  # 見出しの行があり、その前が空行
  heading = h: text: lib.hasInfix "\n\n${h}\n" text;

  byDefault = configWith { };
  both = configWith { videoOffer.enable = true; };
  videoOnly = configWith {
    devTracker.enable = false;
    videoOffer.enable = true;
  };
  neither = configWith { devTracker.enable = false; };
  all = [
    byDefault
    both
    videoOnly
    neither
  ];

  cases = [
    {
      name = "videoOffer.enable の既定は false";
      ok = !byDefault.dotfiles.claude.videoOffer.enable;
    }
    {
      name = "mkHome の claude 引数で videoOffer.enable = true を渡せる";
      ok = both.dotfiles.claude.videoOffer.enable;
    }
    {
      name = "既定 (devTracker だけ true) の CLAUDE.md は「タスク管理」だけを持つ";
      ok = heading "## タスク管理" (md byDefault) && !lib.hasInfix "## 解説動画を作る" (md byDefault);
    }
    {
      name = "両方 true の CLAUDE.md は両方を持ち、「解説動画を作る」が「タスク管理」より前";
      ok =
        heading "## 解説動画を作る" (md both)
        && heading "## タスク管理" (md both)
        && !lib.hasInfix "## タスク管理" (builtins.head (lib.splitString "## 解説動画を作る" (md both)));
    }
    {
      name = "videoOffer だけ true の CLAUDE.md は「解説動画を作る」だけを持つ";
      ok = heading "## 解説動画を作る" (md videoOnly) && !lib.hasInfix "## タスク管理" (md videoOnly);
    }
    {
      name = "両方 false の CLAUDE.md はどちらの節も持たない";
      ok = !lib.hasInfix "## 解説動画を作る" (md neither) && !lib.hasInfix "## タスク管理" (md neither);
    }
    {
      name = "どの組み合わせでも「命名」と「方針を承認したら PR まで走り切る」の節がある";
      ok = builtins.all (c: heading "## 命名" (md c) && heading "## 方針を承認したら PR まで走り切る" (md c)) all;
    }
    {
      name = "どの組み合わせでも改行が 3 つ続かず、改行 1 つで終わる";
      ok = builtins.all (
        c: !lib.hasInfix "\n\n\n" (md c) && lib.hasSuffix "\n" (md c) && !lib.hasSuffix "\n\n" (md c)
      ) all;
    }
    {
      name = "既定の skill-overrides は pjp-dev-tracker が on、pjp-video-explainer-offer が off";
      ok =
        builtins.fromJSON (overrides byDefault) == {
          "pjp-dev-tracker" = "on";
          "pjp-video-explainer-offer" = "off";
        };
    }
    {
      name = "両方 true の skill-overrides は両方 on";
      ok =
        builtins.fromJSON (overrides both) == {
          "pjp-dev-tracker" = "on";
          "pjp-video-explainer-offer" = "on";
        };
    }
    {
      name = "両方 false の skill-overrides は両方 off";
      ok =
        builtins.fromJSON (overrides neither) == {
          "pjp-dev-tracker" = "off";
          "pjp-video-explainer-offer" = "off";
        };
    }
    {
      name = "skill-overrides は改行で終わる";
      ok = lib.hasSuffix "\n" (overrides byDefault);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-skill-toggles: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-skill-toggles" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
