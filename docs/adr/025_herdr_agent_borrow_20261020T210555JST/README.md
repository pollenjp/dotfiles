# ADR: herdr の固定名を session ごとに持ち、herdr を包んだ実行ファイル・`~/.ssh/rc`・見張りで、同じマシンから来ている生きている接続を借りる

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-20 にユーザーが承認。文面は PR でレビュー |
| 日付 | 2026-10-20 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-224](https://app.notion.com/p/herdr-remote-hr-attach-herdr-ssh-agent-ssh-rc-ssh-agent-sock--3fe79149a66f8169b3f9ef9b5fa85819)（集約ハブの会話は [TKT-241](https://app.notion.com/p/herdr-remote-detach-attach-ssh-agent-herdr-ssh-agent-TKT-2-3ff79149a66f815ba94bc798b0000075)） |
| 前提 ADR | [008_ssh_agent_stable_sock](../008_ssh_agent_stable_sock_20260909T144947JST/README.md)（固定名 `~/.ssh/agent.sock` を挟み、ssh 先で herdr を開くときだけ張り替える）、[022_one_password_outside_wsl](../022_one_password_outside_wsl_20261018T105655JST/README.md)（手元で開いたときも、そのマシンの 1Password へ張り替える） |
| 関連 (外部) | nixos-config の TKT-255（全 NixOS ホストの sshd に `AcceptEnv PJP_SSH_CLIENT` を入れる。pollenjp/nixos-config#9） |
| 運用手順 | [`nix/README.md`「forward された agent を固定名で見せる」](../../../nix/README.md#forward-された-agent-を固定名で見せる) |
| 設計 | [`docs/superpowers/specs/2026-10-20-herdr-remote-agent-borrow-design.md`](../../superpowers/specs/2026-10-20-herdr-remote-agent-borrow-design.md)（承認した設計の書き写しと、実装の細部） |

---

## 1. 背景 (Context)

ADR 008 は、ssh 先で herdr を常駐させても ssh を張り直したあとに中から agent が引けるよう、固定名
`~/.ssh/agent.sock` を挟み、fish・bash の `herdr` 関数が「herdr を開いた接続」へ張り替える形にした。

この形は、Windows の `herdr.exe --remote`（hr）で lavie へ繋ぐ今の使い方では効かない。herdr 0.9.1 の source と
lavie・Windows の実測（2026-10-20）で、次のことが分かった。

| 事実 | 出どころ |
| --- | --- |
| hr は ssh 先で `exec /home/pollenjp/.nix-profile/bin/herdr [--session <名前>] remote-client-bridge` を直に打つ。パスはログイン shell の `command -v herdr` で見つけたもので、fish の `exec` は関数を通らない | `src/remote/attach.rs`（`bridge_command_with_idle_timeout`・`remote_binary_on_path_any`） |
| bridge は server が居なければ起こし、server は bridge の env（その接続の forward された socket）を継ぐ。pane は server の env を継ぐ | `src/remote/host.rs`・`src/server/autodetect.rs`・`src/pane.rs` |
| detach で herdr.exe が終わると ssh の接続が閉じ、sshd が socket を消す。pane は agent を失う | lavie の実測（default の server と pane 14 個が、もう無い socket を持っていた） |
| Windows の OpenSSH では herdr は ControlMaster を使わず、attach のたびに bridge の前に確認用の短い接続を何本も張る。どれも agent を forward する | Windows の ssh の設定（`ForwardAgent yes`）と実測 |
| OpenSSH 10.1 からは、forward された socket は `~/.ssh/agent/s.<hash>.sshd.<乱数>` に置かれる | `misc-agent.c` |

ユーザーの依頼（原文は設計の「背景と意図」）は次のとおり。

- detach してから hr で attach し直しても、意識せずに ssh-agent が使えること
- 生きている接続が 1 本でもあれば、それを借りること。ただし切断前の接続が生きていればそれを優先し、借りるのは
  既存の接続で解決できないときだけ
- 借りるのは同じユーザーへ同じマシンから来ている接続に限る（同じユーザーを人と共有したときの誤作動を防ぐ保険）
- 設計の途中で足したこと: 同じマシンは、接続元のアドレスではなく、クライアントが送る環境変数で見分ける。固定名は
  session ごとに分けるが、どれも切断されて生きている接続が 1 本だけなら、全部がそれを指す。`AcceptEnv` の無い
  サーバーでは starship で気づけるようにする

## 2. 決定 (Decision)

**固定名を herdr の session ごとに持ち、server を起こしうる herdr の呼び出しを包んだ実行ファイルが固定名を渡す。
固定名の先は「開いた接続」か「持ち主と同じ値を名乗る、生きている一番古い接続」へ、1 本の script が向け直す。**
ADR 008 の「herdr を開いた接続だけが固定名を動かす（覗くだけの接続は奪わない）」性質は保つ。

![部品と、固定名の先を動かす 2 つのきっかけ](./plantuml/out/01_parts.svg)

### A. session ごとの固定名

| session | 固定名 | 持ち主の記録 |
| --- | --- | --- |
| default | `~/.ssh/agent.sock`（今と同じ） | `~/.local/state/pjp-agent-link/owner/default` |
| ほか（`s2` など） | `~/.ssh/agent.<session>.sock` | `~/.local/state/pjp-agent-link/owner/<session>` |

持ち主は、固定名を張ったときの開いた接続の `PJP_SSH_CLIENT`。attach は開いた session の固定名だけを動かすので、
同じユーザーを共有する人が自分の session を開いても、ほかの session の固定名は動かない。

### B. herdr を包む実行ファイル

home の `bin/herdr`（`~/.nix-profile/bin/herdr`）を、本物の herdr を exec する script にする。hr の bridge もここを通る。

| 呼び出し | すること |
| --- | --- |
| `herdr`（サブコマンドなし）・`herdr session attach <名前>`・`herdr remote-client-bridge [...]` | 向け先を決め直し、`SSH_AUTH_SOCK` をその session の固定名にして exec |
| `herdr server`（headless の server） | 決め直さずに、`SSH_AUTH_SOCK` を固定名にして exec |
| それ以外（`status`・`pane`・`server stop`・`--remote`・`--version` など） | そのまま exec |

herdr 0.9.1 で server を起こすのは `auto_detect_launch` と `ensure_remote_server_running` の 2 か所だけで、
`server live-handoff` は動いている server が新しい server を起こす（server の env を継ぐ）。

### C. 向け先の決め方

| きっかけ | その固定名の今の先 | 決め方 |
| --- | --- | --- |
| herdr を開いた（attach） | 生きていて、持ち主が開いた接続と同じ値 | 変えない（切断前の接続を優先する） |
| herdr を開いた（attach） | 死んでいる・持ち主が分からない・別の値 | 開いた接続へ向け、持ち主をその値にする |
| 接続が増えた・減った（見張り） | 生きている | 何もしない（覗くだけの接続は奪わない） |
| 接続が増えた・減った（見張り） | 死んでいる | 持ち主と同じ値の、生きている接続のうち一番古いものを借りる。無ければ dangling のまま |
| 手で `ssh-agent-link` | 何でも | 今の session の固定名を今の接続へ強制で向ける |

- 「生きている」は `ssh-add -l` が 1 秒以内に 0 か 1 を返すこと（回線断で返事をしない socket で固まらない）
- 「一番古い」は rc が記録した開いた時刻。attach の確認用の短い接続より、前からある接続を選ぶため
- 値が届いていない接続は、どの接続とも同じマシンとみなさない（見張りが借りることも、借りられることもない）。
  attach の向け直しは値が空でも効く
- 手元の 1Password（`~/.1password/agent.sock`）は持ち主 `local` として同じ規則に載せ、生死を確かめずに張る（ADR 022）
- 開いた接続として渡さないもの（ADR 008 と同じ）: forward の無い接続（`ssh -a`）・pane の中（`SSH_AUTH_SOCK` が
  固定名）・`SSH_AGENT_PID` のある shell。この場合も ssh 先なら固定名は渡す。pane の中から別の session を
  起こすときは、pane の固定名の先と持ち主を開いた接続として扱う

### D. 接続の記録は `~/.ssh/rc`

sshd が接続のたびに走らせる `~/.ssh/rc` から `pjp-agent-link rc` を呼び、forward された socket・`PJP_SSH_CLIENT`・
開いた時刻を `~/.local/state/pjp-agent-link/conn/<socket の basename>` に書く。**rc は張り替えない**（ADR 008 が
案 C を採らなかった理由の、後勝ちの害を避ける）。stdout は捨てる。X11 の cookie は sshd(8) の例どおり xauth へ渡す。

### E. 見張りは systemd の user の path unit

`pjp-agent-link-watch.path` が `~/.ssh/agent` と `conn/` を `PathChanged` で見て、`pjp-agent-link watch` を起こす。
接続が閉じたときに固定名を向け直せるのはこれだけ。Linux の全ホストに置く（macOS には置かない）。path unit は
service が走っている間の知らせを見ないので、watch は始めと終わりで中身を比べて繰り返す。

### F. 同じマシンは `PJP_SSH_CLIENT` で見分ける

各マシンの ssh が `SetEnv PJP_SSH_CLIENT=%u@%L` で自分のユーザー名とホスト名を送り、受け取る側の sshd が
`AcceptEnv PJP_SSH_CLIENT` で受け取る。`SetEnv` の値の token は OpenSSH 10.0 から展開される。

| 送る側 | 置き場所 | 値の例 |
| --- | --- | --- |
| Windows の ssh.exe（hr・WSL の `ssh`） | `%USERPROFILE%\.ssh\config`（`bootstrap-windows-ssh-config.sh`） | `polle@PJP-RAIDEN` |
| Nix の home の ssh（Linux・macOS・WSL の `/usr/bin/ssh`） | `~/.ssh/config`（`programs.ssh.settings."*"`） | `pollenjp@pjp-raiden`（10.0 以上なら） |

- 空・`%` を含む（10.0 より古い ssh は `%u@%L` のまま送る。みな同じ文字列になるので、そのままでは別のマシン同士が
  同じに見える）・制御文字を含む・`local` の値は、届いていないものとして扱う
- 大文字小文字は揃えない。同じ PC でも ssh.exe と WSL の Linux の ssh はユーザー名から違うので、別のマシンになる
- なりすましは防がない（誤作動を防ぐ保険）

### G. 値が届いていないことを starship で出す

ssh で入った shell（herdr の外）で値が空なら、herdr の pane では固定名の持ち主が空なら、プロンプトに
`⚠ PJP_SSH_CLIENT なし` を出す。pane の env には server を起こした接続の値が残るので、env ではなく持ち主の記録を見る。
判定は `sh` で、外のコマンドも `ssh-add` も呼ばない。

### H. 張り替えの排他

決め直しは、`ssh-add` で生死を見る間は lock を持たず、入れ替える直前に `flock` を取って「決めたときの先と持ち主の
まま」かを見てから、一時名の symlink を rename で入れ替える（固定名が消える瞬間を作らない）。変わっていたら決め直す。
見張りが、別のマシンから開き直された直後の固定名を、古い見立てで前の持ち主の接続へ戻さないため。

### I. shell の関数を消す

fish・bash の `herdr` 関数と `ssh-agent-link` 関数は消す（同じことを shell ごとに 2 回書かない。関数を通らない hr の
経路と挙動が分かれない）。`ssh-agent-link` は同じ名前のコマンドになる。init の `299_ssh_agent` は残し、「固定名」の
判定を `~/.ssh/agent.<session>.sock` にも広げる（pane ではローカル agent へ倒れない）。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/pkgs/pjp-agent-link/pjp-agent-link.sh`・`default.nix` | 向け先を決める script（`open`・`watch`・`link`・`rc`・`status`）と `ssh-agent-link` |
| `nix/pkgs/pjp-agent-link/herdr.sh`・`herdr.nix` | herdr を包む実行ファイル。`bin/herdr` だけを替え、補完と skill は本物の herdr の symlink |
| `nix/home/modules/agent-link.nix`（新設） | 包んだ herdr・`pjp-agent-link`・`~/.ssh/rc`・見張りの unit |
| `nix/home/modules/packages.nix` | `herdr` を外した（agent-link.nix が入れる） |
| `nix/home/modules/fish.nix`・`bash.nix` | `herdr`・`ssh-agent-link` の関数を消し、`299_ssh_agent` の判定を広げた |
| `nix/home/modules/ssh.nix` | `Host *` に `SetEnv PJP_SSH_CLIENT="%u@%L"` |
| `nix/scripts/bootstrap-windows-ssh-config.sh` | Windows の `config` に `Host *` と `SetEnv PJP_SSH_CLIENT=%u@%L` |
| `nix/files/starship.toml` | `[custom.pjp_ssh_client]` |
| `nix/home/modules/claude.nix`・`nix/tests/claude-herdr-skill.nix` | skill は包む前の herdr から張る（コメントとテストを合わせた） |
| `nix/tests/pjp-agent-link.test.sh`・`nix/tests/agent-link.nix` + `nix/flake.nix` | checks の `pjp-agent-link-test`・`agent-link-state` |
| `nix/tests/bootstrap-windows-ssh-config.test.sh` | 新しい `config` の中身と、前の版からの上書き |
| `nix/README.md`・`win/README.md` | 運用手順 |
| `docs/adr/008_…`・`022_…` | 冒頭の表に後続 ADR の行（本文はそのまま） |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| ADR 008 の案 C そのまま（`~/.ssh/rc` が接続のたびに固定名を張り替える） | 後勝ちになる。覗くだけの接続や attach の確認用の短い接続が固定名を奪い、閉じると herdr の中の全員が agent を失う。rc は記録だけにした |
| 同じマシンを接続元のアドレスで見分ける（cc-page 0001 の形） | DHCP でアドレスが変わる・IPv4 と IPv6 で違う・NAT や踏み台の越しでは別の PC が同じアドレスになる。ユーザーが環境変数で見分ける形を選んだ |
| 名前を `LC_PJP_SSH_CLIENT` にする（Debian・Ubuntu・macOS の sshd は既定で `AcceptEnv LANG LC_*` を持つので、設定なしで届く） | Debian の ssh の既定の `SendEnv LANG LC_*` で、そこからさらに ssh した先へも値が付いて行き、別のマシンからの接続が元の PC を名乗ってしまう。locale の名前の場所を借りる形にもなる |
| 固定名を 1 つにする（cc-page 0002 の形） | ある session の attach が、ほかの session の固定名を動かす。同じユーザーを共有したときの保険が弱い。ユーザーが session ごとを選んだ |
| 見張りを常駐の `inotifywait -m` にする | 依存と常駐のプロセスが増える。path unit の取りこぼしは、watch が始めと終わりで比べて繰り返すことで小さくでき、残る短い間に起きたものも次の知らせ（次の接続・attach）で直る |
| lock を使わず rename だけで入れ替える | 見張りが `ssh-add` で生死を見ている間に別のマシンから開き直されると、見張りが古い見立てで前の持ち主の接続へ戻す |
| fish・bash の `herdr` 関数を薄く残す | 関数を通る経路と通らない経路（hr）で挙動が分かれたままになる |
| herdr 側で attach のときに env を更新する（tmux の `update-environment` 相当） | ADR 008 の案 E と同じ。すでに走っている pane には効かず、herdr は手を入れる対象ではない |

## 5. 影響 (Consequences)

### 良くなること

- hr で detach → attach し直しても、pane から agent が使える（attach が開いた接続へ向け直す）
- detach したままでも、同じ PC から素の ssh の端末などが繋がっていれば、見張りがその接続を借りる。default と s2 の
  どちらも切断され、生きている接続が 1 本なら、両方がそれを指す
- 覗くだけの接続と attach の確認用の短い接続は、固定名の先が生きている限り奪わない
- 別のマシン（値の違う・届いていない接続）の agent を、見張りが勝手に借りない
- `PJP_SSH_CLIENT` が届いていないサーバーに、プロンプトで気づける
- WSL の手元と、lavie の前で開いたときの挙動（ADR 022）は変わらない

### 注意が必要なこと

- **今動いている server は、作り直すまで今のまま。** 適用したあと、都合のよいときに 1 回 `herdr server stop`
  （named session は `herdr session stop <名前>`）して開き直す。pane のプロセスは終わる（Claude Code は herdr の
  agent session restore で会話へ戻れる）
- **借りる仕組みは、受け取る側の sshd が `AcceptEnv PJP_SSH_CLIENT` を持つときだけ効く。** 無いサーバーでは借りない
  だけで、attach し直せば鍵は使える。NixOS のホストは nixos-config が入れる（TKT-255）。ほかは警告を見て都度足す
- ssh は最初に当たった `SetEnv` の行だけを使う。`config.d` の `Host` に自分の `SetEnv` がある接続先では、そこにも
  `PJP_SSH_CLIENT=%u@%L` を足さないと届かない
- `~/.ssh/rc` を置くと、sshd は xauth を自分では呼ばず（rc が渡す）、`/etc/ssh/sshrc` も走らせない。sftp・
  ForceCommand・`PermitUserRC no`・authorized_keys の `restrict` / `no-user-rc` の接続では rc が走らず、その接続は
  見張りに借りられない。手で置いた `~/.ssh/rc` があるマシンでは、switch が「would be clobbered」で止まる
- path unit が service を走らせている間に起きた変化は、watch の最後の比べから unit が見張りに戻るまでのごく短い間に
  起きたものだけ取りこぼす（次の接続か attach で直る）
- OpenSSH 10.1 より古いホスト（socket が `/tmp/ssh-*/`）は見張らない。macOS は見張りが無い（attach の張り替えだけ）
- user の systemd が止まっている間（linger の無いホストで最後の session が閉じたあと）は見張りも止まる。次に繋いだ
  接続の attach で直る
- 削除した session の固定名と持ち主の記録は残る（使うプロセスが無いので害は無い。要らなければ消してよい）
- 誰も繋いでいないあいだは、herdr の中から鍵は使えない（ADR 008 と同じ、意図した性質）

## 6. 検証 (Verification)

nix の check（CI と同じ）:

- `nix build ./nix#checks.x86_64-linux.pjp-agent-link-test`: 偽の HOME・偽の `ssh-add`・python で bind した本物の unix
  socket で、attach の表・「開いた接続」の決め方・link・rc（stdout が空・xauth・記録）・watch（cc-page 0003 の場面 1 の
  1〜11、覗くだけの接続、返事をしない記録、見張りと attach が同時に走る場面）・status・包む実行ファイル（attach と
  みなす呼び出し・何もしない呼び出し・bridge の stdin と stdout・失敗と時間切れ）・starship の判定（本物の starship も）を流す
- `nix build ./nix#checks.x86_64-linux.agent-link-state`: home の中身（包んだ herdr・rc・unit・関数が無いこと・
  フォールバックの判定・`SetEnv`）と、包んだ herdr が本物の herdr を store のパスで exec すること
- `bootstrap-windows-ssh-config-test`・`claude-herdr-skill`・`nix flake check --all-systems --no-build`・
  `nix flake check --no-eval-cache`・shfmt・shellcheck・nixfmt・テストの先頭の「## 確かめること」・`check-test-grep-q.sh`

lavie での実機の結果は「6.1」に書く。

### 6.1 lavie での実機

（PR の確かめの結果をここに書く）

## 7. 移行・運用手順

```sh
# 1. 適用 (lavie なら --host pollenjp@laptop)。WSL のマシンでは Windows の config の SetEnv も配られる
~/dotfiles/setup --update

# 2. 今動いている server を 1 回作り直す (固定名を持たずに起きた server のため)
herdr server stop          # default
herdr session stop s2      # named session ごとに
# Windows の PowerShell から開き直す (bridge が包んだ herdr を通り、固定名を持つ server が起きる)
herdr.exe --remote lavie.local

# 3. 確かめる (ssh 先で)
pjp-agent-link status      # 固定名の先・生死・持ち主と、記録にある接続
# herdr の pane の中で
echo "$SSH_AUTH_SOCK"      # ~/.ssh/agent.sock (named session は ~/.ssh/agent.<名前>.sock)
ssh-add -l                 # 鍵が並ぶ
```

- ssh 先の sshd に `AcceptEnv PJP_SSH_CLIENT` が無いと、プロンプトに `⚠ PJP_SSH_CLIENT なし` が出る（借りる仕組みが
  効かないだけで、attach し直せば鍵は使える）
- 鍵が引けなくなったら、detach して開き直すか、herdr の外の ssh の shell で `ssh-agent-link` を打つ
- 張り替えの記録は `~/.local/state/pjp-agent-link/log`
