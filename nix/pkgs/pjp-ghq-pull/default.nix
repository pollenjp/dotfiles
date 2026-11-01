# ghq の repo を org・repo 単位の木で選び、選んだ repo の既定 branch を fetch --prune と fast-forward で最新にする TUI。
# 既定 branch でない・追跡中のファイルに変更がある・分岐している (merge commit が要る) など、そのまま進められない repo は
# 確認待ちに回し、答えを待つ間もほかの repo は並列で進める。使い方と確認待ちの理由・選べることは nix/README.md の
# 「ghq の repo をまとめて最新にする (pjp-ghq-pull)」。
#
# Rust にしたのは、選ぶ画面・並列の作業・問いの画面を 1 つの実行ファイルで持ち、1 repo の判定 (どの理由で問うか・
# 何を流すか) を型で書くため。shell と fzf では、答えを待つ間にほかの repo を進める画面が組めない。dotfiles で Rust を
# 包むのはこれが初めてで、形は次のとおり:
#
#   - rustPlatform.buildRustPackage と Cargo.lock (cargoLock.lockFile)。crate の版は公開から 7 日以上経ったものに限る
#     (cargo には猶予の設定が無いので、Cargo.lock を作り直したら crates.io の公開日時を見て、新しすぎる版は
#     cargo update -p <名前> --precise <前の版> で下げる)
#   - build の中で cargo test を流す (一時ディレクトリに bare の remote と clone を作り、本物の git と ghq で判定を確かめる)。
#     flake の checks の pjp-ghq-pull-test はこの package そのもの、pjp-ghq-pull-lint は cargo fmt --check と
#     cargo clippy -D warnings
#   - 直すときの道具は flake の devShells.pjp-ghq-pull (cargo・rustc・clippy・rustfmt・git・ghq)
#
# gitViaGh (dotfiles.claude.gitViaGh.enable) は ~/.local/state/dotfiles/git-via-gh.json の "enable": true で on と読み、
# fetch だけを git gh で打つ (merge・rebase・checkout は通信しないので素の git)。on なのに git-gh か gh が無い・gh が
# github.com にログインしていないときは、ssh に倒さずに始める前に止める。
#
# git・ghq・gh・git-gh は runtimeInputs のように包まず、PATH のものを使う (home には modules/git.nix の git と
# modules/packages.nix の ghq・gh・git gh がある)。ユーザーの git の設定 (署名・hook・core.sshCommand) をそのまま効かせる。
{
  lib,
  rustPlatform,
  git,
  ghq,
}:

rustPlatform.buildRustPackage {
  pname = "pjp-ghq-pull";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      ./tests
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  # cargo test が一時の repo を作る git と、repo の一覧を読む ghq
  nativeCheckInputs = [
    git
    ghq
  ];

  meta = {
    description = "ghq の repo を選び、既定 branch を fetch と fast-forward で最新にする TUI";
    mainProgram = "pjp-ghq-pull";
    platforms = lib.platforms.unix;
  };
}
