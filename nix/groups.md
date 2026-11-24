<!-- 生成物 (dotfiles の nix/lib/host-summary/)。手で直さない -->

> 生成物。手で直さない。出し直すのは dotfiles の root で `nix eval --raw ./nix#lib.groupsDoc > nix/groups.md`。古ければ CI (flake の checks の groups-doc) が落ちる。

# 設定グループ

ホストは設定グループを 1 つ選び (`mkHome` の `group`)、グループは「どの段の道具まで入れるか」で決まる (dotfiles-private の ADR 057)。選び方・直し方・setup の振る舞いは [README の「設定グループ」](./README.md#設定グループ)。ここは `nix/lib/groups.nix` の表と、作り物のホストの値から作った生成物。登録したホストごとの図 (段の入れ子の領域と、ホストごとの囲みの線) は dotfiles-private の `docs/hosts/` にある (dotfiles-private の ADR 093)。

## グループ

| グループ | 使う PC と何を入れるか | ① エンジニアの道具 | ② AI の道具 | ③ 個人の道具 |
| --- | --- | --- | --- | --- |
| `personal` | 個人の開発用の PC。① ② ③ を全部入れる (グループを選ばないホストもこれ) | on | on | on |
| `company` | 自社の PC。① と ② を入れ、③ は要るものだけをホストで足す | on | on | off |
| `client` | 客先の PC。① だけを入れ、許可の出た道具をホストで 1 つずつ足す | on | off | off |

## 道具の switch と、グループごとの既定

グループだけを書いた (ほかの値を書かない) ホストの値。Windows の道具は `wsl.windowsFiles.enable` のマシンでだけ効く (効く条件の列)。既定が段によらない道具 (`onePassword.enable` など) は、どのグループでも off で、使うホストが入れる。

| 段 | 道具 | option (`dotfiles.…`) | `personal` | `company` | `client` | 効く条件 |
| --- | --- | --- | --- | --- | --- | --- |
| ① | WSL の手当て | `wsl.enable` | off | off | off |  |
| ① | Windows のアプリと設定 (win/) | `wsl.windowsFiles.enable` | off | off | off |  |
| ① | .exe の起動の記録 (WSL) | `wsl.exeExecTrace.enable` | off | off | off |  |
| ① | eth0 の MTU の見張り (WSL) | `wsl.mtuGuard.enable` | off | off | off |  |
| ① | 証明書の束を OS の信頼ストアに寄せる | `osCaBundle.enable` | on | on | on |  |
| ① | 使わない store path・mise の版の掃除 | `cleanup.enable` | on | on | on |  |
| ② | Claude Code 一式 | `claude.enable` | on | on | off |  |
| ② | herdr | `herdr.enable` | on | on | off |  |
| ② | herdr-core (hc) | `herdrCore.enable` | on | on | off |  |
| ② | Windows の Claude Code | `wsl.windowsFiles.claudeCode.enable` | on | on | off | `wsl.windowsFiles.enable` |
| ② | Windows の herdr・herdr-app | `wsl.windowsFiles.herdr.enable` | on | on | off | `wsl.windowsFiles.enable` |
| ② | cursor-agent | `cursorAgent.enable` | off | off | off |  |
| ② | T3 Code (t3 と t3code.service) | `t3Code.enable` | off | off | off | `claude.enable` |
| ② | Windows の T3 Code | `wsl.windowsFiles.t3Code.enable` | off | off | off | `wsl.windowsFiles.enable` |
| ②③ | private な skill (claude-skills の clone) | `claude.privateSkills.enable` | on | off | off |  |
| ②③ | cc-pages | `ccPages.enable` | on | off | off |  |
| ②③ | 集約ハブ ~/h | `herdr.hub.enable` | on | off | off |  |
| ②③ | Windows の claude-personal・claude-work | `wsl.windowsFiles.claudeAccounts.enable` | on | off | off | `wsl.windowsFiles.enable`・`wsl.windowsFiles.claudeCode.enable` |
| ②③ | Windows の Claude Desktop (MSIX) | `wsl.windowsFiles.claudeDesktop.enable` | on | off | off | `wsl.windowsFiles.enable` |
| ②③ | Notion Dev Tracker | `claude.devTracker.enable` | off | off | off |  |
| ②③ | Dev Tracker の見回り役 | `claude.devTracker.inbox.enable` | off | off | off |  |
| ③ | 1Password | `onePassword.enable` | off | off | off |  |
| ③ | op-reason の SSH の中継 | `opReason.sshRelay.enable` | off | off | off | `onePassword.enable` |
| ③ | ntn (Notion の CLI) | `ntn.enable` | on | off | off |  |
| ③ | Windows の ntn | `wsl.windowsFiles.ntn.enable` | on | off | off | `wsl.windowsFiles.enable` |
| ③ | Windows の Tailscale | `wsl.windowsFiles.tailscale.enable` | off | off | off | `wsl.windowsFiles.enable` |
| ③ | Windows の sshd (Tailscale から鍵で入る) | `wsl.windowsFiles.sshd.enable` | off | off | off | `wsl.windowsFiles.enable` |
| ③ | Windows の type-clipboard | `wsl.windowsFiles.typeClipboard.enable` | off | off | off | `wsl.windowsFiles.enable` |
| ③ | git の名前とメール (pollenjp・pollenjp-sub) | `git.identity.enable` | on | off | off |  |

## 作り物のホストの値

`nix/lib/group-examples.nix` のホスト (どれも WSL で `win/` を配る。値は作り物)。**太字**はホストで決めた値。「–」は値は on だが、効く条件が off で効かない。

- `personal`: personal (個人の PC。グループの既定のまま)
- `company`: company (自社の PC。③ の道具を足していない)
- `client`: client (客先の PC)
- `client-claude`: client に Claude Code だけを足したホスト (`claude.enable = true`)

| 道具 | `personal` | `company` | `client` | `client-claude` |
| --- | --- | --- | --- | --- |
| グループ | **`personal`** | **`company`** | **`client`** | **`client`** |
| ① エンジニアの道具 | on | on | on | on |
| ② AI の道具 | on | on | off | off |
| ③ 個人の道具 | on | off | off | off |
| ① WSL の手当て | **on** | **on** | **on** | **on** |
| ① Windows のアプリと設定 (win/) | **on** | **on** | **on** | **on** |
| ① .exe の起動の記録 (WSL) | off | off | off | off |
| ① eth0 の MTU の見張り (WSL) | off | off | off | off |
| ① 証明書の束を OS の信頼ストアに寄せる | on | on | on | on |
| ① 使わない store path・mise の版の掃除 | on | on | on | on |
| ② Claude Code 一式 | on | on | off | **on** |
| ② herdr | on | on | off | off |
| ② herdr-core (hc) | on | on | off | off |
| ② Windows の Claude Code | on | on | off | off |
| ② Windows の herdr・herdr-app | on | on | off | off |
| ② cursor-agent | off | off | off | off |
| ② T3 Code (t3 と t3code.service) | off | off | off | off |
| ② Windows の T3 Code | off | off | off | off |
| ②③ private な skill (claude-skills の clone) | on | off | off | off |
| ②③ cc-pages | on | off | off | off |
| ②③ 集約ハブ ~/h | on | off | off | off |
| ②③ Windows の claude-personal・claude-work | on | off | off | off |
| ②③ Windows の Claude Desktop (MSIX) | on | off | off | off |
| ②③ Notion Dev Tracker | off | off | off | off |
| ②③ Dev Tracker の見回り役 | off | off | off | off |
| ③ 1Password | off | off | off | off |
| ③ op-reason の SSH の中継 | off | off | off | off |
| ③ ntn (Notion の CLI) | on | off | off | off |
| ③ Windows の ntn | on | off | off | off |
| ③ Windows の Tailscale | off | off | off | off |
| ③ Windows の sshd (Tailscale から鍵で入る) | off | off | off | off |
| ③ Windows の type-clipboard | off | off | off | off |
| ③ git の名前とメール (pollenjp・pollenjp-sub) | on | off | off | off |
