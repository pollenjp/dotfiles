//! `dotfiles-win` の入口。中身は `dotfiles_win::cli`。

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(dotfiles_win::cli::main(args));
}
