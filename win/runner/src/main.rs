//! `dotfiles-win` の入口。中身は `dotfiles_win::cli`。claude-accounts の手順が `claude-<名前>.exe` の名前で写したものは launcher として動く
//! (`dotfiles_win::launcher`。runner の引数を読まない)。

fn main() {
    if let Some(code) = dotfiles_win::launcher::main_if_launcher() {
        std::process::exit(code);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(dotfiles_win::cli::main(args));
}
