# bash。
#
# 複製元: .bashrc / .bash/*.sh / shell/*.sh (bash と zsh の共有部分)
#
# シェル非依存の設定 (sessionVariables / sessionPath / mise) は
# modules/shell-common.nix にある。
#
# ## bash で壊れていたものを移植時に修正した
#
#   c        : `alias c='noglob c-func'` の noglob は zsh 専用で bash には無く、
#              `c` は "noglob: command not found" で失敗していた -> c-func を直接呼ぶ
#   cdrepo   : ガードが `if not command -v ghq` と fish 構文で書かれており、
#              bash では `not` が見つからず終了ステータス 127 -> 常に偽。
#              つまりガードが一度も発火しない死んだコードだった -> `!` に修正
#
# ## 移植しなかったもの
#
#   025_mingw / 205_go_path の cygpath 分岐 : Windows は対象外
#   .bash/02_asdf.sh                        : asdf は既に使われていない
#   050_common の `bindkey -v`               : zsh 専用のガード付きで、
#                                             bash では元々発火していなかった
{ config, ... }:

{
  programs.bash = {
    enable = true;

    # 複製元: main.bash:199-219 が curl + tar で bash-completion 2.11 を
    # 取得し ~/.bashrc にローダ行を追記していた処理。まるごと不要になる。
    enableCompletion = true;

    # 複製元: 000_constant (HISTSIZE / HISTFILE)
    # SAVEHIST は zsh 用なので移植していない。
    historySize = 10000;
    historyFileSize = 10000;
    historyFile = "${config.home.homeDirectory}/.shell_history";

    shellAliases = {
      #########################
      # 複製元: 250_alias
      #########################
      # NOTE: f は 201_git が 'git fetch' を定義した後に 250_alias が
      #       'cd ..' で上書きしていた。後勝ち側を採用する。
      f = "cd ..";
      ff = "cd ../..";
      fff = "cd ../../..";
      ffff = "cd ../../../..";
      e = "exit";
      H = "head";
      show_ports_netstat = "netstat -tulpn";
      show_ports_ss = "ss -ltnp";
      today = "date '+%Y-%m-%d'";
      ep = "echo-PATH-tr";
      ws = ''touch-vscode-workspace "$(basename "$(pwd)")"'';
      cp = "cp -i";
      mv = "mv -i";
      vi = "vim";
      LESS = "less -imMSR";
      # 末尾のスペースは意図的。直後の語も alias 展開の対象になる
      watch = "watch ";
      ssh-agent-start = "exec ssh-agent $SHELL";

      # OSTYPE が darwin/linux の分岐を採用 (msys 分岐は対象外)
      ls = "eza --group-directories-first -F";
      la = "eza --group-directories-first -F -a";
      ll = "eza --group-directories-first -F -a -l --header";
      l = "eza --group-directories-first -F -a -1";

      #########################
      # 複製元: 060_mise の代替コマンド
      #########################
      # NOTE: 元は `alias ls='exa'` もあったが exa は eza の旧名で、
      #       いずれにせよ 250_alias の eza 版に上書きされていた。
      cat = "bat";
      grep = "rg";

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

      # NOTE: レガシーでは alias が alias を参照する連鎖 (glfg='glf --graph' など)
      #       になっていたが、fish 側と揃えて完全形に展開してある。
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
      # noglob (zsh 専用) を外した。詳細はファイル冒頭の注記を参照
      c = "c-func";

      #########################
      # 複製元: 251_alias_k8s / .bash/08-k8s.sh
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

      zls = "z list-sessions";
      za = "z attach";
      zkill = "z kill-session";
      zkill-all = "z kill-all-sessions";
      zdel = "z delete-session";
      zdel-all = "z delete-all-sessions";

      # herdr。zellij の z* の先頭を h に変えただけ。対応表・`hd` を作れない
      # 理由・落としたものは fish.nix の同じ節に書いてある。
      #
      # 上の z* が `z` 経由なのは SHELL を差し替える必要があるからで、herdr は
      # config.toml の default_shell が同じ役目を果たす。なので `h` は挟まず
      # `herdr` を直に呼ぶ。
      h = "herdr";
      hss = "herdr --session";
      hls = "herdr session list";
      ha = "herdr session attach";
      hkill = "herdr session stop";
      hdel = "herdr session delete";

      hst = "herdr status";
      hreload = "herdr server reload-config";
    };

    initExtra = ''
      ##############################################################
      # 複製元: 200_tty
      ##############################################################
      GPG_TTY=$(tty)
      export GPG_TTY

      ##############################################################
      # 複製元: 000_constant (MANPATH)
      ##############################################################
      if command -v manpath &>/dev/null; then
        export MANPATH="''${MANPATH}:$(manpath -g)"
      fi

      ##############################################################
      # 複製元: 205_go_path
      # NOTE: cygpath による Windows 分岐は対象外なので移植していない
      ##############################################################
      if command -v go &>/dev/null; then
        _go_bin="$(go env GOPATH)/bin"
        case ":''${PATH}:" in
          *:"''${_go_bin}":*) ;;
          *) export PATH="''${_go_bin}:''${PATH}" ;;
        esac
        unset _go_bin
      fi

      ##############################################################
      # 複製元: 206_cargo_path
      ##############################################################
      if [ -f ~/.cargo/env ]; then
        # shellcheck source=/dev/null
        . ~/.cargo/env
      fi

      ##############################################################
      # 複製元: .bash/08-k8s.sh
      ##############################################################
      if command -v kubectl &>/dev/null; then
        source <(kubectl completion bash)
        complete -o default -F __start_kubectl k
      fi

      ##############################################################
      # 複製元: 250_alias の関数群
      ##############################################################
      echo-PATH() { echo "''${PATH//:/$'\n'}"; }
      echo-PATH-tr() { tr : '\n' <<<"$PATH"; }
      echo-PATH-grep() { grep -o '[^:]*' <<<"$PATH"; }

      touch-vscode-workspace() {
        local workspace_name="''${1:-workspace}"
        local workspace_file="''${workspace_name}.code-workspace"
        if [[ -f "''${workspace_file}" ]]; then
          echo "File already exists: ''${workspace_file}"
          return 1
        fi
        cat <<'__EOF__' >"''${workspace_file}"
      {
        "folders": [
          {
            "path": "."
          }
        ],
        "settings": {}
      }
      __EOF__
      }

      # ssh-copy-id が入っていない環境向けの代替
      ssh-copy-id-custom() {
        local pubkey_file=~/.ssh/id_ed25519.pub
        local ssh_host="''${1:?}"
        xargs -I{} ssh "''${ssh_host}" "echo {} >> .ssh/authorized_keys" <"''${pubkey_file}"
      }

      datetime-format() {
        local sep="''${1:--}"
        printf "%s" "$(date '+%Y'"''${sep}"'%m'"''${sep}"'%d'"''${sep}"'%H%M%S')"
      }

      hatch-env-find-python() {
        echo "$(hatch env find "''${@+"$1"}")"/bin/python
      }

      ##############################################################
      # 複製元: 201_git の関数群
      ##############################################################
      git_get_default_branch() {
        git remote show origin | head -n 5 | sed -n '/HEAD branch/s/.*: //p'
      }

      git_fetch_branch() {
        git fetch origin "''${1:?}:''${1:?}"
      }

      git_fetch_base() {
        git_fetch_branch "$(git_get_default_branch)"
      }

      git_push_set_upstream() {
        local remote="''${1:-origin}"
        local git_branch_name
        git_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -n "''${git_branch_name}" ]]; then
          git push --set-upstream "''${remote}" "''${git_branch_name}"
        fi
      }

      # 直前のコミットが WIP なら reset --soft してから commit し直す
      git_commit_WIP() {
        local msg=""
        msg="$(git log -1 --format=%s | tr -d '\n')"
        if [[ "''${msg}" =~ ^WIP ]]; then
          git reset --soft HEAD~1
          git commit -m "''${msg}"
        else
          git commit -m "WIP: temporarily commit"
        fi
      }

      git_branch_cleanup() {
        local main_branch="''${1:-"$(git_get_default_branch)"}"
        git switch "''${main_branch:?}" \
          && git fetch --prune \
          && git pull \
          && git branch --merged | grep -v '\*' | grep -v "''${main_branch:?}" | xargs git branch -d
      }

      git_branch_cleanup_force() {
        local main_branch="''${1:-"$(git_get_default_branch)"}"
        git switch "''${main_branch:?}" \
          && git fetch --prune \
          && git pull \
          && git branch | grep -v '\*' | grep -v "''${main_branch:?}" | xargs git branch -D
      }

      git_fetch_pull_request() {
        local pr_num="''${1:?}"
        git fetch origin "pull/''${pr_num}/head:pr''${pr_num}"
      }

      c-func() {
        git commit -m "$*"
      }

      ##############################################################
      # 複製元: 252_alias_mise
      # NOTE: 日次 pin は flake.lock が担うので移植していない。
      #       手動で固定したいときのために関数だけ残す。
      ##############################################################
      _mise_lock_to_current() {
        # shellcheck disable=SC2046
        mise use "$@" --pin $(mise ls --current --json | jq -r 'to_entries[] | "\(.key)@\(.value[0].version)"')
      }

      mise_lock_to_current_global() {
        _mise_lock_to_current -g
      }

      ##############################################################
      # 複製元: 253_alias_terminal_mux
      # NOTE: 参照先は Stage 3 で ~/.config/tmux/ へ配置したものに書き換えている
      ##############################################################
      tss() {
        local session_name="''${1:?}"
        tmux -f ~/.config/tmux/interactive_shell.tmux.conf new -s "''${session_name}"
      }

      tmux-cwd() {
        tmux command-prompt -I "$PWD" -p "New session dir:" "attach -c %1"
      }

      screen-kill-session() {
        screen -X -S "$1" kill
      }

      z() {
        local _shell_path=""
        if _shell_path=$(command -v fish); then
          : # do nothing
        elif _shell_path=$(command -v zsh); then
          : # do nothing
        else
          zellij "$@"
          return
        fi
        SHELL="''${_shell_path}" zellij "$@"
      }

      zss() {
        local session_name="''${1:?}"
        local _session_line
        if _session_line=$(zellij list-sessions | grep "''${session_name}"); then
          if [[ "''${_session_line}" =~ EXITED ]]; then
            zellij delete-session "''${session_name}"
            z -s "''${session_name}"
          else
            echo "Already running! Run 'zellij attach ''${session_name}' to attach to it."
          fi
        else
          z -s "''${session_name}"
        fi
      }

      ##############################################################
      # 複製元: 254_alias_fzf
      # NOTE: 元のガードは fish 構文の `not` で書かれており bash では
      #       常に偽 (= 一度も発火しない死んだコード) だった。`!` に修正。
      ##############################################################
      cdrepo() {
        if ! command -v ghq &>/dev/null; then
          echo "ghq is not installed"
          return 1
        fi
        if ! command -v fzf &>/dev/null; then
          echo "fzf is not installed"
          return 1
        fi

        local ghq_list repodir ghq_root
        ghq_list=$(ghq list) \
          && repodir=$(fzf -1 +m <<<"$ghq_list") \
          && ghq_root=$(ghq root) \
          && cd "''${ghq_root:?}/''${repodir:?}" || return
      }

      ##############################################################
      # 複製元: 299_ssh_agent
      # 1password などで既に ssh-agent が動いていれば何もしない。
      #
      # NOTE: 元のコードには ssh-add の存在確認が無く、ssh-add が無い環境では
      #       起動のたびにエラーが出ていた。ガードを追加している。
      ##############################################################
      if command -v ssh-add &>/dev/null; then
        SSH_AGENT_FILE="''${HOME}/.ssh-agent"

        if ! ssh-add -l >/dev/null 2>&1 && test -f "''${SSH_AGENT_FILE}"; then
          # shellcheck disable=SC1090
          source "''${SSH_AGENT_FILE}"
        fi

        if ! ssh-add -l >/dev/null 2>&1; then
          if [[ -z "''${SSH_AGENT_PID:-}" ]]; then
            ssh-agent >"''${SSH_AGENT_FILE}"
            # shellcheck disable=SC1090
            source "''${SSH_AGENT_FILE}"
          fi

          if [ -f "''${HOME}/.ssh/id_ed25519" ]; then
            ssh-add "''${HOME}/.ssh/id_ed25519"
          fi
        fi
      fi

      ##############################################################
      # マシンローカルの環境変数。home-manager の管理下には置かない。
      #
      # そのマシンでしか使わない API キーなど、tracked にできない値の置き場。
      # home.sessionVariables は使わないこと。あれは /nix/store 経由で
      # ~/.config/environment.d/ へ配置されるので、値が誰でも読める場所と
      # tracked な .nix の両方に残る。
      #
      # 形式 (fish 側のローダと一致させた厳格なサブセット):
      #   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
      #   - # 始まりはコメント、空行は無視
      #   - クォートしない。= の後ろは行末までそのまま値
      #   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
      #
      # flake の shellHook でやっている `set -a; . ./.env; set +a` とは
      # 意味が違う。あちらは値を展開・実行するが、fish 側でそれを再現できない
      # ので展開しない方に揃えてある。
      #
      # export "KEY=VALUE" は引数を再スキャンしないため展開が起きず、fish 側と
      # 挙動が一致する。識別子で始まる行だけに絞ってあるのは、壊れた行が
      # 混ざってもシェル起動のたびにエラーを出さないため。
      ##############################################################
      _env_file="''${XDG_CONFIG_HOME:-''${HOME}/.config}/pjp/env"
      if [ -f "''${_env_file}" ]; then
        while IFS= read -r _line || [ -n "''${_line}" ]; do
          if [[ "''${_line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # shellcheck disable=SC2163
            export "''${_line}"
          fi
        done <"''${_env_file}"
        unset _line
      fi
      unset _env_file

      ##############################################################
      # 複製元: .bashrc 末尾
      # マシンローカルの逃げ道。home-manager の管理下には置かない。
      #
      # 上の ~/.config/pjp/env より後に読む。あちらは値 (データ) 専用で、
      # こちらは任意のコードを書ける復旧経路。順序を入れ替えると
      # 逃げ道から env の値を上書きできなくなる。
      ##############################################################
      _common_shellrc="''${HOME}/.common_shellrc.sh"
      if [ ! -f "''${_common_shellrc}" ]; then
        touch "''${_common_shellrc}"
      fi
      # shellcheck disable=SC1090
      . "''${_common_shellrc}"
      unset _common_shellrc
    '';
  };
}
