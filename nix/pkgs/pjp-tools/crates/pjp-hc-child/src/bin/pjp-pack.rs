//! `pjp pack` (spec §6.2): skill の pack から子の `--settings` の JSON を作る・割り当てを確かめる。中身は lib の `pack`。

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let code = pjp_hc_child::pack::main(&args, &mut std::io::stdout(), &mut std::io::stderr());
    ExitCode::from(code)
}
