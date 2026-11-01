//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! - crate の版が Cargo.toml の版 (0.1.0) として lib から読めること (cargo test と Nix の build の通り道)

#[test]
fn version_matches_cargo_toml() {
    assert_eq!(pjp_ghq_pull::VERSION, "0.1.0");
}
