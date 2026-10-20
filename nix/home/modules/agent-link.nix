# ssh 先で、herdr の中から forward された ssh-agent を使い続けるための仕組み (ADR 025。ADR 008 の後続)。
# herdr を包んだもの・~/.ssh/rc・見張りの systemd の unit を置く。向け先の決め方は
# nix/pkgs/pjp-agent-link/pjp-agent-link.sh の先頭のコメント。
#
#   bin/herdr                 herdr を包む実行ファイル (nix/pkgs/pjp-agent-link/herdr.sh)。hr (herdr --remote) の
#                             bridge もここを通る。server を起こしうる呼び出しで SSH_AUTH_SOCK を session の固定名にする
#   bin/pjp-agent-link        向け先を決める script。手で打つ ssh-agent-link も同じ package
#   ~/.ssh/rc                 sshd が接続のたびに走らせる。forward された socket と PJP_SSH_CLIENT を記録するだけ
#   pjp-agent-link-watch      systemd の user の path unit と service (Linux だけ)。接続が増えた・減ったら固定名を見直す
#
# このマシンを名乗る PJP_SSH_CLIENT (SetEnv) は modules/ssh.nix と、Windows は bootstrap-windows-ssh-config.sh が
# 書く config に置く。値が届いていないことを出す starship の警告は files/starship.toml の custom.pjp_ssh_client。
#
# ## ~/.ssh/rc を置くと変わること
#
# sshd は ~/.ssh/rc があると xauth を自分では呼ばず、/etc/ssh/sshrc も走らせない。X11 の cookie は
# pjp-agent-link rc が sshd(8) の例どおりに xauth へ渡す。subsystem (sftp) と ForceCommand の接続、PermitUserRC no の
# sshd、authorized_keys の restrict・no-user-rc の鍵では rc が走らず、その接続は記録されない (attach の張り替えは
# 効くが、見張りはその接続を借りない)。rc の stdout はその ssh のセッションのデータなので、/dev/null へ向けてから
# exec する。
#
# ## 見張り
#
# PathChanged は、ディレクトリの中でファイルができた・消えた・rename されたら service を起こす。~/.ssh/agent は
# OpenSSH 10.1 から sshd が forward した socket を置く場所 (それより前の /tmp/ssh-*/ は見張らない)。conn/ は rc が
# 書く記録で、書けたあとに借りられるよう見る。path unit は service が走っている間の知らせを見ないので、
# pjp-agent-link watch は始めと終わりで中身を比べて繰り返す。何も起きないホスト (WSL の手元など) では待つだけ。
# macOS には systemd が無いので置かない (attach の張り替えだけが効く)。
{ lib, pkgs, ... }:

let
  agentLink = pkgs.callPackage ../../pkgs/pjp-agent-link { };
  herdr = pkgs.callPackage ../../pkgs/pjp-agent-link/herdr.nix { inherit agentLink; };
in
{
  home.packages = [
    herdr
    agentLink
  ];

  home.file.".ssh/rc".text = ''
    # dotfiles (home-manager) が置く (nix/home/modules/agent-link.nix。ADR 025)。sshd が接続のたびに /bin/sh で走らせる。
    # stdout はそのセッションのデータなので、何も書かない
    exec ${lib.getExe agentLink} rc >/dev/null
  '';

  systemd.user = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    paths.pjp-agent-link-watch = {
      Unit.Description = "pjp-agent-link: ssh の接続が増えた・減ったら herdr の固定名を見直す";
      Path.PathChanged = [
        "%h/.ssh/agent"
        "%h/.local/state/pjp-agent-link/conn"
      ];
      Install.WantedBy = [ "default.target" ];
    };

    services.pjp-agent-link-watch = {
      Unit = {
        Description = "pjp-agent-link: 先が死んだ herdr の固定名に、同じマシンの生きている接続を借りる";
        # 知らせのたびに起きる (hr の attach は確認用の短い接続を何本も張るので、数秒に 10 回を超える)。
        # 既定の起動の上限 (10 秒に 5 回) に当たると、service も path unit も failed になって見張りが
        # 止まる (lavie で実測。unit-start-limit-hit) ので、上限を外す。1 回は数十 ms で終わる
        StartLimitIntervalSec = 0;
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe agentLink} watch";
      };
    };
  };
}
