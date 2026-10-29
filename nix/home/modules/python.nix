# nixpkgs の python3 を home.packages に入れ、uv には自分で入れた python だけを使わせる。
#
# ## なぜ python3 を Nix で入れるのか
#
# Claude Code の Claude Security plugin (scripts/bootstrap-claude-plugins.sh が入れる claude-security) は、PATH の
# python3 (3.9 以上。標準ライブラリだけ) で helper の script を動かす。無い・古いと /claude-security が警告を出し、
# スキャンも修正も動かない。OS の python3 は版がマシンごとに違う (無い OS もある) ので、ここで揃える。
# claude-skills の script (ticket.sh など) が、python3 が 3.11 未満のときに nix develop へ入り直すのも要らなくなる。
#
# ADR 001 の決定 6 の「言語ランタイムは mise」は、プロジェクトごとに版を切り替えるもの (go・node) の話。python3 は
# プロジェクトで切り替えず、道具の前提として使うので、グローバルな CLI と同じく Nix に置く (modules/packages.nix の
# 冒頭の役割分担)。プロジェクトで版を決めて使う python は、今までどおり uv か mise で入れる。
#
# ~/.nix-profile/bin は PATH で /usr/bin より前に来るので、すべてのシェルと Claude の Bash tool の python3 (と python・
# pydoc) がこれに替わる。OS のコマンドは /usr/bin/python3 を直に指すので替わらない。apt の python3-* (yaml など) は、
# この python からは見えない。
#
# ## なぜ uv の python-preference を only-managed にするのか
#
# uv は、自分で入れた python が無いと PATH の python3 で venv を作る。python3 が Nix のものになると、venv が
# /nix/store の python に結び付き、nixpkgs を上げて古い python が GC されると動かなくなる。only-managed にすると、
# uv は自分で入れた python (無ければ落としてくる) だけで venv を作る。
#
# 環境変数 (UV_PYTHON_PREFERENCE) でなく ~/.config/uv/uv.toml に書くのは、
#   - hm-session-vars は 1 つの session で 1 回しか読まず、switch の前から続く process (herdr の server など) の下で
#     開いたシェルには届かない。uv.toml は switch の後の次の uv から効く (python3 も switch の直後から替わる)
#   - 環境変数はプロジェクトの [tool.uv] の python-preference より強い。user の uv.toml はプロジェクトの設定より
#     弱いので、プロジェクトが別の値を選べる
#
# 既存の .venv の作り直しと、版を決めていないプロジェクトが uv の知る最新の python を使うことは、
# nix/README.md の「python3 と uv」(uv 0.13.0・0.11.3 で確かめた)。
{ pkgs, ... }:

{
  home.packages = [ pkgs.python3 ];

  programs.uv = {
    enable = true;
    # uv 本体は入れない。uv はプロジェクトの mise などが入れる (modules/packages.nix の役割分担)
    package = null;
    settings.python-preference = "only-managed";
  };
}
