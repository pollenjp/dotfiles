# Dev Tracker のコメントの見回り役を systemd の user service で常駐させる — 設計 (TKT-306)

- チケット: [TKT-306](https://app.notion.com/p/Dev-Tracker-ticket-sh-inbox-systemd-user-service-TKT-302-3-10-40179149a66f81cfa1dcf2bb17884532)
  (仕組み全体の設計と指揮役の会話は [TKT-302](https://app.notion.com/p/Dev-Tracker-40179149a66f81c28be2e41f4e9c2a98))
- 方針は 2026-10-22 にユーザーが TKT-302 で承認した。この文書は、その設計のうち dotfiles の受け持ち (設計の 3.10「常駐」) の
  書き写しと、実装で決めたこと
- 見回り役の本体 (`ticket.sh inbox`)・コメントの選び方・会話の側の決まりは claude-skills の別の PR。設計の全文はそちらの
  `docs/superpowers/specs/2026-10-22-ticket-comment-inbox-design.md`

## 背景と意図

ハブ (`~/h`) の会話のチケットのページにユーザーがコメントを書くと、そのチケットの会話 (herdr の pane の Claude) に、端末で
打った発言として届くようにする。ユーザーの言葉 (原文):

> いま dev tracker にてチケットを作ってもらっていると思うけど、このチケット側に僕がコメントしたら、集約会話セッション側でそれを拾って普通の指示として受け取ってくれるような仕組みを実現したいなぁ。

> それもあるし、普通に notion 側の方が並行で動いているagentの様子を管理しやすいから。

(前者の「それ」は、外出先のスマホで回答待ちのチケットにその場で答える場面)

## 呼ぶ口 (設計の 3.10 の写し)

- `~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh inbox`: 常駐。`--interval <秒>` (既定 30)。SIGTERM・SIGINT で終了コード 0
- 設定の誤り (ユーザーの Notion の id が無い・プロファイルが決まらない) は終了コード 2。service はこれで再起動を繰り返さない。
  ntn・git・herdr が PATH に無いときも終了コード 2 (claude-skills の PR #110 で足した)
- 1 回の見回りの失敗 (ntn・herdr の一時的な失敗) はログに出して次の見回りへ進む (終了しない)
- ログは標準出力・標準エラー (journal に入る)。何もしなかった見回りでは出さない
- 使うコマンドは ntn・herdr・git・python3 (3.11 以上。無ければ claude-skills の flake の devShell に nix で入り直す)。
  Notion の API キーは ticket.sh が自分で `~/.config/pjp/env` から読む
- merge は claude-skills の PR (pollenjp/claude-skills#110) が先。`inbox` が入る前に service が動いても、再起動を繰り返さない。
  merge のあとも、`~/dotfiles/setup --update` で claude-skills の clone を進めるまで `~/.claude/skills` の ticket.sh に inbox は無い

## 決めたこと

- **ホストごとの option にする。** `dotfiles.claude.devTracker.inbox.enable` (既定 false)。`devTracker.enable` が false の
  ホストで true にしたら評価で止める。値は dotfiles-private の `nix/hosts/` に書く (ADR 026・027 の決め方)。
  dotfiles-private の 4 台とも `devTracker.enable = true` だが、その全部では動かさない。見回り役は自分のマシンに worktree の
  無いチケットを読まないので、複数のホストで動かしても互いの会話のチケットには書かない (claude-skills の PR #110。TKT-307) が、
  プロファイルにユーザーの Notion の id (`user.id`。今は personal にだけある) が無いホスト (work) では終了コード 2 で止まり、
  failed の unit と setup の警告が残り続ける。ハブの会話を回さないホストでは 30 秒ごとに Notion を引くだけになる
- **unit** (`home/modules/dev-tracker-inbox.nix`。中身の理由は module の先頭のコメント)
  - `ExecStart` は store の bash で `ticket.sh inbox` を打つ (実行の bit と `/usr/bin/env` に頼らない)。cwd は `~/h`
  - `ConditionPathExists` (ticket.sh)・`ConditionPathIsDirectory` (`~/h`) で、無いマシンでは failed で残さずにスキップする
  - `Restart=on-failure`・`RestartSec=30`・`RestartPreventExitStatus=2`・10 分に 5 回 (`StartLimitBurst`) で諦める
  - `KillMode=mixed` (止めるときの SIGTERM は本体の python3 にだけ送り、打っている途中の herdr・ntn を巻き込まない)・
    `TimeoutStopSec=5min` (本体は今の見回りを終えてから止まる。既定の 90 秒では、届ける会話が重なると控えを書く前に
    SIGKILL され、同じコメントを二度打ちうる)
  - macOS で true にしたら評価のたびに警告する (systemd の unit しか置かないので、黙って何もしない)
  - `PATH` (`~/bin`・`~/.local/bin`・home-manager の profile・nixpkgs の python3・nix の profile・NixOS の system の profile・
    `/usr/bin` など) と `PYTHONUNBUFFERED=1` を渡す。user manager の PATH には ntn・herdr・nix が無い。python3 は system の
    ものより前に置き、system の python3 が古くても `nix develop` を挟まずに済むようにする (home の閉包にもともとある 3.14。
    claude-skills の PR #110 の見回り役のテスト 87 件と ticket.py のテスト 505 件が 3.14.7 で通る)
- **setup で起こし直す。** `bootstrap-dev-tracker-inbox.sh` (`order: 70`) が、`bootstrap-claude-skills.sh` (50) と
  `bootstrap-herdr-hub.sh` (60) の後に `daemon-reload`・`reset-failed`・`restart` を打ち、3 秒のうちに止まったら今回の起動
  (`InvocationID`) の journal の末尾を添えて警告する。起動の条件 (ticket.sh・`~/h`) が揃わずに飛ばされたときも、使うと決めた
  ホストなので、無い方と直し方を警告する。claude-skills の更新では unit ファイルが変わらず switch が再起動しないのと、
  `--update` では switch が claude-skills の更新より先に走るため (初めて入れるときも、switch が起こした見回り役は古い clone で
  2 で止まりうる)
- **linger は要らない。** herdr の server が残る closing の login session が user manager を生かすので、SSH を全部切っても
  止まらない (下の「確かめたこと」)。止まるのは server も落ちて SSH も無いときだけで、その間は届ける先の会話も無い

## 確かめたこと (2026-10-22、GCP の VM・systemd 255)

- logind は `KillUserProcesses=false`・`UserStopDelaySec=10s`、`Linger=no`。herdr の server は closing の `session-75.scope` の中
- SSH が 1 本も無かった 2026-10-21 12:51:55〜23:35:18 UTC (session 75 の logout から次の SSH まで) に、`user@1001.service` は
  再起動なし (`ActiveEnterTimestamp` が 10-20 17:38:40 のまま) で、同じ形の常駐の `cc-pages.service` も 11:16:05 の起動から
  10-22 00:24:01 まで止まらなかった (logind と user の journal)
- 今の claude-skills の `ticket.sh inbox` は argparse の invalid choice で終了コード 2。home-manager が作る unit を名前を変えて
  `/run/user/1001/systemd/user` に置いて起こすと failed (`ExecMainStatus=2`) になり、`NRestarts=0` のまま再起動しなかった
- 同じ unit の ExecStart だけ替えた probe で、cwd が `~/h`、`%h` が展開され、ntn・herdr・git・python3 (nixpkgs の 3.14.7)・
  nix が見え、`HERDR_*` の無い環境で `herdr agent list` が既定の socket で server に届いた
- 同じ unit の ExecStart を claude-skills の PR #110 の worktree の `ticket.sh inbox --dry-run` (打たず・返信せず・控えも
  書かない) に替えると、終了コード 0 で終わった (API キー・プロファイル・`user.id`・herdr・Notion はどれも通った)
- `systemd-analyze --user verify` は警告なし

## やらないこと

- macOS の launchd の agent (ハブを回すのは Linux のホスト)
- linger を有効にすること (要るのは再起動の後、ログイン前から返事までさせたいときだけ)
- このホストで option を有効にすること (dotfiles-private の `nix/hosts/` の変更。別の repo)
