# claude-selector (略語 cs): 組み立てるコマンド行をいつも見せ、その項目 (claude のアカウントと option) を矢印キーで選んで Claude Code を
# 起こす。使い方は nix/README.md・win/README.md の「claude-selector (cs)」。設計は dotfiles-private の docs/adr/087_claude_selector_* (画面と
# 引数の並びは docs/adr/116_claude_selector_command_line_*)。
#
# 項目はコマンド行の区切りで、左から (起こす引数もこの並び):
#
#   アカウント      素の claude (既定) と claude-<名前> (既定のアカウントと claude-account add の登録。launcher が PATH に無いものは選べない)
#   effort          low・medium・high・xhigh・max (既定)
#   モデル          claude-opus-5-5 (既定) ほかと、手で打つ
#   権限            --dangerously-skip-permissions (既定)・--permission-mode auto・付けない・acceptEdits・plan
#   Remote Control  付けない (既定)・名前なし (--remote-control=)・名前を付ける (--remote-control=<名前>)
#
# ←→ (h l) で項目を移り、↑↓ (j k) で値を選ぶと、すぐコマンド行に出る。Enter でどの項目からでも今のコマンド行のまま起こす (Esc・Ctrl+C で
# やめる)。どの項目も既定に印を付け、打ってすぐ Enter で既定のまま起こす。cs の後ろの引数は、組み立てた引数の後ろにそのまま付ける。
# unix は exec で置き換わる。
#
# Linux と Windows の両方に、この 1 つの crate を置く: Linux はこの package (home には modules/claude.nix が dotfiles.claude.enable の
# ホストに入れる)、Windows は runner の手順 claude-selector (win/runner/src/steps/claude_selector.rs) が同じ Cargo.lock で cargo build して
# %LOCALAPPDATA%\dotfiles\bin\ に置く。Rust にしたのは、矢印キーで選ぶ同じ画面を両方の OS に 1 本で出すため (fzf と PowerShell の 2 本に
# しない)。形は pjp-ghq-pull と同じ:
#
#   - rustPlatform.buildRustPackage と Cargo.lock (cargoLock.lockFile)。crate の版は公開から 7 日以上経ったものに限る
#     (cargo には猶予の設定が無いので、Cargo.lock を作り直したら crates.io の公開日時を見て、新しすぎる版は
#     cargo update -p <名前> --precise <前の版> で下げる)
#   - build の中で cargo test を流す (何を確かめるかは tests/*.rs の先頭)。flake の checks の claude-selector-test はこの package
#     そのもの、claude-selector-lint は cargo fmt --check と cargo clippy -D warnings。Windows の側は CI の win-runner が
#     windows-latest で clippy と test を流す
#   - 直すときの道具は flake の devShells.claude-selector (cargo・rustc・clippy・rustfmt)
#
# claude と claude-<名前> は runtimeInputs のように包まず、PATH のものを起こす (mise の claude と、claude-account の launcher)。
{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "claude-selector";
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

  meta = {
    description = "claude のアカウントと option を矢印キーで選んで Claude Code を起こす (cs)";
    mainProgram = "claude-selector";
    platforms = lib.platforms.unix;
  };
}
