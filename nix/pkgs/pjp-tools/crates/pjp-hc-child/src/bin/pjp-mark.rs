//! `pjp mark` (spec §7.3・§7.5・§8.4): 会話の端末の label の印と space の名前。中身は lib の `mark`。

use std::process::ExitCode;

use pjp_hc_child::hc::SystemRunner;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let code = pjp_hc_child::mark::main(
        &SystemRunner,
        &args,
        &mut std::io::stdout(),
        &mut std::io::stderr(),
    );
    ExitCode::from(code)
}
