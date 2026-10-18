# GitHub との通信だけを gh の資格情報 (HTTPS) に向けて git を呼ぶ。git gh <コマンド> で呼ぶ
# (git は git-<名前> を PATH から探す)。git-gh <コマンド> と直に呼んでも同じ。
#
# 中身は、Claude のセッションの env と同じ組 (lib/git-via-gh.nix) を -c で付けて git を呼ぶだけ。
# GitHub の ssh の URL を https に読み替え、資格情報を gh から取る。効くのはそのコマンドの間だけで、
# origin の URL も git の設定ファイルも書き換えない。GitHub 以外の remote と ssh のホスト別名は
# 今までどおり ssh を通る。
#
# fish の abbr と bash の alias の fetch 系 (gf・gfp・gpul・gpull・gcl と、fetch / pull を含む関数) は、
# dotfiles.claude.gitViaGh.enable のマシンでこれを使う (home/modules/fish.nix・bash.nix)。gfp-gh は
# option によらずこれを使う。
#
# gh が無い・github.com にログインしていないときは、git を呼ばずに止まる。そのまま git を呼ぶと、
# 資格情報が取れずに Username の入力待ち (端末が無ければ失敗) になり、原因が分かりにくいため。
#
# git と gh は runtimeInputs に入れず、PATH のものを使う (home には modules/git.nix の git と
# modules/packages.nix の gh がある)。git gh と呼ばれたときは、git が自分の exec-path を PATH の先頭に
# 足してから起動するので、中の git は呼んだ git と同じものになる。テストは偽の gh を PATH に置いて流す。
{
  lib,
  writeShellApplication,
}:

let
  gitConfig = import ../../lib/git-via-gh.nix;
in
writeShellApplication {
  name = "git-gh";
  text = ''
    hint="  gh を通さずに ssh で通すなら、git gh ではなく git で打ってください (gfp なら gfp-base)。"

    if ! command -v gh >/dev/null; then
      echo "git-gh: gh が見つかりません。GitHub へ gh の資格情報で通すには gh が要ります。" >&2
      echo "''${hint}" >&2
      exit 127
    fi
    # token は捨てる (ログインしているかだけを見る)
    if ! gh auth token --hostname github.com >/dev/null 2>&1; then
      echo "git-gh: gh が github.com にログインしていません。gh auth login を実行してください。" >&2
      echo "''${hint}" >&2
      exit 1
    fi

    exec git ${
      lib.concatMapStringsSep " " (p: "-c ${lib.escapeShellArg "${p.k}=${p.v}"}") gitConfig
    } "$@"
  '';
}
