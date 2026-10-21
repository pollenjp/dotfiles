# home/options.nix の dotfiles.claude.videoOffer.autoStart.enable から作られる
# ~/.local/state/dotfiles/claude-video-offer.json と、~/.claude/CLAUDE.md の解説動画の節を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-video-offer-state) から呼ぶ。
#
# ## 確かめること
#
#   - videoOffer.autoStart.enable の既定は false で、mkHome の claude 引数で true を渡せる
#   - claude-video-offer.json は {"autoStart": <option の値>} で、改行で終わる。hook (video-offer-nudge.sh) と
#     claude-skills の pjp-video-explainer-offer がこれを読み、true のときだけ答えを待たずに作り始める
#   - CLAUDE.md の「解説動画を作るか聞く」の節は option によらず同じで、いつもある (作るかを聞く文を持つ)
#   - claude-skill-overrides.json は pjp-dev-tracker だけを持ち、解説動画の skill を隠さない。値は既定 (devTracker.enable が
#     false) で "off"、true で "on"。「タスク管理」の節は devTracker.enable = true のときだけ
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
  state = cfg: cfg.home.file.".local/state/dotfiles/claude-video-offer.json".text;
  overrides = cfg: cfg.home.file.".local/state/dotfiles/claude-skill-overrides.json".text;

  # 見出しの行があり、その前が空行
  heading = h: text: lib.hasInfix "\n\n${h}\n" text;

  byDefault = configWith { };
  auto = configWith { videoOffer.autoStart.enable = true; };
  tracker = configWith { devTracker.enable = true; };
  noTracker = configWith { devTracker.enable = false; };

  cases = [
    {
      name = "videoOffer.autoStart.enable の既定は false";
      ok = !byDefault.dotfiles.claude.videoOffer.autoStart.enable;
    }
    {
      name = "mkHome の claude 引数で videoOffer.autoStart.enable = true を渡せる";
      ok = auto.dotfiles.claude.videoOffer.autoStart.enable;
    }
    {
      name = "既定の claude-video-offer.json は autoStart が false";
      ok = builtins.fromJSON (state byDefault) == { autoStart = false; };
    }
    {
      name = "autoStart.enable = true の claude-video-offer.json は autoStart が true";
      ok = builtins.fromJSON (state auto) == { autoStart = true; };
    }
    {
      name = "claude-video-offer.json は改行で終わる";
      ok = lib.hasSuffix "\n" (state byDefault);
    }
    {
      name = "CLAUDE.md は autoStart.enable によらず同じ";
      ok = md byDefault == md auto;
    }
    {
      name = "どの組み合わせでも CLAUDE.md に「解説動画を作るか聞く」の節があり、作るかを聞く文を持つ";
      ok = builtins.all (c: heading "## 解説動画を作るか聞く" (md c) && lib.hasInfix "解説動画を作るかを聞く" (md c)) [
        byDefault
        auto
        tracker
        noTracker
      ];
    }
    {
      name = "claude-skill-overrides.json は pjp-dev-tracker だけで、解説動画の skill を隠さない (既定は off、true で on)";
      ok =
        builtins.fromJSON (overrides byDefault) == {
          "pjp-dev-tracker" = "off";
        }
        && builtins.fromJSON (overrides tracker) == { "pjp-dev-tracker" = "on"; };
    }
    {
      name = "「タスク管理」の節は devTracker.enable = true のときだけ (既定には無い)";
      ok =
        heading "## タスク管理" (md tracker)
        && !lib.hasInfix "## タスク管理" (md byDefault)
        && !lib.hasInfix "## タスク管理" (md noTracker);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-video-offer-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-video-offer-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
