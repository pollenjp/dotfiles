# homeConfiguration を組み立てるヘルパ。
# hosts/default.nix から 1 マシン 1 行で呼ぶ。
{ inputs }:

{
  username,
  system,
  # macOS だけ home の親ディレクトリが異なる
  homeDirectory ?
    if inputs.nixpkgs.lib.hasSuffix "darwin" system then "/Users/${username}" else "/home/${username}",
  # WSL 固有の設定をまとめて渡す (dotfiles.wsl にそのまま入る)。
  # 有効な組み合わせが構造に出るよう、1Password は WSL の下、Windows ユーザー名は
  # さらに 1Password の下に置いている。
  #
  #   wsl = {
  #     enable = true;
  #     onePassword = {
  #       enable = true;
  #       windowsUserName = "polle";
  #     };
  #   };
  #
  # 省略すれば非 WSL マシン。個々の既定値は home/options.nix を参照。
  wsl ? { },
  # Claude Code まわりのマシン固有設定 (dotfiles.claude にそのまま入る)。
  #
  #   claude.devTracker.enable = false;   # Notion Dev Tracker を使わないマシン
  #
  # 省略すれば既定 (使う)。ローカル flake (~/dotfiles/flake.nix) の雛形は
  # 登録簿のホストにも当たる module で false にしているので、そちら経由の
  # マシンでは雛形側を見ること。
  claude ? { },
  modules ? [ ],
}:

inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  extraSpecialArgs = { inherit inputs; };
  modules = [
    ../home
    {
      home = { inherit username homeDirectory; };
      dotfiles = { inherit wsl claude; };
    }
  ]
  ++ modules;
}
