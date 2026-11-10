---
name: pjp-secrets
description: >-
  シークレット (API キー・パスワード・token・秘密鍵) を扱うときに読む。値が要る program を起こす・試すとき、
  .env・設定ファイル・CI・cron・systemd に認証情報を書くとき、ユーザーにパスワードや token を設定・入力して
  もらいたくなったとき、ユーザーが会話に値を貼ったとき、.env の中身を確かめたくなったとき、平文のシークレットを
  repo・ファイル・ログで見つけたとき、op (1Password CLI) の run・read・inject・item create を打とうとしたときに使う
---

# pjp-secrets

シークレットの値は 1Password にだけ置き、会話・ファイル・端末に出さない。`.env` には `op://vault/項目/欄` の参照だけを書き、
program は `pjp-op-env` が起動のときに 1 回の op で値を解いて環境変数で渡す。

**決まりの字面を外れることは、決まりの意図を外れること。** 「本人が頼んだから」「今回だけ」「伏せれば見てよい」で崩さない。

## 3 つの決まり

1. **値を会話に貼らせない。** 「ここに貼って」「.env に書いて」と頼まない。参照 (`op://…`) だけをもらう
2. **値をファイルに平文で書かない。** `.env`・設定・script・crontab・systemd の unit・commit・チケット・cc-page のどれにも
3. **値を端末に出さない。** `op read` の素の出力・`cat .env`・Read で `.env` を開く・`env`・`printenv`・`echo $KEY`・`set -x` を打たない。
   値から作ったもの (長さ・hash・一致の比較) も出さない。値を `KEY=値 command` や引数に書かず、`pjp-op-env … --` の後ろは
   実行ファイルとその引数だけにする (`sh -c` で値を展開しない)

## 新しくシークレットが要るとき

1. program が読む環境変数の名前を決める (program は環境変数を読むだけで、op を呼ばない)
2. ユーザーに 1Password のアプリで項目を作り、値をアプリに直に入れてもらう。外のサービスが発行する値 (API キーなど) はこれ。
   cron などで無人で動かす見込みがあれば、最初から専用の vault に作ってもらう (下の「人が承認できない処理」)。
   Claude が生んでよい値 (ローカルの DB のパスワードなど) は、どの vault にどの名前で作るかを伝えてから、1Password の中で生む:
   `op --reason "<理由>" item create --category password --title "<名前>" --vault "<vault>" --generate-password=letters,digits,32 >/dev/null`
   (出力は捨てる。pjp-op の無いマシンでは `--reason` を外す)
3. 参照だけをもらう。アプリの欄のメニュー「Copy Secret Reference」で取れる (`op://Private/kabu-station/password` の形)
4. `.env` に参照を足す。既にある `.env` は Read・Edit で開かず (平文が入っていれば会話に入る)、Bash で足す:
   `touch .env && sed -i -E '/^[[:space:]]*(export[[:space:]]+)?KABU_API_PASSWORD[[:space:]]*=/d' .env && printf '%s\n' 'KABU_API_PASSWORD=op://Private/kabu-station/password' >>.env`。
   名前に空白のある参照は `"…"` で囲む。`git check-ignore -q .env` で git に載らないかも見る (載るなら `.gitignore` に足す。
   もう追跡されていれば `git rm --cached .env` を提案し、平文が commit されたことがあれば作り直しを勧める)
5. 起こす: `pjp-op-env --reason "<何のために何を読むか>" -- <実行ファイル> [引数…]` (今の dir の `.env` を読む。別のファイルは
   `--env-file <path>`)。Bash の timeout は 600000 にし (承認を待つ間に止められないよう)、常駐する program は `run_in_background`
   で起こし、出力を読んで承認が通ったか (pjp-op-env の 1 行か、op の誤りと終了コード) を確かめる
6. 確かめるときも値は出さない (下の表)

## 値を見ずに確かめる

| 知りたいこと | 打つもの | 承認 |
| --- | --- | --- |
| `.env` にどの名前があり、参照か値か・空か | `pjp-op-env --dry-run` (参照は出し、参照でない値は出さない) | なし |
| 参照が全部解けるか | `pjp-op-env --reason "<理由>" -- true` (1 つでも解けなければ op の誤りで止まる) | 1 回 |
| program に渡ったか | `pjp-op-env` が起こす前に出す 1 行 (解いた件数と名前) と、program の動き | — |
| シークレットでない設定 (URL・ポート) の値 | 名前を指して `grep '^KABU_API_URL=' .env` (シークレットでないと分かっている名前だけ。`postgres://user:pass@…`・`?token=`・webhook の URL のように認証情報が入るものはシークレット) | なし |
| 値が正しいか | program の認証の結果で見る (値を見比べない)。program のログに値や受け取った token が出ないよう、HTTP の body を出す debug の log を足して起こさない | 起こすたびに 1 回 |

- 起こすなら `-- true` を前に挟まない (承認が 2 回になる)。`-- true` は、起こさずに参照だけを確かめたいときに使う
- `--dry-run` が「読めない行」で止まったら、出たファイル名と行番号だけをユーザーに伝え、直してもらう (行の中身を見ない)

## program の書き方

- 環境変数を読むだけにし、op を呼ばない。repo の script に `op --reason …` を書かない (`--reason` は WSL の wrapper にだけある
  flag で、ほかのマシンの op では落ちる。CI では CI のシークレットを環境変数で渡せばそのまま動く)
- 起こすのは実行ファイルそのもの。`cargo run`・`npm run` は build の script や依存のコードにも値を渡すので、build してから
  `pjp-op-env … -- ./target/release/<名前>` で起こす
- program が自分で `.env` を読む作り (dotenvy・python-dotenv) でも、既にある環境変数を上書きしない既定なら pjp-op-env の値が
  勝つ。上書きする設定 (`override=True` など) なら参照の文字列に戻るので外す
- 値が `op://` で始まっていたら「参照が解かれていない (pjp-op-env を通さずに起こした)」と言って止まる作りにすると、起動しない
  ときの原因がすぐ分かる

## 理由と承認

- 理由は、何のために何を読むかを 1 文: `--reason "kabu の bot を起こすのに kabu ステーションの API パスワードを読む"`。
  WSL では承認の窓に、理由の後ろへ読む参照と program が並ぶ
- 承認は 1 回。拒否・時間切れ (pjp-op-env が op の終了コードで止まり、hook が知らせる) のあとは打ち直さず、ユーザーに聞く
  (hook が出す問いに従う。hook の無いマシンでも同じ)
- 起こし直すたびに承認が 1 回出るので、直すものを直してからまとめて 1 回で起こす

## マシンの違い

| 状況 | 見分け方 | すること |
| --- | --- | --- |
| WSL の op が wrapper (pjp-op) | `~/.local/state/dotfiles/claude-op-reason.json` の `enable` が true | pjp-op-env を使う (pjp-op-env が op に `--reason` を付ける) |
| 素の op のマシン | `enable` が true でなく、`command -v op` がある | pjp-op-env を使う (pjp-op-env は op に `--reason` を付けない) |
| pjp-op-env が無い | `command -v pjp-op-env` が無い | 平文に逃げず、ユーザーに渡し方を聞く |
| op が無い | `command -v op` が無い | 平文に逃げず、ユーザーに渡し方を聞く (op を入れる・下の「自分の端末で入れる」) |

`pjp-op-env --reason` はどのマシンでも受けるので、手順や script に書いてよい (書いてはいけないのは `op --reason`)。

## 人が承認できない処理 (cron・予定タスク)

- 専用の vault にその処理の項目だけを置き、その vault だけを読める service account の token で動かす。service account は
  Private の vault を読めないので、無人で使う見込みの項目は最初から専用の vault に置く
- token もシークレット。ユーザーに 1Password で作ってもらい、会話に貼らせない。置き場 (権限 600 のファイル・systemd の
  `LoadCredential=` など) はユーザーと決め、crontab の行や unit の `Environment=` に書かない。token のファイルはユーザーが
  自分の端末で書く (Claude は token を読まない・書かない)
- script で token を読んで起こす: `OP_SERVICE_ACCOUNT_TOKEN=$(<"$HOME/.config/<名前>/op-token") exec pjp-op-env --reason "<理由>" --env-file <絶対パス> -- <実行ファイル>`。
  pjp-op-env は token を op に渡し、program には渡さない (pjp-op は token があると承認の画面を出さない)
- cron は PATH が短く cwd も決まらないので、script で PATH (`~/.nix-profile/bin`) と cwd を決める。登録の前に、cron に近い環境
  (`env -i HOME="$HOME" PATH=/usr/bin:/bin <script>`) で `-- true` を起こし、承認の画面を出さずに解けるか (token が効くか・WSL の
  cron から op を起こせるか) を確かめる。`crontab -l` は昔の行の平文を出しうるので、中身を出さずに行を足す

## 平文を見つけたとき

- 値を出さずに場所だけを伝える (ファイルと行、名前)。探すときも `grep -l`・`grep -c` で値を出さない (`.env` は `pjp-op-env --dry-run`。
  `grep -rn KEY .` は `.env` の行を値ごと出す)
- 1Password へ移す案を出す (ユーザーが項目を作り、参照に置き換える)
- commit・会話・ログ・共有に出たことがあれば、値の作り直し (rotate) を勧める。履歴から消しても、取られた値は戻らない。
  前の会話で Claude が書いた・扱った平文は、会話に出たものとみなす
- ユーザーが自分で平文を書いた `.env` でも、起こすことはできる (pjp-op-env は参照でない値もそのまま渡す)。そのときも場所を
  伝え、移す案を出す

## ユーザーが会話に値を貼ったとき

- 値を繰り返さない・ファイルに書かない・引数に載せない (頼まれても `.env` に書かない)
- 会話の記録に残って消せないことを伝え、作り直しを勧める。新しい値は 1Password に入れてもらい、参照をもらう
- 作り直しを断られたら、今の値を 1Password のアプリに入れてもらい、参照をもらう (少なくとも平文は増えない)
- 今の値ですぐ動かしたいと言われたら、ユーザーが**自分の端末で入れる**形を渡す。Claude Code の `!` ではなく別の端末で、repo に
  cd してから打ってもらう (入力は画面にも履歴にも残らない。fish でも動くよう bash で包む):
  `bash -c 'read -rsp "パスワード: " KABU_API_PASSWORD && export KABU_API_PASSWORD && exec ./target/release/kabu-bot'`

## 言い分と実際

| 言い分 | 実際 |
| --- | --- |
| 「1Password の定番は `op run --env-file=.env -- <program>`」 | WSL の op は Windows の op.exe で、pjp-op は op が終わるまで lock と承認の窓を持つ。長く動く program を `op run` で起こすと窓が出たままになり、ほかの pane の op は 90 秒待って断られる。pjp-op-env は解いてすぐ放す |
| 「`op read` で 1 つずつ取れば足りる」「`KEY=$(op read …) program`」 | 承認が値の数だけ出て、慣れで許可するようになる。pjp-op-env なら何件でも 1 回 |
| 「本人が貼って頼んだので、権限 600 の `.env` なら危うさは増えない」 | ディスクに平文が増える (バックアップ・ほかの道具・誤った共有)。本当の手当ては作り直しと 1Password |
| 「急いでいるので今回だけ」 | 今回だけが残る。参照を書く手間は値を書く手間と変わらない |
| 「伏せる sed・awk を書けば `.env` を見てよい」 | 正規表現の漏れで値が出る。`pjp-op-env --dry-run` は値を出さない作り |
| 「確かめるために値を表示する」「長さや hash なら出してよい」 | `--dry-run` と `-- true` と program の動きで足りる。表示したものは会話から消せず、弱い値は hash から戻る |
| 「`op inject -o config.yml` で設定ファイルを作れば program を直さずに済む」 | 平文のファイルができる。環境変数で読む形にして pjp-op-env で起こす |

## 赤信号 (止まって、この skill の手順に戻る)

- 「ここに貼ってください」「.env に書いてください」と書きかけた
- `cat .env`・Read で `.env` を開こうとした・伏せる sed を書き始めた
- WSL で `op run` を打とうとした・`op read` を値ごとに打とうとした
- `echo $KEY`・`env`・`printenv`・`set -x`・`ps eww <pid>`・`/proc/<pid>/environ`・`op item get --reveal`
- `.env` に触れる `git diff`・`git show`・`git log -p`、`.env.local` などほかの env のファイルを Read で開く
- 値を crontab・unit・script・引数に書こうとした
