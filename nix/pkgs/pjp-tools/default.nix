# ハブと子の道具 (pjp hub・pjp child・pjp mark・pjp pack) と入口 pjp (dotfiles-private の ADR 124)。使い方は nix/README.md・win/README.md の
# 「ハブと子の道具 (pjp-tools)」と、この dir の README.md。
#
# Linux と Windows の両方に、この 1 つの workspace を置く: Linux はこの package (home には modules/pjp-tools.nix が、hc が入るホスト
# (dotfiles.herdrCore.enable) と claude-skills の道具を使うホスト (dotfiles.claude.privateSkills.enable) に入れる)、Windows は CI
# (.github/workflows/pjp-tools-release.yml) が workspace の git の tree の hash ごとの Release に置いた exe を、runner の手順 pjp-tools が
# 確かめて %LOCALAPPDATA%\dotfiles\bin\ に置く。形は claude-selector と同じ:
#
#   - rustPlatform.buildRustPackage と Cargo.lock (cargoLock.lockFile)。crate の版は公開から 7 日以上経ったものに限る
#   - build の中で cargo test を流す (何を確かめるかは各 crate の試験の先頭)。flake の checks の pjp-tools-test はこの package
#     そのもの、pjp-tools-lint は cargo fmt --check と cargo clippy -D warnings。Windows の側は CI の pjp-tools が windows-latest で
#     clippy と test を流す
#   - 直すときの道具は flake の devShells.pjp-tools (cargo・rustc・clippy・rustfmt・git)
#
# src は nix/ を root にし、workspace と、pjp-hc-hub の試験が読む skill の図の雛形 (files/claude/skills/pjp-hc-hub/assets/panel) と、
# 雛形の細かさの倍率を書いた panel-figures.md だけを入れる (cargoRoot・buildAndTestSubdir で workspace に入って作る)。試験は git を
# 打つ (ハブを一時ディレクトリに作る)
{
  lib,
  rustPlatform,
  git,
}:

rustPlatform.buildRustPackage {
  pname = "pjp-tools";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./crates
      ../../files/claude/skills/pjp-hc-hub/assets/panel
      ../../files/claude/skills/pjp-hc-hub/references/panel-figures.md
    ];
  };
  cargoRoot = "pkgs/pjp-tools";
  buildAndTestSubdir = "pkgs/pjp-tools";

  cargoLock.lockFile = ./Cargo.lock;

  nativeCheckInputs = [ git ];

  meta = {
    description = "ハブと子の道具 (pjp hub・child・mark・pack) と入口 pjp";
    mainProgram = "pjp";
    platforms = lib.platforms.unix;
  };
}
