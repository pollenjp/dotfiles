# herdr --remote で attach し直しても ssh-agent を使えるようにする — 設計 (TKT-224)

- チケット: [TKT-224](https://app.notion.com/p/herdr-remote-hr-attach-herdr-ssh-agent-ssh-rc-ssh-agent-sock--3fe79149a66f8169b3f9ef9b5fa85819)
  (集約ハブの会話は [TKT-241](https://app.notion.com/p/herdr-remote-detach-attach-ssh-agent-herdr-ssh-agent-TKT-2-3ff79149a66f815ba94bc798b0000075))
- 方針は 2026-10-20 にユーザーが承認した。この文書はその書き写しと、実装に要る細部 (「実装の細部」と「こちらの判断」)
- 図つきの同じ設計: ハブの cc-page 0001 (全体)・0002 (環境変数で見分ける仕組み・確認用の接続・回線断)・
  0003 (session ごとの固定名と、具体的な名前で追う場面。最新の形)。0001 の「接続元のアドレスで見分ける」と
  0002 の「固定名は 1 つ」は、0003 の形に置き換わった
- lavie の sshd の `AcceptEnv` は nixos-config の別の PR (TKT-255、pollenjp/nixos-config#9) が全 NixOS ホストに入れる
- 関連: ADR 008 (ssh 先で herdr を開くときだけ固定名を張り替える)、ADR 022 (手元の 1Password も固定名へ)、
  TKT-24 (ADR 008 を入れた)、TKT-221 (setup の取得を gh へ逃がした)。決定の記録は ADR 025

## 背景と意図

ユーザーの依頼 (原文):

> herdr --remote で繋いだ後、 detach してから再び herdr --remote で attach してもユーザーは意識せず ssh-agent が使える状態が望ましい。
> 少なくとも1つの ssh connection でssh-agentが有効なものがあればそれを借りて使えるようにしたい。
> ただし、切断前の ssh connection が生き続けている場合はそのコネクションを優先的に使う。一度 detach するなどをはさみ既存のconnectionではssh-agentを解決できない場合に限り、同一ユーザーに対して同一マシンからsshされているコネクションを探しそれを借用できるような仕組みが望ましい。
> 同一ユーザーに対して同一マシンといっているのは、同一ユーザーを他の人と共有するような環境があった場合に変な誤作動を起こさないための保険 (難易度が高そうなら後回しでよい。)
> ※注意: 1password の ssh を使うため herdr --remote する場合は windows 側の herdr を叩かないといけないため、明示的に `herdr.exe` を叩くこと。

設計の途中でユーザーが足したこと (原文):

> 接続元のアドレスで分岐するの微妙かも。。。むしろ herdr を起動するときの ssh 接続で client 側から環境変数を設定する仕組みってなかったっけ？特定の環境変数をクライアントから与えられているかどうか。それが一致しているかどうかで検知するのはどうだろうか？

> (固定名を session ごとに) 分ける。ただし、例えば default と s2 が別々の固定名を持っていたとしても、どちらも切断されており、 ssh-agent を保っているのが他に一つだけのような状況では、その一つをどちらも指すようなものであって欲しい。

> 今回の案を撮った場合、自分が設置するsshサーバー系全部 `AcceptEnv PJP_SSH_CLIENT` を貼って置く必要があるんだな。
> この環境変数がOnになっていない場合、 starship とかで表示させて気付けるようにできるとよいのだけどなぁ～

承認のあとに指揮役が足したこと (nixos-config の子が確かめた結果から。2026-10-20):

- 展開されていない値 (`%` を含む) は「届いていない」と同じに扱う。OpenSSH 10.0 より古い ssh (WSL の `/usr/bin/ssh` は
  9.6p1) は `SetEnv` の token を展開せず、みな同じ文字列 `%u@%L` を送るので、そのままだと別のマシン同士が
  「同じマシン」に見えてしまうため
- 同じ PC でも、Windows の ssh.exe (`polle@PJP-RAIDEN` の見込み) と WSL の Linux の ssh (nix の OpenSSH 10.5 なら
  `pollenjp@pjp-raiden`) では値が違い、別のマシンとして扱われる。hr (herdr.exe) と WSL の `ssh` (既定は ssh.exe への
  ラッパー) は同じ ssh.exe を通るので揃う。この違いは README に一言書く

### なぜ今は壊れるか (herdr 0.9.1 の source と lavie・Windows の実測。2026-10-20)

- Windows の `herdr.exe --remote lavie.local` は、remote で
  `ssh -C -F <一時 config> -T lavie.local "printf …; exec /home/pollenjp/.nix-profile/bin/herdr remote-client-bridge"`
  を打つ (`src/remote/attach.rs` の `bridge_command_with_idle_timeout`)。パスはログイン shell の `command -v herdr` で
  見つけた絶対パス (`remote_binary_on_path_any`)。fish の `exec` は関数を通らないので、`herdr` 関数 (ADR 008 の固定名を
  渡す役) は走らない。named session なら `herdr --session s2 remote-client-bridge`
- bridge は server が居なければ `spawn_server_daemon()` で起動し (`src/remote/host.rs`)、server は bridge の env
  (= その接続の forward された socket) を継ぐ。pane は server の env を継ぐ (`src/pane.rs` が消すのは `WT_SESSION` など
  数個で、`SSH_*` は消さない)
- detach で Windows の herdr.exe が終わると ssh の接続が閉じ、sshd が socket を消す。pane は agent を失う
- lavie の実測: default の server (pid 2838、10/18 21:54 起動) と pane 14 個は、もう無い
  `~/.ssh/agent/s.0NdPnuXkIu.sshd.UtPGyd8N0F` を持つ。s2 の server (pid 1034895、今日 15:28 起動) は今の s2 の hr 接続の
  socket を持つ。固定名 `~/.ssh/agent.sock` は 10/18 07:23 に張られた、もう無い socket を指している
- Windows の OpenSSH では herdr は ControlMaster を使わないので、ssh を打つたびに別の接続になる。attach のたびに、
  bridge の前に確認用の短い接続 (`command -v herdr`・候補の列挙・`status client --json` など) が何本か張られ、
  どれも agent を forward する (Windows の ssh の設定で `ForwardAgent yes`)
- Windows の herdr.exe は 0.9.2-preview、lavie の herdr は 0.9.1 (nixpkgs)。Windows の ssh.exe は OpenSSH_for_Windows_10.0p2
- lavie の sshd: OpenSSH 10.5p1、PermitUserRC は既定 (yes)、authorized_keys にオプション無し、X11Forwarding no、
  ClientAliveInterval 未設定、`AcceptEnv` 無し (既定は何も受け取らない)

## ゴール

1. `herdr.exe --remote lavie.local` で attach → detach → attach し直したあと、herdr の pane で `ssh-add -l` が鍵を返す
2. 切断前の接続が生きていて同じマシンなら、それを使い続ける
3. 固定名の先が死んだら、同じマシンから来ている生きている接続を借りる (別のマシンの接続は借りない)
4. 固定名は herdr の session ごとに持つ。どの session の固定名も同じ規則で借りるので、生きている接続が 1 本なら全部がそれを指す
5. 覗くだけの 2 本目の ssh を開いて閉じても、herdr の中の agent が壊れない (ADR 008 の性質)
6. `PJP_SSH_CLIENT` が届いていない ssh の shell と herdr の pane では、starship のプロンプトで気づける
7. lavie の前で開いたときの 1Password の挙動 (ADR 022) と、WSL の手元の挙動を保つ

## 非ゴール

- 今動いている server を止めずに直すこと。適用したあと、ユーザーが都合のよいときに 1 回作り直す (README に手順を書く)
- lavie 以外の ssh サーバーに `AcceptEnv` を入れること (警告を見て都度足す)
- dotfiles-private を変えること
- OpenSSH 10.1 より古いホスト (socket が `/tmp/ssh-*/`) で、接続が閉じたことを見張ること
- macOS の remote で見張ること (systemd が無い)
- `PJP_SSH_CLIENT` のなりすましを防ぐこと (誤作動を防ぐ保険であって、守りの仕組みではない)

## アンチゴール (技術的に動いても失敗とみなすもの)

- 覗くだけの接続や attach の確認用の短い接続が固定名を奪い、閉じると herdr の中の agent が切れる
- 別のマシン (`PJP_SSH_CLIENT` の値が違う・届いていない) の接続の agent を、見張りが勝手に借りる
- ある session の attach が、ほかの session の固定名を動かす
- `~/.ssh/rc` や bridge の stdout に 1 byte でも書く (git over ssh・scp・herdr の通信を壊す)
- 返事をしない socket (回線断で sshd に残った接続) で、attach・見張り・ログイン・プロンプトが固まる
- 誰も繋いでいないのに鍵が使える (remote に agent を置く・ローカルの鍵へ倒れる)
- プロンプトを出すたびに agent へ問い合わせる (`ssh-add` を打つ)

## 設計 (承認済み)

### 部品

| 部品 | 役割 |
| --- | --- |
| herdr を包む実行ファイル | home-manager の herdr を、本物の herdr を exec する script で包む (`~/.nix-profile/bin/herdr` がこれになり、hr の bridge もここを通る)。server を起動しうる呼び出し (herdr 本体・`session attach`・`remote-client-bridge`) では、`SSH_AUTH_SOCK` をその session の固定名にしてから exec する。attach する呼び出しでは、その接続を「開いた接続」として向け先の script に渡す |
| 向け先を決める script | session ごとの固定名を、今の先・開いた接続・記録にある接続から選んで張り替える。手で打つ `ssh-agent-link` (今の接続へ強制で向ける逃げ道) もこれ |
| `~/.ssh/rc` | sshd が接続のたびに走らせる。forward された socket があれば、socket のパスと `PJP_SSH_CLIENT` の値と開いた時刻を記録に書くだけ (張り替えない) |
| 見張り (systemd の user の path unit) | `~/.ssh/agent` と記録の場所に変化があると script を呼び、全部の固定名を見直す。接続が閉じたときに向け直せるのはこれだけ |
| ssh の設定 (クライアント) | `SetEnv PJP_SSH_CLIENT=%u@%L` を WSL・Linux・macOS の Nix の ssh の設定と、Windows の `%USERPROFILE%\.ssh\config` に足す (OpenSSH 10.0 から `SetEnv` の値は token を展開する。Windows の ssh.exe は 10.0p2) |
| starship の警告 | ssh で入った shell (herdr の外) で `PJP_SSH_CLIENT` が空なら、プロンプトに警告を出す。herdr の pane では、その session の固定名の持ち主の値が空なら同じ警告を出す (pane の env には server を起こした接続の値が残るので、env ではなく持ち主の記録を見る) |

fish と bash の `herdr` 関数・`ssh-agent-link` 関数は、この実行ファイルと script に移して消す (shell ごとの二重の実装を
なくす)。init の 299_ssh_agent (固定名と 1Password の shell ではフォールバックしない) は残し、「固定名」の判定を
session ごとの固定名すべてに広げる。

### session ごとの固定名

- default の固定名は今と同じ `~/.ssh/agent.sock`。named session の固定名は `~/.ssh/agent.<session>.sock` などにする
  (名前は実装で決める。`~/.ssh` (0700) に置く。`~/.ssh/agent/` は sshd と ssh-agent の場所なので使わない)
- session の名前は、包む実行ファイルが引数 (`--session <名前>`・`session attach <名前>`) から、無ければ `HERDR_SESSION`
  から、それも無ければ default として決める
- 持ち主 (固定名を張ったときの開いた接続の `PJP_SSH_CLIENT`) は固定名ごとに持つ
- pane の中から `herdr --session <別の名前>` で新しい server を起こしたときの固定名の向け先は実装で決める
  (案: 呼んだ pane の固定名と同じ先・同じ持ち主で張る)

### 向け先の決め方

| きっかけ | その固定名の今の先 | 決め方 |
| --- | --- | --- |
| herdr を開いた (attach) | 生きていて、開いた接続と同じマシン | 変えない (切断前の接続を優先する) |
| herdr を開いた (attach) | 死んでいる・持ち主が分からない・別のマシン | 開いた接続へ向け、持ち主を開いた接続の値にする |
| 接続が増えた・減った (見張り) | 生きている | 何もしない (覗くだけの接続は奪わない) |
| 接続が増えた・減った (見張り) | 死んでいる | 持ち主と同じ値の、生きている接続のうち一番古いものを借りる (attach の確認用の短い接続を避けるため)。無ければ dangling のまま |
| 手で `ssh-agent-link` | 何でも | 今の session の固定名を今の接続へ強制で向ける |

- attach は開いた session の固定名だけを動かす。見張りは全部の固定名を見直す
- 「生きている」: `ssh-add -l` が 1 秒以内に 0 か 1 を返す (回線断で返事をしない socket で固まらない。ADR 008 の案 B の実測)
- 「同じマシン」: `PJP_SSH_CLIENT` の値が同じ。値が空 (届いていない) の接続は、どの接続とも同じマシンとみなさない
  (見張りが借りることも、借りられることもない。attach の向け直しは値が空でも効く)
- 「一番古い」: rc が記録した開いた時刻で比べる
- 今の固定名 (この変更の前に張られたもの) は持ち主が分からないものとして扱う
- 手元の 1Password (`~/.1password/agent.sock`。ADR 022) は「手元」という値として同じ規則に載せる。
  `SSH_CONNECTION` が無く `SSH_AUTH_SOCK` が 1Password の socket の shell から開いたら、手元から開いたことにする
  (1Password の socket は場所が決まっているので、生死を確かめずに張る。ADR 022 の案 F)
- 開いた接続として渡さないもの (ADR 008 の `ssh-agent-link` が張らないもの): `SSH_AUTH_SOCK` が socket でない (`ssh -a`)・
  固定名そのもの (pane の中)・`SSH_AGENT_PID` が入っている (フォールバックのローカル agent)。この場合も、ssh 先なら
  `SSH_AUTH_SOCK` は固定名にして渡す (ADR 008「ssh 先では forward の無い接続からでも固定名を渡す」)
- 確認用の短い接続で打たれる `status client --json` などでは、向け先を決め直さない
- 張り替えは一時名の symlink を rename で入れ替え、固定名が消える瞬間を作らない
- script と rc は stdout に何も書かない

### `~/.ssh/rc`

- sshd(8) の SSHRC のとおり、X11 の cookie が渡されたら xauth へ渡す (例どおり)。lavie は X11Forwarding no だが、
  ほかのホストのために入れる
- subsystem (sftp) と ForceCommand では sshd が走らせない (`session.c` の `do_rc_files`)。走らせ方は
  `$SHELL -c '/bin/sh ~/.ssh/rc'` で、rc の stdout はそのセッションの stdout
- 記録の形と場所は実装で決める (`~/.ssh/agent/` は使わない。ssh-agent は起動のとき、1 時間より古い死んだ socket を
  そこから消す (`misc-agent.c` の `agent_cleanup_stale`。消すのは socket だけ))

### 今動いている server

固定名を持たない server (今の default と s2) は、作り直すまで今のまま。README に、適用したあと 1 回
`herdr server stop` (named session は `herdr session stop <名前>`) して hr で開き直す手順を書く。Claude Code の pane は
herdr の native agent session restore で会話へ戻れる。

## 実装の細部 (決まったこと)

### 1. 名前と置き場所

| もの | 名前・場所 |
| --- | --- |
| 向け先を決める script | `nix/pkgs/pjp-agent-link/pjp-agent-link.sh` (`pjp-agent-link`。writeShellApplication) |
| 手で打つ逃げ道 | `ssh-agent-link` (同じ package の `bin/`。`pjp-agent-link link` を呼ぶ) |
| herdr を包む実行ファイル | `nix/pkgs/pjp-agent-link/herdr.sh` を `bin/herdr` に置き、`pkgs.herdr` の残り (補完・skill) を symlinkJoin で並べる (`nix/pkgs/pjp-agent-link/herdr.nix`) |
| home の module | `nix/home/modules/agent-link.nix` (包んだ herdr と script を入れ、`~/.ssh/rc` と見張りの unit を置く) |
| 固定名 | default は `~/.ssh/agent.sock`、named session は `~/.ssh/agent.<session>.sock` |
| 記録の場所 | `~/.local/state/pjp-agent-link/` (0700)。`conn/<socket の basename>` (接続ごと)・`owner/<session>` (固定名ごとの持ち主)・`log` (張り替えの記録)・`lock`・`tmp/` |
| 見張りの unit | `pjp-agent-link-watch.path` と `pjp-agent-link-watch.service` (Linux だけ) |
| 手元の値 | `local` (`%u@%L` の形にならない値) |

- 記録の場所は `XDG_STATE_HOME` を見ずに `$HOME/.local/state` に固定する。rc (sshd から)・見張り (systemd から)・
  プロンプト (shell から) で env が違っても、同じ場所を読むため
- 接続の記録は 1 接続 1 ファイルで、中身は `sock=<パス>`・`client=<値>`・`opened=<UNIX 時刻>` の 3 行。名前は socket の
  basename (OpenSSH 10.1 からは `s.<hash>.sshd.<乱数>`)。`tmp/` に書いてから `conn/` へ rename する
  (見張りが書きかけを読まない。rename は 1 回の inotify の知らせになる)
- 持ち主は 1 行のファイル。無い・空は「持ち主が分からない」(同じマシンとみなさない) として同じに扱う

### 2. `PJP_SSH_CLIENT` の値の扱い

- 空・`%` を含む (OpenSSH 10.0 より古い ssh が token を展開せずに送った)・制御文字を含む・`local` と同じ、のどれかは
  「届いていない」として空にする。rc・attach・`ssh-agent-link`・starship のどれも同じ扱い
- 大文字小文字は揃えない (そのまま比べる)。Windows の ssh.exe と WSL の Linux の ssh はユーザー名から違う
  (`polle` と `pollenjp`) ので、揃えても同じにならない

### 3. 包む実行ファイルが見る引数

`--` より前の引数から `--session <名前>`・`--session=<名前>` を抜いて決める。

| 呼び出し | 扱い |
| --- | --- |
| `herdr` (サブコマンドなし。`--session` だけは付いてよい)・`herdr session attach <名前>`・`herdr remote-client-bridge [...]` | attach (向け先を決め直し、`SSH_AUTH_SOCK` を固定名にする) |
| `herdr server` (それだけ。headless の server を起こす) | 起動だけ (`SSH_AUTH_SOCK` を固定名にする。決め直さない) |
| それ以外 (`status`・`pane`・`server stop`・`--remote`・`--machine`・`--help`・`--version` など) | 何もしない (そのまま exec) |

- `--remote` はこのマシンの herdr が ssh を打つ側で、こちらの server は起こさない。`server live-handoff`・`update --handoff`
  は動いている server が新しい server を起こす (server の env を継ぐ) ので、何もしない
- session の名前は herdr と同じ規則 (英数字と `.`・`_`・`-`、64 byte まで、`.`・`..` を除く。`default` は default) で
  確かめ、外れたら何もしない (herdr がエラーにする)
- 向け先の script は `</dev/null` で呼び、stdout は `$(…)` で受け、stderr は捨てる。bridge の stdin は herdr の通信なので、
  script に 1 byte も読ませない。script が失敗・時間切れ (10 秒) でも、元の env のまま herdr を exec する
- PATH は変えない (server と pane に継がれる)。script と本物の herdr は store の絶対パスで呼ぶ

### 4. `pjp-agent-link` のサブコマンド

| サブコマンド | 呼ぶもの | すること |
| --- | --- | --- |
| `open attach <session>` / `open start <session>` | 包む実行ファイル | 呼んだ env から「開いた接続」を決め (下の表)、attach なら決め直す。`SSH_AUTH_SOCK` に入れるパスを stdout に 1 行出す (変えないときは何も出さない) |
| `watch` | 見張りの service | 死んだ socket の記録を消し、全部の固定名を見直す。`~/.ssh/agent` と `conn/` の中身が始めと終わりで同じになるまで繰り返す (5 回まで) |
| `link [<session>]` | `ssh-agent-link` (手で打つ) | 今の session (引数・`HERDR_SESSION`・default の順) の固定名を、この shell の接続へ強制で向ける |
| `rc` | `~/.ssh/rc` | X11 の cookie を xauth へ渡し、forward された socket があれば記録を書く。stdout は捨てる |
| `status` | 人 | 固定名ごとの先・生死・持ち主と、記録にある接続を出す |

「開いた接続」の決め方:

| 呼んだ shell | 開いた接続 | `SSH_AUTH_SOCK` に入れるもの |
| --- | --- | --- |
| `SSH_AUTH_SOCK` が固定名 (herdr の pane) | 別の session なら、その固定名の先と持ち主 (pane の固定名と同じ先・同じ持ち主で張る)。同じ session なら無し | 開く session の固定名 |
| `SSH_CONNECTION` があり、`SSH_AUTH_SOCK` が socket で `SSH_AGENT_PID` が空 | その socket と `PJP_SSH_CLIENT` | 開く session の固定名 |
| `SSH_CONNECTION` があるが、上に当たらない (`ssh -a`・フォールバックの agent) | 無し | 開く session の固定名 |
| `SSH_CONNECTION` が無く、`SSH_AUTH_SOCK` が `~/.1password/agent.sock` | 1Password の socket と `local` | 開く session の固定名 |
| それ以外 (WSL の手元など) | 無し | 何も入れない (変えない) |

### 5. 張り替えの排他

決め直しは、`ssh-add` で生死を見る間は lock を持たず、張り替える直前に lock (`flock -w 5 ~/.local/state/pjp-agent-link/lock`)
を取って「決めたときの先と持ち主のままか」を見てから入れ替える。変わっていたら決め直す (3 回まで)。見張りと attach が
同時に走っても、片方が古い見立てで上書きしない (別のマシンから開いた直後の固定名を、見張りが前の持ち主の接続へ戻さない)。

### 6. 見張りの unit

- `PathChanged=%h/.ssh/agent` と `PathChanged=%h/.local/state/pjp-agent-link/conn`。ディレクトリの中でファイルが
  できた・消えた・rename されたら service (Type=oneshot、`pjp-agent-link watch`) を起こす
- path unit は service が走っている間の知らせを見ない。watch は始めと終わりで中身を比べて繰り返すので、その間に
  閉じた接続も拾う (終わりの比べから unit が見張りに戻るまでの短い間に起きたものは、次の知らせまで拾わない)
- Linux の全ホストに置く (WSL の手元では何も起きない)。macOS には置かない

### 7. ssh の設定

- Nix の `~/.ssh/config`: `Include config.d/*.ssh_config` の後ろに `Host *` の `SetEnv PJP_SSH_CLIENT="%u@%L"`
  (home-manager の `matchBlocks."*".setEnv`)
- Windows の `config` (bootstrap-windows-ssh-config.sh の `config_body`): 同じく Include の後ろに `Host *` と `SetEnv`。
  前回置いた中身と同じなら、正本の更新として上書きされる
- ssh は最初に当たった `SetEnv` の行だけを使う (後ろの行は足されない)。config.d の Host に自分の `SetEnv` がある
  接続先では、そこに `PJP_SSH_CLIENT=%u@%L` を足さないと届かない (README に書く)

### 8. starship

`nix/files/starship.toml` に `[custom.pjp_ssh_client]` を足す。`when` は `sh` で、`ssh-add` も外のコマンドも呼ばずに判定する
(固定名の持ち主は `read` で読む)。出すのは `⚠ PJP_SSH_CLIENT なし` (黄色)。

| shell | 警告を出すとき |
| --- | --- |
| `SSH_AUTH_SOCK` が固定名 (herdr の pane) | その固定名の持ち主が空・無い |
| `SSH_CONNECTION` がある (ssh で入った shell) | `PJP_SSH_CLIENT` が空・`%` を含む |
| それ以外 | 出さない |

## 確かめ方

- 向け先の決め方: stub の `ssh-add` と python で bind した本物の unix socket、偽の HOME で、上の表と下の場面を回す
  nix の check (ADR 008・022 の検証と同じ形)
- rc: stdout が空であること・DISPLAY と cookie を渡したときに xauth (stub) が呼ばれること・`PJP_SSH_CLIENT` を記録すること
- 包む実行ファイル: 引数をそのまま渡すこと・`remote-client-bridge` と attach の呼び出しでだけ向け先を決め直すこと・
  session ごとの固定名を `SSH_AUTH_SOCK` に入れること・WSL の手元では何も変えないこと
- starship: 値が空の ssh の shell と、持ち主の値が空の session の pane でだけ警告が出ること (プロンプトで `ssh-add` を打たない)
- ssh の設定: `ssh.exe -v` の出力で `PJP_SSH_CLIENT` を送っていること (`Setting env` の行)
- lavie での実機 (sudo の要る操作はしない):
  - branch の home を当てて試し、終わったら main の home に戻す
  - lavie の sshd (port 22) は `AcceptEnv` を持たないので、値が届かない場面 (警告・借りない) はそのまま試す
  - 値が届く場面は、ユーザー権限の一時の sshd (別の port、`AcceptEnv PJP_SSH_CLIENT`) を lavie に立て、Windows の
    `%USERPROFILE%\.ssh\config.d` に試験用の Host (その port・`ForwardAgent yes`・`SetEnv PJP_SSH_CLIENT=%u@%L`) を
    1 ファイル足して、`herdr.exe --remote <試験用の Host> --session <試験用>` で試す。終わったら一時の sshd を止め、
    試験用のファイルを消す
  - attach → pane で `ssh-add -l` → detach → attach → pane で `ssh-add -l`
  - 同じ PC から 2 つの session を開き、片方ずつ閉じたとき、両方の固定名が生きている方を指す
  - 覗くだけの ssh を開いて閉じても、固定名の先が変わらない
  - 今の default と s2 の server は止めない

| # | 場面 | 期待 |
| --- | --- | --- |
| 1 | hr で attach → detach → attach | 2 回目の attach のあと pane で鍵が並ぶ |
| 2 | 同じ PC の 2 つの session の片方を閉じる | 閉じた方の固定名は残った方の接続を借りる |
| 3 | 両方の session を閉じ、素の ssh の端末だけ開いたまま | 両方の固定名が端末の接続を指す |
| 4 | hr 中に覗くだけの ssh を開いて閉じる | どの固定名の先も変わらない |
| 5 | 返事をしない socket を固定名が指す状態で attach | 1 秒で見切って開いた接続へ移る (固まらない) |
| 6 | 別のマシン (値が違う) から default を attach | default の固定名だけが移り、ほかの session の固定名は動かない |
| 7 | 別のマシンの接続だけが生きている状態で、固定名の先が死ぬ | 借りない (dangling) |
| 8 | 値が届かない接続 (`AcceptEnv` の無い sshd) | 借りない・借りられない。プロンプトに警告 |
| 9 | lavie の前で開く (1Password) | default の固定名は `~/.1password/agent.sock` (ADR 022 と同じ) |
| 10 | WSL の手元 | 何も変わらない |
| 11 | 誰も繋いでいない | 鍵は使えない |

check の置き場所:

- `nix/tests/pjp-agent-link.test.sh` (flake の checks の `pjp-agent-link-test`。python3・flock・starship を足して流す):
  script・包む実行ファイル・rc・starship の `when` を、偽の HOME・偽の `ssh-add`・本物の unix socket で回す
- `nix/tests/agent-link.nix` (`agent-link-state`。評価時の assert): home に包んだ herdr・`~/.ssh/rc`・見張りの unit
  (Linux だけ)・ssh の `SetEnv` があり、fish と bash に `herdr`・`ssh-agent-link` の関数が無いこと
- `nix/tests/bootstrap-windows-ssh-config.test.sh` と `nix/tests/claude-herdr-skill.nix` を新しい形に合わせる

## 文書

- ADR 025 (ADR 008・022 の後続)。ADR 008・022 の冒頭の表に後続 ADR の行を足す (本文はそのまま)
- `nix/README.md`「forward された agent を固定名で見せる」を新しい形に直す (部品・session ごとの固定名・借り方・
  今動いている server を 1 回作り直す手順・`AcceptEnv` の要るサーバーと starship の警告・ssh.exe と WSL の ssh で
  値が違うこと・`pjp-agent-link status` と log)。`win/README.md` の ssh の設定の節にも `SetEnv` を一言

## こちらの判断 (ユーザーに確かめずに決めたもの)

builder check の問い (設計の「実装者に任せること」) と、実装の中で決めたもの。

- 名前: script は `pjp-agent-link`、固定名は `~/.ssh/agent.<session>.sock`、記録は `~/.local/state/pjp-agent-link/`、
  手元の値は `local` (1 節)。固定名を `~/.ssh` の直下に並べるのは、default の今の名前 (`~/.ssh/agent.sock`) を変えずに
  済み、0700 の場所のままだから
- 包む実行ファイルが「attach する呼び出し」とみなす範囲は 3 節の表。herdr 0.9.1 で server を起こすのは
  `auto_detect_launch` (サブコマンドなしと `session attach`) と `ensure_remote_server_running` (`remote-client-bridge`) の
  2 か所だけで、`server live-handoff` は server が新しい server を起こす (`src/server/handoff.rs`) ため
- fish・bash の `herdr` と `ssh-agent-link` の関数は消し、`ssh-agent-link` は同じ名前のコマンドにする (手で打つ名前は
  変えない)。関数を薄く残すと、関数を通る経路と通らない経路 (hr) で挙動が分かれたままになる
- 見張りは Linux の全ホストに置く。path unit は inotify を待つだけで、何も起きないホストでは動かない。要るホストだけに
  すると、ホストを足すたびに option を書き忘れる
- starship は custom module の `when` を `sh` で書く (`shell = ['sh']`。fish を起動させない)。文言は `⚠ PJP_SSH_CLIENT なし`
- Windows の `SetEnv` は、bootstrap-windows-ssh-config.sh が書く `config` に足す (config.d は dotfiles-private の正本の
  写しなので、dotfiles 側で持つ `config` に置く)。Include の後ろに置き、config.d の値を優先する
- `%` を含む値・制御文字を含む値・`local` は届いていないものとして扱い、大文字小文字は揃えない (2 節)
- 張り替えは flock で比べてから入れ替える (5 節)。lock を持つのは入れ替えの瞬間だけで、返事をしない socket を待つ間は
  持たない (attach が見張りの `ssh-add` を待たない)
- 張り替えのたびに 1 行を `~/.local/state/pjp-agent-link/log` に残す (どの接続がいつ固定名を動かしたかを後から追える。
  大きくなったら後ろの 1000 行に切り詰める)。`pjp-agent-link status` で今の状態を出す
- 包む実行ファイルは script を 10 秒で打ち切る。script の中の待ちは、生死を見る `ssh-add` 1 回 1 秒と lock の 5 秒まで
- 削除した session の固定名は残る (見張りが張り替え続けても、使うプロセスが無いので害は無い)。README に、要らなければ
  消してよいと書く
- pane の中から別の session を起こしたとき (nested を許した herdr など) は、呼んだ pane の固定名の先と持ち主を「開いた
  接続」として同じ規則に載せる (設計の案どおり)

## 実装に任せること

- 出力の文言と並び、log の 1 行の形
- テストの組み方と偽のコマンドの作り
