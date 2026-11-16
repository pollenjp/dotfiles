# hc (herdr-core) の agent skill。~/.claude/skills/hc/ (中身は SKILL.md だけ) を、入れる hc の `hc --skill` から作る。
#
# `hc --skill` は hc の CLI の手引き (Markdown。hc の版ごとに中身が変わる) を出すだけで、Claude Code が読む frontmatter が無い。
# 頭に frontmatter (name: hc と、使う場面の description) と、作った版を書いたコメントを足す。どちらも隣の claude-skill-head.md
# に書き、@version@ を hc の版に替える。Windows で同じ SKILL.md を作るとき (win/ の runner。別の PR) も、同じ head を使う。
#
# build の中で `hc --skill` を流す。hc は HOME にも core にも触らずに手引きを出す (空の env と HOME だけで、手元と同じ出力に
# なることを確かめた)。hc の版は releases.json で決まり、上げると derivation が変わるので、SKILL.md も一緒に作り直る (setup の
# bootstrap で作り直す仕組みは要らない)。名前は公式の CLI の名前どおり hc (pjp- は自作の印。herdr の skill と同じ扱い)。
# 張るのは home/modules/claude.nix (dotfiles.herdrCore.enable のホストだけ)。確かめるのは tests/claude-hc-skill.nix。
{
  runCommand,
  herdr-core,
}:

runCommand "hc-claude-skill-${herdr-core.version}"
  {
    nativeBuildInputs = [ herdr-core ];
    head = ./claude-skill-head.md;
    inherit (herdr-core) version;
    meta = {
      description = "hc (herdr-core) の agent skill (hc --skill の手引きに frontmatter を足したもの)";
      inherit (herdr-core.meta) platforms;
    };
  }
  ''
    mkdir -p "$out"
    HOME="$TMPDIR" hc --skill >manual.md
    # 手引きが出ていなければ落とす (空の SKILL.md を張らない)
    if [[ ! -s manual.md ]]; then
      echo "hc --skill が何も出さなかった (hc $version)" >&2
      exit 1
    fi
    sed "s/@version@/$version/" "$head" >"$out/SKILL.md"
    cat manual.md >>"$out/SKILL.md"
  ''
