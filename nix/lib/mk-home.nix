# homeConfiguration を組み立てるヘルパ。
# hosts/default.nix (型と sandbox)・dotfiles-private の nix/hosts/*.nix (lib/private-hosts.nix)・ローカル flake の tmp から、
# 1 マシン 1 回呼ぶ。
{ inputs }:

{
  username,
  system,
  # macOS だけ home の親ディレクトリが異なる
  homeDirectory ?
    if inputs.nixpkgs.lib.hasSuffix "darwin" system then "/Users/${username}" else "/home/${username}",
  # WSL 固有の設定をまとめて渡す (dotfiles.wsl にそのまま入る)。
  # 有効な組み合わせが構造に出るよう、win/ の配布などは WSL の下に置いている。
  #
  #   wsl = {
  #     enable = true;
  #     windowsUserName = "alice";   # ホスト側 Windows のユーザー名 (例は作り物)
  #     windowsFiles.enable = true;
  #     exeExecTrace.enable = true;   # .exe の起動を常時記録する (ADR 012。setup の手順が要る)
  #   };
  #
  # 省略すれば非 WSL マシン。個々の既定値は home/options.nix を参照。
  wsl ? { },
  # 1Password を使うか (dotfiles.onePassword にそのまま入る)。WSL ならホスト側 Windows の、
  # それ以外はこのマシンの 1Password で git の署名をする (ADR 022)。
  #
  #   onePassword.enable = true;
  #
  # 省略すれば使わない (署名の設定を書き出さない)。
  onePassword ? { },
  # Claude Code まわりのマシン固有設定 (dotfiles.claude にそのまま入る)。
  #
  #   claude.devTracker.enable = true;    # Notion Dev Tracker を使うマシン (既定は使わない。ADR 027)
  #   claude.devTracker.inbox.enable = true;  # チケットのコメントをハブの会話へ届ける見回り役を常駐させるマシン (Linux。既定は置かない)
  #   claude.gitViaGh.enable = false;     # gh にログインしないマシン (Claude の git・fetch 系の abbr / alias・setup の取得を ssh で通す)
  #   claude.notion.profile = "personal";  # Notion へ書く skill の既定の宛先 (claude-skills の profiles.toml の名前)
  #   claude.notion.routes = { "pollenjp/*" = "work"; };  # このマシンだけの宛先の規則 (例: 会社の PC で pollenjp の repo も work に書く)
  #   claude.videoOffer.autoStart.enable = true;  # 設計・PR のときに解説動画の短尺を答えを待たずに作り始めるマシン (既定は先に聞く)
  #
  # 省略すれば既定 (gitViaGh は true、devTracker (inbox も) と videoOffer.autoStart は false。個々は home/options.nix)。
  # dotfiles-private に登録したホスト (lib/private-hosts.nix) とローカル flake の tmp は、ここに渡す値でその PC の
  # 値の全部を持つ (ADR 027)。前の雛形のローカル flake は、登録簿のホストに local の module を前置する (lib.hostsWith)。
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
      dotfiles = { inherit wsl claude onePassword; };
    }
  ]
  ++ modules;
}
