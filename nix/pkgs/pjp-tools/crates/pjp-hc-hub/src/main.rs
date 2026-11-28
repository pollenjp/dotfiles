//! bin `pjp-hub` (shim から `pjp hub …` で打つ)。中身は lib の `cli`。

fn main() -> std::process::ExitCode {
    pjp_hc_hub::cli::main(std::env::args_os().skip(1).collect())
}
