# PR 全体の差分から変更ファイルを fzf で選び、選んだファイルだけの git diff を出す。
# 使い方と比べる範囲の決め方は pjp-pr-diff.sh の先頭のコメント。
#
# gh は runtimeInputs に入れない。この branch の PR の base を引くのに使うだけで、PATH に無い・
# ログインしていないときは origin/HEAD と比べる (home には modules/packages.nix の gh がある)。
# writeShellApplication は runtimeInputs を元の PATH の前に足すだけなので、git の pager (delta) も
# そのまま見える。
{
  writeShellApplication,
  git,
  fzf,
}:

writeShellApplication {
  name = "pjp-pr-diff";
  runtimeInputs = [
    git
    fzf
  ];
  text = builtins.readFile ./pjp-pr-diff.sh;
}
