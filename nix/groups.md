<!-- 生成物 (dotfiles の nix/lib/host-summary/)。手で直さない -->

> 生成物。手で直さない。出し直すのは dotfiles の root で `nix eval --raw ./nix#lib.groupsDoc > nix/groups.md`。古ければ CI (flake の checks の groups-doc) が落ちる。

# 設定グループ

ホストは設定グループを 1 つ選ぶ (`mkHome` の `group`)。グループは道具の集合で、グループに入る道具の switch は全部既定で on、入らない道具は既定で off になる (dotfiles-private の ADR 109)。選び方・直し方・setup の振る舞いは [README の「設定グループ」](./README.md#設定グループ)。ここは `nix/lib/groups.nix` の表と、作り物のホストの値から作った生成物。登録したホストごとの図 (グループの入れ子の領域と、ホストごとの囲みの線) は dotfiles-private の `docs/hosts/` にある (dotfiles-private の ADR 093)。

## グループ

| グループ | 使う PC と何を入れるか | 入る道具の switch |
| --- | --- | --- |
| `minimum` | どの PC にも初めからあってほしいもの (基本の道具と、証明書の束・掃除)。ほとんどのホストはこれにして、使う道具をホストのファイルで足す (グループを書かないホストもこれ) | 2 / 28 |
| `all` | 道具を全部入れる (minimum の全部と、ほかの道具の switch の全部)。環境が合わない道具 (WSL だけ・win/ を配るマシンだけ・Linux だけなど) は、そのマシンでは入らない。道具の前提 (1Password の署名の鍵・Windows の側の SSH の中継・Notion の宛先など) もそろう PC で選ぶ (README の「設定グループ」) | 28 / 28 |

`minimum` ⊂ `all`。グループを書かないホストは `minimum`。

## 基本の道具 (switch なし)

どのグループにも入り、いつも入る (`minimum` の中)。外したいホストが出たら、そのとき switch を足す。

- shell (fish・bash)
- starship (prompt)
- git
- ssh
- vim と neovim
- tmux と zellij
- CLI (rg・fd・jq・fzf・gh・ghq など)
- mise
- direnv
- python

## 道具の switch と、グループに入るか

on の道具は、そのグループのホストで既定で on になる。ただし効く条件 (そのマシンの環境と、頼るほかの道具) が合わなければ、グループに入っていても既定で off になる (要約の表と図では「–」)。グループに入らない道具も、ホストのファイルで on にできる。

| 道具 | option (`dotfiles.…`) | `minimum` | `all` | 効く条件 |
| --- | --- | --- | --- | --- |
| .exe の起動の記録 (WSL) | `wsl.exeExecTrace.enable` | off | on | `wsl.enable` |
| eth0 の MTU の見張り (WSL) | `wsl.mtuGuard.enable` | off | on | `wsl.enable` |
| 証明書の束を OS の信頼ストアに寄せる | `osCaBundle.enable` | on | on |  |
| 使わない store path・mise の版の掃除 | `cleanup.enable` | on | on |  |
| Claude Code 一式 | `claude.enable` | off | on |  |
| herdr | `herdr.enable` | off | on |  |
| herdr-core (hc) | `herdrCore.enable` | off | on | Linux (macOS でない) |
| systemd の linger (ログアウトしても user の service を止めない) | `linger.enable` | off | on | 既定は `herdrCore.enable` に従う・Linux (macOS でない) |
| Windows の Claude Code | `wsl.windowsFiles.claudeCode.enable` | off | on | `wsl.windowsFiles.enable` |
| Windows の herdr・herdr-app | `wsl.windowsFiles.herdr.enable` | off | on | `wsl.windowsFiles.enable` |
| cursor-agent | `cursorAgent.enable` | off | on |  |
| T3 Code (t3 と t3code.service) | `t3Code.enable` | off | on | Linux (macOS でない)・`claude.enable` |
| Windows の T3 Code | `wsl.windowsFiles.t3Code.enable` | off | on | `wsl.windowsFiles.enable` |
| private な skill (claude-skills の clone) | `claude.privateSkills.enable` | off | on |  |
| cc-pages | `ccPages.enable` | off | on |  |
| 集約ハブ ~/h | `herdr.hub.enable` | off | on |  |
| Windows の claude-personal・claude-work | `wsl.windowsFiles.claudeAccounts.enable` | off | on | `wsl.windowsFiles.enable`・`wsl.windowsFiles.claudeCode.enable` |
| Windows の Claude Desktop (MSIX) | `wsl.windowsFiles.claudeDesktop.enable` | off | on | `wsl.windowsFiles.enable` |
| Notion Dev Tracker | `claude.devTracker.enable` | off | on |  |
| Dev Tracker の見回り役 | `claude.devTracker.inbox.enable` | off | on | Linux (macOS でない) |
| 1Password | `onePassword.enable` | off | on | WSL なら `wsl.onePassword.windowsUserName` (既定は `wsl.windowsUserName`) が null でない (WSL でなければいつも) |
| op-reason の SSH の中継 | `opReason.sshRelay.enable` | off | on | `wsl.enable`・`wsl.windowsFiles.enable` が false・`onePassword.enable` |
| ntn (Notion の CLI) | `ntn.enable` | off | on |  |
| Windows の ntn | `wsl.windowsFiles.ntn.enable` | off | on | `wsl.windowsFiles.enable` |
| Windows の Tailscale | `wsl.windowsFiles.tailscale.enable` | off | on | `wsl.windowsFiles.enable` |
| Windows の sshd (Tailscale から鍵で入る) | `wsl.windowsFiles.sshd.enable` | off | on | `wsl.windowsFiles.enable` |
| Windows の type-clipboard | `wsl.windowsFiles.typeClipboard.enable` | off | on | `wsl.windowsFiles.enable` |
| git の名前とメール (pollenjp・pollenjp-sub) | `git.identity.enable` | off | on |  |

## 作り物のホストの値

`nix/lib/group-examples.nix` のホスト (値は作り物)。**太字**はホストで決めた値。「–」は効かない (値は on か、グループに入るが、環境の条件か効く条件が合わない)。

- `minimum`: minimum (グループの既定のまま。WSL で win/ を配る)
- `minimum-claude`: minimum に Claude Code だけを足したホスト (`claude.enable = true`。WSL で win/ を配る)
- `all-wsl`: all (WSL で win/ を配る)
- `all-linux`: all (WSL でない Linux)

| 道具 | `minimum` | `minimum-claude` | `all-wsl` | `all-linux` |
| --- | --- | --- | --- | --- |
| グループ | **`minimum`** | **`minimum`** | **`all`** | **`all`** |
| 環境 | WSL · win/ を配る | WSL · win/ を配る | WSL · win/ を配る | Linux (WSL でない) |
| .exe の起動の記録 (WSL) | off | off | on | – |
| eth0 の MTU の見張り (WSL) | off | off | on | – |
| 証明書の束を OS の信頼ストアに寄せる | on | on | on | on |
| 使わない store path・mise の版の掃除 | on | on | on | on |
| Claude Code 一式 | off | **on** | on | on |
| herdr | off | off | on | on |
| herdr-core (hc) | off | off | on | on |
| systemd の linger (ログアウトしても user の service を止めない) | off | off | on | on |
| Windows の Claude Code | off | off | on | – |
| Windows の herdr・herdr-app | off | off | on | – |
| cursor-agent | off | off | on | on |
| T3 Code (t3 と t3code.service) | off | off | on | on |
| Windows の T3 Code | off | off | on | – |
| private な skill (claude-skills の clone) | off | off | on | on |
| cc-pages | off | off | on | on |
| 集約ハブ ~/h | off | off | on | on |
| Windows の claude-personal・claude-work | off | off | on | – |
| Windows の Claude Desktop (MSIX) | off | off | on | – |
| Notion Dev Tracker | off | off | on | on |
| Dev Tracker の見回り役 | off | off | on | on |
| 1Password | off | off | on | on |
| op-reason の SSH の中継 | off | off | – | – |
| ntn (Notion の CLI) | off | off | on | on |
| Windows の ntn | off | off | on | – |
| Windows の Tailscale | off | off | on | – |
| Windows の sshd (Tailscale から鍵で入る) | off | off | on | – |
| Windows の type-clipboard | off | off | on | – |
| git の名前とメール (pollenjp・pollenjp-sub) | off | off | on | on |
