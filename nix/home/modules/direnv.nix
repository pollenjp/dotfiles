# direnv と nix-direnv。ディレクトリに入ると、そこの .envrc が書く環境をシェルに読み込み、出ると戻す。
#
# .envrc に `use flake` と書くと、その flake の devShell に入る。1 つの flake に devShell を並べ、
# ディレクトリごとの .envrc で選ぶこともできる:
#   repo の直下の flake.nix が devShells.<system>.ch01 を持つとき、ch01/.envrc に
#     use flake ../..#ch01
#     dotenv_if_exists    # 秘密の値は、隣の .env に置いて読む (無ければ何もしない)
# 初めて入ったディレクトリと、書き換えた .envrc は止められる。中身を確かめてから `direnv allow` で許す。
#
# `use flake` は nix-direnv が受け持つ (direnv 自身のものより速く、devShell が消えない):
#   - 評価した devShell を .envrc のディレクトリの .direnv/ に cache し、flake.nix・flake.lock
#     (と devshell.toml) が変わるまで評価し直さない。flake.nix から読む別のファイルを変えたときは
#     `direnv reload` を打つか、.envrc に `watch_file <ファイル>` を足す
#   - devShell と flake の inputs に、.direnv/ から GC root を張る。週 1 回の nix-collect-garbage
#     (modules/cleanup.nix) でも消えない。要らなくなったら .direnv/ を消せば root も外れる
#
# .envrc は global gitignore で無視しない (repo に置いて共有する)。秘密の値は .envrc に書かず、
# global gitignore で無視している .env に置いて、`dotenv_if_exists` で読む (modules/git.nix の NOTE)。
{ ... }:

{
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;

    # hook は fish の interactiveShellInit と bash の initExtra に、home-manager が mkAfter で足す
    # (どちらも mise activate より後ろ)。devShell が mise の global のツールと同じコマンド (node など) を
    # 持つときも、そのディレクトリの中では devShell の方が先に引かれる。
    enableFishIntegration = true;
    enableBashIntegration = true;
    # zsh は Nix の対象外なので常に false (modules/starship.nix と同じ)
    enableZshIntegration = false;

    # .direnv/ (nix-direnv の cache と GC root) を global gitignore に足す
    enableGitIntegration = true;

    # ~/.config/direnv/direnv.toml
    config.global = {
      # 読み込むたびに出る「direnv: export +AR +AS … ~PATH」を出さない。devShell では数十個の
      # 変数が 1 行に並び、プロンプトが流れる。「direnv: loading …」と、.envrc が止められている
      # ときのエラー (direnv allow を促す) は出る。
      #
      # warn_timeout は既定 (5 秒) のまま。devShell を初めて評価・ビルドするときは長く待つので、
      # 待っていることと Ctrl-C で止められることを知らせてくれる。
      hide_env_diff = true;
    };
  };
}
