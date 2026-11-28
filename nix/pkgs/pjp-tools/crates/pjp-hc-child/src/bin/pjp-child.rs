//! `pjp child` (spec §7.4〜§7.8): 子の Claude Code を立てる・読む・送る・片付ける。中身は lib の `child`。

use std::process::ExitCode;

use pjp_hc_child::hc::SystemRunner;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let code = pjp_hc_child::child::main(
        &SystemRunner,
        &args,
        &mut std::io::stdout(),
        &mut std::io::stderr(),
    );
    ExitCode::from(code)
}
