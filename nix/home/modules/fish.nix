# fish shell。
#
# 複製元: .config/fish/config.fish と .fish/*.fish (17 ファイル / 610 行)
#
# レガシー側は 000_ / 050_ / 2XX_ という数字プレフィックスで読み込み順を制御して
# いたが、Nix では役割別に整理し直している。順序が本質的に効くもの
# (PATH の前置、mise activate、starship init) だけを interactiveShellInit の
# 並び順で表現する。
#
# ## 平坦化で判明した重複 (レガシーでは後勝ちだった)
#
#   f  : 201_git の 'git fetch' を 250_alias の 'cd ..' が上書き -> 'cd ..' を採用
#   ls : 060_mise の 'eza' を 250_alias の 'eza --group-directories-first -F' が
#        上書き -> 後者を採用
#
# ## 移植しなかったもの
#
#   010_fish_fisher : fisher 自体が programs.fish.plugins で不要になる
#   252 の日次 pin  : flake.lock が担うので不要
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # 000_constant / 050_common / 260_env_vars / 060_mise のシェル非依存部分は
  # modules/shell-common.nix にある (bash と共有)。

  # 複製元: 298_starship
  # -> programs.starship.enableFishIntegration = true (modules/starship.nix)

  programs.fish = {
    enable = true;

    # 複製元: .config/fish/fish_plugins + 010_fish_fisher.fish
    #
    # fisher (curl でインストーラ取得 + 日次 update) が丸ごと不要になる。
    # fisher 自身もプラグイン一覧に入っていたが、Nix 管理では不要。
    plugins = [
      {
        name = "autopair";
        src = pkgs.fishPlugins.autopair.src;
      }
      {
        name = "fzf-fish";
        src = pkgs.fishPlugins.fzf-fish.src;
      }
    ];

    shellAbbrs = {
      #########################
      # 複製元: 250_alias
      #########################
      f = "cd ..";
      ff = "cd ../..";
      fff = "cd ../../..";
      ffff = "cd ../../../..";
      e = "exit";
      H = "head";
      show_ports_netstat = "netstat -tulpn";
      show_ports_ss = "ss -ltnp";
      today = "date '+%Y-%m-%d'";
      ep = "echo-PATH";
      ws = "touch-vscode-workspace (basename (pwd))";
      cp = "cp -i";
      mv = "mv -i";
      vi = "vim";
      LESS = "less -imMSR";
      ls = "eza --group-directories-first -F";
      la = "eza --group-directories-first -F -a";
      ll = "eza --group-directories-first -F -a -l --header";
      l = "eza --group-directories-first -F -a -1";
      ssh-agent-start = "exec ssh-agent $SHELL";

      #########################
      # 複製元: 060_mise の代替コマンド
      #########################
      cat = "bat";
      grep = "rg";
      fuz = "fzf";

      #########################
      # 複製元: 201_git
      #########################
      g = "git";
      ga = "git add";
      gap = "git add -p";
      gb = "git branch";
      gc = "git commit -v";
      gca = "git commit -v -a";
      gcam = "git commit -v --amend";
      gcl = "git clone --recurse-submodules";
      gcm = "git commit -m";
      gcp = "git commit -p -v";
      gcpm = "git commit -p -m";
      gf = "git fetch --prune";
      gfp = "git fetch --prune && git pull";
      gl = "git log";
      glo = "git log --oneline --decorate";
      glog = "git log --graph --decorate --pretty=format:'%C(auto)%h %C(cyan)%ad%C(auto) %d %s' --date=iso --color=always";
      gloga = "git log --graph --decorate --pretty=format:'%C(auto)%h %C(cyan)%ad%C(auto) %d %s' --date=iso --color=always --all";
      glf = "git log --format='%C(auto)%h%Creset %G? %s'";
      glfg = "git log --format='%C(auto)%h%Creset %G? %s' --graph";
      glfga = "git log --format='%C(auto)%h%Creset %G? %s' --graph --all";
      gls = "git log --stat";
      glsp = "git log --stat -p";
      gm = "git merge";
      gop = "git checkout -p";
      gp = "git push";
      gpf = "git push --force-with-lease";
      gpup = "git_push_set_upstream";
      gpul = "git pull";
      gpull = "git pull";
      gds = "git diff --staged";
      gg = "git grep";
      gr = "git restore";
      grhh = "git reset --hard";
      grs = "git reset --soft";
      gs = "git status";
      gst = "git stash --include-untracked";
      gstp = "git stash pop";
      gwip = "git_commit_WIP";
      gpr = "git_fetch_pull_request";
      w = "git switch";
      gw = "git switch";
      c = "c-func";

      #########################
      # 複製元: 251_alias_k8s
      #########################
      k = "kubectl";
      ksysex = "kubectl --namespace=kube-system exec -i -t";

      #########################
      # 複製元: 252_alias_mise
      #########################
      m = "mise";
      mr = "mise run";

      #########################
      # 複製元: 253_alias_terminal_mux
      #########################
      ta = "tmux a -t";
      td = "tmux detach -s";
      tkill-sess = "tmux kill-session";
      tls = "tmux ls";
      tls-panes = "tmux list-panes";
      tchdir = "tmux-cwd";

      schdir = ''screen -X eval "chdir $PWD"'';
      slayout = ''screen -X eval "layout save default"'';
      sss = "screen -S";
      sls = "screen -ls";
      sa = "screen -r";
      sd = "screen -d";
      skill-sess = "screen-kill-session";

      zls = "zellij list-sessions";
      za = "zellij attach";
      zkill = "zellij kill-session";
      zkill-all = "zellij kill-all-sessions";
      zdel = "zellij delete-session";
      zdel-all = "zellij delete-all-sessions";
    };

    functions = {
      #########################
      # 複製元: 250_alias
      #########################
      echo-PATH = {
        description = "Display PATH entries one per line";
        body = ''
          for p in $PATH
            echo $p
          end
        '';
      };

      touch-vscode-workspace = {
        description = "Create a VSCode workspace file";
        body = ''
          set -l workspace_name $argv[1]
          if test -z "$workspace_name"
            set workspace_name workspace
          end
          set -l workspace_file "$workspace_name.code-workspace"
          if test -f $workspace_file
            echo "File already exists: $workspace_file"
            return 1
          end
          echo '{
            "folders": [
              {
                "path": "."
              }
            ],
            "settings": {}
          }' >$workspace_file
        '';
      };

      ssh-copy-id-custom = {
        description = "Copy SSH key to remote host";
        body = ''
          set -l pubkey_file ~/.ssh/id_ed25519.pub
          set -l ssh_host $argv[1]
          xargs -I{} ssh $ssh_host "echo {} >> .ssh/authorized_keys" <$pubkey_file
        '';
      };

      datetime-format = {
        description = "Print current datetime";
        body = ''
          set -l sep $argv[1]
          if test -z "$sep"
            set sep -
          end
          printf "%s" (date "+%Y$sep%m$sep%dT%H%M%S")
        '';
      };

      hatch-env-find-python = {
        description = "Find python in hatch env";
        body = ''
          echo (hatch env find $argv)/bin/python
        '';
      };

      #########################
      # 複製元: 201_git
      #########################
      git_get_default_branch.body = ''
        git remote show origin 2>/dev/null | head -n 5 | sed -n '/HEAD branch/s/.*: //p'
      '';

      git_fetch_branch.body = ''
        git fetch origin "$argv[1]:$argv[1]"
      '';

      git_fetch_base.body = ''
        git_fetch_branch (git_get_default_branch)
      '';

      git_push_set_upstream.body = ''
        set -l remote (test (count $argv) -ge 1; and echo $argv[1]; or echo origin)
        set -l git_branch_name (git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if test -n "$git_branch_name"
            git push --set-upstream $remote $git_branch_name
        end
      '';

      git_commit_WIP.body = ''
        set -l msg (git log -1 --format=%s | tr -d '\n')
        if string match -qr '^WIP' -- $msg
            git reset --soft HEAD~1
            git commit -m "$msg"
        else
            git commit -m "WIP: temporarily commit"
        end
      '';

      git_branch_cleanup.body = ''
        set -l main_branch (test (count $argv) -ge 1; and echo $argv[1]; or git_get_default_branch)
        git switch $main_branch
        and git fetch --prune
        and git pull
        and git branch --merged | string match -rv '\*' | string match -rv $main_branch | xargs git branch -d
      '';

      git_branch_cleanup_force.body = ''
        set -l main_branch (test (count $argv) -ge 1; and echo $argv[1]; or git_get_default_branch)
        git switch $main_branch
        and git fetch --prune
        and git pull
        and git branch | string match -rv '\*' | string match -rv $main_branch | xargs git branch -D
      '';

      git_fetch_pull_request.body = ''
        set -l pr_num $argv[1]
        git fetch origin "pull/$pr_num/head:pr$pr_num"
      '';

      c-func = {
        description = "git commit with message";
        body = ''git commit -m "$argv"'';
      };

      #########################
      # 複製元: 252_alias_mise
      #########################
      _mise_lock_to_current.body = ''
        mise use $argv --pin (mise ls --current --json | jq -r 'to_entries[] | "\(.key)@\(.value[0].version)"')
      '';

      mise_lock_to_current_global = {
        description = "Pin current tool versions to global mise config";
        body = ''
          _mise_lock_to_current -g
        '';
      };

      #########################
      # 複製元: 253_alias_terminal_mux
      #########################
      # NOTE: 参照先は Stage 3 で ~/.config/tmux/ へ配置したものに書き換えている
      #       (元は ~/dotfiles/tmux/interactive_shell.tmux.conf)
      tss = {
        description = "tmux start session";
        body = ''
          set -l session_name $argv[1]
          if test -z "$session_name"
            echo "Usage: tss <session_name>"
            return 1
          end
          tmux -f ~/.config/tmux/interactive_shell.tmux.conf new -s $session_name
        '';
      };

      tmux-cwd = {
        description = "Change tmux session directory";
        body = ''
          tmux command-prompt -I "$PWD" -p "New session dir:" "attach -c %1"
        '';
      };

      css = {
        description = "attach to shogun tmux session";
        body = ''
          set -l s "shogun-$fish_pid"
          set -l cols (tput cols 2>/dev/null; or echo 80)
          tmux new-session -d -t shogun -s "$s" 2>/dev/null
          and tmux set-option -t "$s" destroy-unattached on 2>/dev/null

          if test "$cols" -lt 80
            tmux new-window -t "$s" -n mobile 2>/dev/null
            tmux attach-session -t "$s:mobile" 2>/dev/null
            or tmux attach-session -t shogun
          else
            tmux attach-session -t "$s" 2>/dev/null
            or tmux attach-session -t shogun
          end
        '';
      };

      csm = {
        description = "attach to multiagent tmux session";
        body = ''
          set -l s "multi-$fish_pid"
          set -l cols (tput cols 2>/dev/null; or echo 80)
          tmux new-session -d -t multiagent -s "$s" 2>/dev/null
          and tmux set-option -t "$s" destroy-unattached on 2>/dev/null

          if test "$cols" -lt 80
            tmux new-window -t "$s" -n mobile 2>/dev/null
            tmux attach-session -t "$s:mobile" 2>/dev/null
            or tmux attach-session -t multiagent
          else
            tmux attach-session -t "$s" 2>/dev/null
            or tmux attach-session -t multiagent
          end
        '';
      };

      screen-kill-session = {
        description = "Kill a screen session";
        body = ''
          screen -X -S $argv[1] kill
        '';
      };

      z = {
        description = "zellij with favorite shell";
        body = ''
          set -l _shell_path
          if set _shell_path (command -v fish)
            : # do nothing
          else if set _shell_path (command -v zsh)
            : # do nothing
          end

          if test -n "$_shell_path"
            set -x SHELL $_shell_path
          end
          zellij $argv
        '';
      };

      zss = {
        description = "zellij start session";
        body = ''
          set -l session_name $argv[1]
          if test -z "$session_name"
            echo "Usage: zss <session_name>"
            return 1
          end
          set -l session_line (zellij list-sessions 2>/dev/null | grep $session_name)
          if test -n "$session_line"
            if string match -q '*EXITED*' -- $session_line
              zellij delete-session $session_name
              z -s $session_name
            else
              echo "Already running! Run 'zellij attach $session_name' to attach to it."
            end
          else
            z -s $session_name
          end
        '';
      };

      #########################
      # 複製元: 254_alias_fzf
      #########################
      cdrepo = {
        description = "cd to ghq repository";
        body = ''
          if not command -v ghq &>/dev/null
            echo "ghq is not installed"
            return 1
          end
          if not command -v fzf &>/dev/null
            echo "fzf is not installed"
            return 1
          end

          set -l repodir (ghq list | fzf -1 +m) \
            && cd (ghq root)/$repodir
        '';
      };
    };

    interactiveShellInit = ''
      # 複製元: 010_fish_fisher (greeting 抑制)
      set -g fish_greeting

      # 複製元: 050_common
      fish_vi_key_bindings

      # 複製元: 200_tty
      set -gx GPG_TTY (tty)

      # 複製元: 000_constant (MANPATH)
      if command -q manpath
        set -l tmp (manpath -g 2>/dev/null)
        if test -n "$tmp"
          set -gx MANPATH $MANPATH $tmp
        end
      end

      # 複製元: 205_go_path
      # NOTE: cygpath による Windows 分岐は対象外なので移植していない
      if command -q go
        fish_add_path --prepend (go env GOPATH)/bin
      end

      # 複製元: 206_cargo_path
      if test -f ~/.cargo/env.fish
        source ~/.cargo/env.fish
      else if test -d ~/.cargo/bin
        fish_add_path --prepend ~/.cargo/bin
      end

      # 複製元: 175_k8s
      if command -q kubectl
        kubectl completion fish | source
      end

      # 複製元: 010_fish_fisher (fzf.fish のキーバインド)
      if type -q fzf_configure_bindings
        fzf_configure_bindings \
          --directory=alt-shift-f \
          --git_log=alt-shift-l \
          --git_status=alt-shift-s \
          --processes=alt-shift-p
      end

      # 複製元: 299_ssh_agent
      # 1password などで既に ssh-agent が動いていれば何もしない。
      # 動いていなければ保存済みの agent 情報を読み、それでも駄目なら新規起動する。
      #
      # NOTE: 元のコードには ssh-add の存在確認が無く、ssh-add が無い環境では
      #       起動のたびに "Unknown command: ssh-add" が 2 回出ていた。
      #       移植にあたってガードを追加している。
      if command -q ssh-add
        set -l SSH_AGENT_FILE "$HOME/.ssh-agent"

        if not ssh-add -l >/dev/null 2>&1; and test -f $SSH_AGENT_FILE
          set -l auth_sock (grep SSH_AUTH_SOCK $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
          set -l agent_pid (grep SSH_AGENT_PID $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
          if test -n "$auth_sock"
            set -gx SSH_AUTH_SOCK $auth_sock
          end
          if test -n "$agent_pid"
            set -gx SSH_AGENT_PID $agent_pid
          end
        end

        if not ssh-add -l >/dev/null 2>&1
          if not set -q SSH_AGENT_PID; or test -z "$SSH_AGENT_PID"
            ssh-agent >$SSH_AGENT_FILE
            set -l auth_sock (grep SSH_AUTH_SOCK $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
            set -l agent_pid (grep SSH_AGENT_PID $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
            if test -n "$auth_sock"
              set -gx SSH_AUTH_SOCK $auth_sock
            end
            if test -n "$agent_pid"
              set -gx SSH_AGENT_PID $agent_pid
            end
          end

          if test -f "$HOME/.ssh/id_ed25519"
            ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null
          end
        end
      end
    '';
  };
}
