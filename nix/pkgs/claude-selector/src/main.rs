//! claude-selector の入口 (流れは `claude_selector::app`)。unix では選んだコマンドに exec で置き換わり、ここへは戻らない。

fn main() {
    std::process::exit(claude_selector::app::main());
}
