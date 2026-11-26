# modules/claude.nix が ~/.claude/skills/hc に張る、hc (herdr-core) の skill を確かめる。中身は pkgs/herdr-core/claude-skill.nix が、
# home.packages の hc と同じ package の `hc --skill` に frontmatter (pkgs/herdr-core/claude-skill-head.md) を足して作る。
# flake.nix の checks (claude-hc-skill) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert。CI の `nix flake check --all-systems --no-build` でも落ちる)
#     - Linux の既定 (dotfiles.herdrCore.enable) では home.file に .claude/skills/hc があり、張る元は home.packages の
#       herdr-core と同じ版から作ったもの (名前に hc の版が入る)
#     - dotfiles.herdrCore.enable = false のホスト・macOS の既定には張らない (package が Linux だけで、無い CLI の skill になる)
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - 張る元に SKILL.md だけがある
#     - frontmatter (1 行目の --- から次の --- まで) の name が hc (Agent Skills の仕様で、name は親ディレクトリ名と一致させる) で、
#       description が空でない
#     - frontmatter の後ろに、作った hc の版を書いたコメントの行があり、@version@ が残っていない
#     - 本文が `hc --skill` の出力そのもの (同じ package の hc で流し直した出力と、frontmatter とコメントの後ろが同じ)
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
      # グループ all のホスト (Claude Code 一式が入り、herdr-core は Linux でだけ既定で入る)
      group = "all";
    }).config;

  byDefault = configWith [ ];
  disabled = configWith [ { dotfiles.herdrCore.enable = false; } ];

  file = byDefault.home.file.".claude/skills/hc" or null;
  herdrCore = lib.findFirst (p: (p.pname or "") == "herdr-core") null byDefault.home.packages;

  linuxOk =
    file != null
    && herdrCore != null
    && lib.hasSuffix "-hc-claude-skill-${herdrCore.version}" (toString file.source)
    && !(disabled.home.file ? ".claude/skills/hc");
  darwinOk = !(byDefault.home.file ? ".claude/skills/hc");
in
assert lib.assertMsg (if isLinux then linuxOk else darwinOk)
  "claude-hc-skill: ~/.claude/skills/hc の張り方が合わない (Linux の既定で張り、herdrCore.enable = false と macOS では張らない)";
if !isLinux then
  pkgs.runCommand "claude-hc-skill" { } ''
    echo "ok   macOS の既定には ~/.claude/skills/hc を張らない"
    touch $out
  ''
else
  pkgs.runCommand "claude-hc-skill"
    {
      nativeBuildInputs = [ herdrCore ];
      skill = file.source;
      inherit (herdrCore) version;
    }
    ''
      set -u
      fail() {
        echo "claude-hc-skill: $*" >&2
        exit 1
      }
      md=$skill/SKILL.md
      [[ -f $md ]] || fail "$md が無い"
      [[ $(ls -A "$skill") == SKILL.md ]] || fail "$skill に SKILL.md のほかのものがある: $(ls -A "$skill")"
      # frontmatter (1 行目の --- から次の --- まで) の name と description
      [[ $(head -n 1 "$md") == --- ]] || fail "$md の 1 行目が --- でない"
      end=$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$md")
      [[ -n $end ]] || fail "$md の frontmatter が閉じていない"
      name=$(awk -v e="$end" 'NR > 1 && NR < e && /^name:/ { sub(/^name:[ \t]*/, ""); print; exit }' "$md")
      [[ $name == hc ]] || fail "frontmatter の name が hc でない (name: $name)"
      desc=$(awk -v e="$end" 'NR > 1 && NR < e && /^description:/ { sub(/^description:[ \t]*/, ""); print; exit }' "$md")
      [[ -n $desc && $desc != '""' ]] || fail "frontmatter の description が空"
      echo "ok   frontmatter の name が hc で、description がある"
      # 作った版のコメント (frontmatter の後ろの最初の空でない行)
      comment=$(awk -v e="$end" 'NR > e && NF { print; exit }' "$md")
      [[ $comment == "<!--"*"hc $version"*"-->" ]] || fail "frontmatter の後ろに hc $version を書いたコメントが無い: $comment"
      ! grep -Fq '@version@' "$md" || fail "$md に @version@ が残っている"
      echo "ok   frontmatter の後ろに、作った hc の版 ($version) を書いたコメントがある"
      # 本文は hc --skill の出力そのもの
      HOME=$TMPDIR hc --skill >want.md
      awk -v e="$end" 'NR > e' "$md" | awk 'found || !/^<!--/ && NF { found = 1 } found' >got.md
      cmp -s want.md got.md || fail "本文が hc --skill の出力と違う: $(diff want.md got.md | head -5)"
      echo "ok   本文が hc --skill の出力そのもの ($(wc -l <want.md) 行)"
      touch $out
    ''
