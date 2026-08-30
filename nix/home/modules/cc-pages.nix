# cc-pages の常駐設定。
#
# cc-pages は Claude Code の長い応答を HTML としてローカルに残し、web app で読むための
# ツール。ここではその daemon (`cc-pages serve`) を systemd user service として常駐させる。
#
#   ~/bin/cc-pages serve    -> 127.0.0.1:7777 で待ち受ける
#
# バイナリの配置は Nix ではなく `nix/scripts/bootstrap-cc-pages.sh` が行う。
#
# ## なぜ Nix (flake input) でバイナリを配らないのか
#
# cc-pages は **private** で、dotfiles は **public**。flake input にすると:
#
#   - public な flake.lock に private repo の URL と rev が載る
#   - GitHub Actions の `nix flake check` が fetch できずに落ちる
#
# claude-skills とまったく同じ理由。詳しくは bootstrap-claude-skills.sh の冒頭。
#
# ## バイナリが無いマシンで失敗しないこと
#
# dotfiles は public なので、cc-pages を取れないマシン (鍵が無い、オフライン、
# そもそも使わない) でも switch は通したい。unit を無条件に起動すると、そういう
# マシンで `cc-pages.service` が failed のまま残り、`systemctl --user status` が
# 常に赤くなる。
#
# そこで **ConditionPathIsExecutable** を使う。条件が偽の unit は「起動しなかった」
# ではなく「条件不成立でスキップ」として扱われ、**失敗として記録されない**。
# bootstrap がバイナリを置いた後は、次の起動 (または bootstrap 内の restart) から
# 普通に上がる。
#
# ## socket activation にしていない理由
#
# 設計では `.socket` を置いて最初のアクセスで起こし、`--idle-timeout` で寝る形を
# 想定していたが、v1 では採らない。Go 側に go-systemd/activation が要り、外部依存が
# 2 つ目になる。常駐しっぱなしでもメモリは数十 MB で、困ってから足せばよい。
{ ... }:

{
  systemd.user.services.cc-pages = {
    Unit = {
      Description = "cc-pages — Claude Code の応答を読むローカル web ビューア";
      Documentation = "https://github.com/pollenjp/cc-pages";
      # バイナリが無いマシンでは静かにスキップする (上のコメント参照)。
      ConditionPathIsExecutable = "%h/bin/cc-pages";
    };

    Service = {
      # 既定は 127.0.0.1:7777 / ~/.local/share/cc-pages。
      # 変えたい場合は ~/.config/cc-pages/config.toml か CC_PAGES_ADDR / CC_PAGES_ROOT。
      ExecStart = "%h/bin/cc-pages serve";
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install.WantedBy = [ "default.target" ];
  };
}
