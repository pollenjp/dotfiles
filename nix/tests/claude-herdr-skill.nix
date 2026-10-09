# modules/claude.nix が ~/.claude/skills/herdr に張る、herdr パッケージ同梱の skill を確かめる。
#
#   評価時 (assert。CI の `nix flake check --all-systems --no-build` でも落ちる)
#     - home.file に .claude/skills/herdr がある
#     - 張る元が home.packages の herdr の中にある (skill と CLI の版が揃う)
#   ビルド時 (このランナーの system だけ)
#     - 張る元に SKILL.md がある
#     - SKILL.md の name が herdr (Agent Skills の仕様で、name は親ディレクトリ名と一致させる)
#
# home-manager は張る元が無くても切れた symlink を黙って作るので、nixpkgs の herdr が
# skill の置き場所を変えたら、flake.lock を上げた PR の CI でここが落ちるようにしておく。
# flake.nix の checks (claude-herdr-skill) から呼ぶ。
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  cfg =
    (mkHome {
      username = "tester";
      inherit system;
    }).config;

  file = cfg.home.file.".claude/skills/herdr" or null;
  source = "${file.source}";
  herdr = lib.findFirst (p: lib.getName p == "herdr") null cfg.home.packages;
in
assert lib.assertMsg (file != null) "claude-herdr-skill: home.file に .claude/skills/herdr が無い";
assert lib.assertMsg (herdr != null) "claude-herdr-skill: home.packages に herdr が無い";
assert lib.assertMsg (lib.hasPrefix "${herdr}/" source)
  "claude-herdr-skill: 張る元が home.packages の herdr の中に無い (${source})";
pkgs.runCommand "claude-herdr-skill" { } ''
  skill=${source}
  if [[ ! -f $skill/SKILL.md ]]; then
    echo "claude-herdr-skill: $skill/SKILL.md が無い (nixpkgs の herdr が skill の置き場所を変えた?)" >&2
    exit 1
  fi
  # frontmatter (1 行目の --- から次の --- まで) の name の値
  name=$(awk 'NR == 1 { if ($0 != "---") exit; next } /^---$/ { exit } /^name:/ { sub(/^name:[ \t]*/, ""); print; exit }' "$skill/SKILL.md")
  if [[ $name != herdr ]]; then
    echo "claude-herdr-skill: $skill/SKILL.md の name が herdr ではない (name: $name)" >&2
    exit 1
  fi
  echo "ok   $skill/SKILL.md (name: $name)"
  touch $out
''
