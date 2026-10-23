# ADR: 登録の compare と draft は dotfiles-private の nix/shared/ を外してホストのファイルの値を比べ・描き、shared/ が足す値は別に出す

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針は 2026-10-23 にユーザーが指示 (集約ハブの会話 TKT-320 で、PC の登録のとき `nix/shared/` の値が差分に出る件を「これやってくれ」)。細部は PR でレビュー |
| 日付 | 2026-10-23 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-326](https://app.notion.com/p/PC-pjp-dotfiles-register-host-private-host-sh-compare-dotfiles-private-nix-shared--40179149a66f8145abe6e80ae1f77963)。集約は [TKT-320](https://app.notion.com/p/dotfiles-minimum-release-age-flake-dotfiles-private-40179149a66f81ce9b20f8443aeaf1b7) |
| 関連 ADR | [026_dotfiles_private_hosts](../026_dotfiles_private_hosts_20261020T215857JST/README.md)（登録の skill と `private-host.sh`。この ADR が compare と draft の `nix/shared/` の扱いを足す）、[030_mise_release_age_overrides](../030_mise_release_age_overrides_20261023T010148JST/README.md)（`nix/shared/*.nix` を登録した全ホストに足す。§5 の「compare は `nix/shared/` の値を違いとして出す」を改める） |
| 運用手順 | [`nix/README.md`「登録する」](../../../nix/README.md#登録する) と skill `pjp-dotfiles-register-host` |

---

## 1. 背景 (Context)

- ADR 030 で、`lib.privateHosts` が dotfiles-private の `nix/shared/*.nix` (home-manager の module) を、登録した全ホストに足すように
  なった。今は mise の遅延の上書きが 1 つ入っている
- `private-host.sh compare` は、旧い形 (ローカル flake の元のホスト) と新しい形 (dotfiles-private に登録したホスト) の drvPath を比べ、
  0 で「登録しても中身が変わらない」を示す。`shared/` の値は新しい形にだけ当たるので、`shared/` に値があると compare は必ず 1 を返し、
  skill の手順 (「compare が 0 になる」「違いは直した値の分だけ」) と食い違った。ADR 030 では compare を変えず、README に
  「違いが `shared/` の値だけなら…」と書くに留めていた
- 登録済みの PC の値を直すとき (`draft --base <登録したホスト>`) は、元のホストにもローカル flake の読む clone の `shared/` が
  当たっているので、下書きに `shared/` の値が描かれる。そのまま置くと `shared/` とホストのファイルの 2 か所に同じ値が並ぶ
  (list はつながり、項目が 2 つになる)

## 2. 決定 (Decision)

### A. compare は `shared/` を外した新しい形とも比べ、`shared/` の値だけの違いなら 0

作業ツリーの `nix/shared/` に module (`.nix` で終わり `.` で始まらないファイル。`privateHosts` と同じ拾い方) があれば、新しい形を
`shared/` を外しても評価する。

| 比べた結果 | 終了コード | 出すもの |
| --- | --- | --- |
| 旧い形 = 新しい形 | 0 | 今までどおり「drvPath が同じ」 |
| 旧い形 = `shared/` を外した新しい形 | 0 | 「同じ (shared/ の値だけ違う)」と、`shared/` が足す値 (`shared/` を外した形 → 新しい形の `config.dotfiles` の違い。`shared/` がこのホストの値を変えなければそう出す) |
| どちらとも違う | 1 | ホストのファイルの違い (旧い → `shared/` を外した形) と、`shared/` が足す値を分けて |
| `shared/` を足した新しい形が評価できない | 4 | 原因の行 (list でない option を `shared/` とホストのファイルの両方に書いた、など) |
| `shared/` を外した形だけが評価できない | 1 | 原因の行を出し、`shared/` を含めた形で比べる (ホストのファイルが `shared/` に頼っている) |

(元のホストが型・`tmp` のとき。登録したホストのときは B)

- `shared/` を外した形は、作業ツリーの `nix/` を `shared/` だけ除いて写し、その写しを `dotfiles-private` の入力にした flake で評価する。
  lock は今までの写しと同じく張り直す
- 終了コードは増やさない。登録の判定は「ホストのファイルが元のホストの値を全部写せているか」で、`shared/` は全ホストに足す値で
  ホストのファイルの外にあるため。元のホストが型・`tmp` なら、`shared/` の値は登録でこの PC に増える値として、確認と PR の本文に書く (skill)
- `shared/` が無ければ、今までと同じ評価・同じ出力

### B. 元のホストが登録したホストなら、draft と compare の旧い形から `shared/` を外し、clone と作業ツリーの `shared/` を比べる

元のホストが、ローカル flake の読む dotfiles-private に登録したホスト (`hosts/<元のホスト>.nix` がある) で、その `shared/` に module が
あれば、ローカル flake の写しの `dotfiles-private` の入力を、`shared/` を除いた写しへ指し直してから評価する (値を直すとき・merge のあとに
clone と比べ直すとき)。

- draft は `shared/` の値を描かない (ホストのファイルの値だけ)。外したら 1 行で知らせる。外した元のホストが評価できなければ 3 で、外したことを出す
- compare は、ホストのファイルどうしで比べる。この PC には clone の `shared/` がもう当たっているので、作業ツリーの `shared/` の値は
  「登録で増える値」ではない。代わりに、clone と作業ツリーの `shared/` が同じかを `diff -r` で比べて出す

| ホストのファイル | clone と作業ツリーの `shared/` | 終了コード | 出すもの |
| --- | --- | --- | --- |
| 同じ | 同じ | 0 | 「同じ。shared/ を外すと drvPath が同じ … shared/ も clone と作業ツリーで同じ。この登録で世代の中身は変わらない」(変更前と同じ判定) |
| 違う | 同じ | 1 | ホストのファイルの違いと、「shared/ は clone と作業ツリーで同じ」の 1 行 |
| 同じ | 違う | 0 | 「同じ (shared/ の値だけ違う)」と、「clone と作業ツリーの shared/ が違う」・作業ツリーの `shared/` が足す値 |
| 違う | 違う | 1 | ホストのファイルの違いと、上と同じ `shared/` の段 |

- 登録簿の型と `tmp` には `shared/` が当たらないので、外さない (外しても値は同じだが、写しと lock の張り直しが増える)
- `--out` は、作業ツリーの `nix/` と、ローカル flake の読む dotfiles-private の `nix/` の中に作らない (作る前に 2 で止める。clone に書かない)

### C. inspect は clone の `shared/` の module を出す

`shared/ (登録した全ホストに足す module): <ファイル名>`。登録すると、ホストのファイルの値に加えてこの値が当たる。

```
compare --base <元のホスト> --private <作業ツリー>
  旧い形      ローカル flake の写しの <元のホスト>   (登録したホストなら、clone の shared/ を外す)
  新しい形    作業ツリーの nix/ の <名前>           (shared/ を足した形。評価できなければ 4)
  外した形    作業ツリーの nix/ から shared/ を除いた写しの <名前>   (shared/ に module があるときだけ)

  元のホストが型・tmp:
    旧い形 = 新しい形 → 0
    旧い形 = 外した形 → 0「同じ (shared/ の値だけ違う)」+ shared/ が足す値 (外した形 → 新しい形。登録で増える)
    それ以外          → 1  ホストのファイルの違い (旧い形 → 外した形) + shared/ が足す値
  元のホストが登録したホスト (旧い形から clone の shared/ を外す):
    旧い形 = 外した形 → ホストのファイルが同じ。clone と作業ツリーの shared/ が同じなら 0「世代の中身は変わらない」
    それ以外          → 1  ホストのファイルの違い (旧い形 → 外した形)
    どちらも、shared/ が同じか (diff -r) を出し、違えば作業ツリーの shared/ が足す値を並べる
```

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/scripts/private-host.sh` | compare (`shared/` を外した形・判定・違いを分けて出す・clone と作業ツリーの `shared/` の比べ・`--out` の置き場所)・draft と compare の旧い形 (元のホストが登録したホストなら `shared/` を外す)・inspect (`shared/` の module)・`--help` |
| `nix/tests/private-host.test.sh` | 偽の nix に `shared/` の扱い (drvPath に `+shared`・`FAKE_DOTFILES` を足す・`FAKE_NEEDS_SHARED`・`FAKE_SHARED_NOOP`) を足し、ケースを足した |
| `nix/files/claude/skills/pjp-dotfiles-register-host/SKILL.md` | compare の結果の読み方の表・inspect の読み方・確認の前の preview に clone の `nix/shared/` も写す (手順 2.3。登録すると当たる値を確認の時点で出させる)・確認の形・PR の本文・値を直すとき・よくある誤り |
| `nix/README.md` | 「登録する」の `shared/` の注意 |
| ADR 026・030 | 冒頭の表に、この ADR への後続 ADR の行を足した。026 の §7 のコマンドの注記を今の形にした |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| compare を変えず、README に注意を書く (ADR 030 の形) | skill の手順 (「compare が 0」) と食い違い、`shared/` の値と下書きの誤りを読み分ける手間が残る |
| `shared/` の値だけ違うときに別の終了コード (5 など) を返す | skill の「compare が 0」を書き分けることになる。判定は「ホストのファイルが写せているか」1 つで足りる |
| 旧い形にも `shared/` を当ててから比べる | ローカル flake の写しの `homeConfigurations` を組み替えることになり大きい (ADR 030 で採らなかった理由と同じ)。登録簿の型と `tmp` に `shared/` が当たらないのが正しい形 |
| `lib.privateHosts` に `shared/` を外す引数を足す | public の本体の lib の形が増える。写しの入力を差し替えれば lib を変えずに済み、偽の nix のテストでも見分けられる |
| 旧い形はそのままにし、違いを option の名前で `shared/` の分とホストの分に分ける | 登録済みの PC で clone の `shared/` と作業ツリーの `shared/` が違うと、ホストのファイルが同じでも 1 になる。draft の 2 重書きも残る |
| 登録したホストを元にしたとき、旧い形を `shared/` を外さずにも評価し、まず旧い形と新しい形の drvPath を比べる | 世代の違いを評価で確かめられるが、評価が 1〜2 回増える (1 回 20〜60 秒)。clone と作業ツリーの `shared/` が同じなら、ホストのファイルの比べと合わせて同じ結論になる |
| 登録したホストを元にしたときも、作業ツリーの `shared/` の値を「登録で増える値」として並べる (最初の実装) | この PC には clone の `shared/` がもう当たっているので誤り。何も変えていなくても「shared/ の値だけ違う」と出て、変更前の「drvPath が同じ」より後退する (レビューの指摘) |

## 5. 影響 (Consequences)

### 良くなること

- 登録の compare が `shared/` の値に引きずられずに 0 になり、`shared/` が足す値は分けて見える
- 登録済みの PC の値を直すとき、下書きに `shared/` の値が混ざらない

### 注意が必要なこと

- `shared/` に module があると、compare の評価が 1 回増える (`shared/` を外した形。1 回 20〜60 秒)。違うときは `config.dotfiles` の評価も増える
- 0 でも、「同じ (shared/ の値だけ違う)」なら `shared/` の値の分だけ世代の中身は変わる。元のホストが型・`tmp` なら、確認と PR の本文には
  `shared/` が足す値を書く
- clone と作業ツリーの `shared/` の比べはファイルの比べで、評価はしない。README のような説明のファイルだけが違っても「違う」と出る
  (「世代が変わりうる」と出す)
- ホストのファイルが `shared/` に頼っている (`shared/` の module が宣言した option を使う、など) と、`shared/` を外した形は評価できない。
  そのときは見分けずに比べる。元のホストが登録したホストなら、旧い形も評価できない (3。`shared/` を外したことを出す)
- 元のホストが登録したホストかは、ローカル flake の読む dotfiles-private に `hosts/<元のホスト>.nix` があるかで見る。ローカル flake に
  同じ名前のホストを手で足していると (後ろが勝つ)、当たっていない `shared/` を外すことになるが、値は変わらない

## 6. 検証 (Verification)

- `nix/tests/private-host.test.sh` (`private-host-test`。34 件)。偽の nix で、`shared/` の値だけ違う (0)・ホストの値も違う (1。分けて出す)・
  `shared/` がこのホストを変えない・`shared/` との衝突 (4)・`shared/` を外すと落ちる (1)・型が元なら外さない・登録したホストを元にした
  compare (ホストのファイルと `shared/` の同じ・違うの組み合わせ、clone との比べ直し) と draft・`shared/` に頼るホスト (3)・`--out` の置き場所・
  inspect・clone に書かないことを見る。`shared/` が無ければ `shared/` の行を出さないことも見る
- branch 全体を別の reviewer (subagent) に見てもらい、登録したホストを元にしたときに `shared/` の値を「増える値」と出す後退 (§4 の最後の行) と、
  Minor 5 件 (`shared/` がホストを変えないときの文言・`--out` の置き場所・3 の原因の表示・skill の読み方・テストの抜け) を直した
- 本物の Nix で、scratchpad に作った dotfiles-private とローカル flake に draft・compare を流した (この commit の本体を `git archive` で写した)
  - 型 `pollenjp@x86_64-linux` から描いた下書きと `shared/` (mise の上書き 1 項目): compare は 0「同じ (shared/ の値だけ違う)」。旧い形と
    `shared/` を外した形の drvPath が一致し、`shared/` が足す値は `mise.releaseAgeOverrides: [] → [{…}]` だった
  - clone を読むローカル flake で、登録したホスト (`ccPages.port = 7801`) を元にした draft は `shared/` の値を描かなかった。port を 7802 に
    直した作業ツリーとの compare は 1 で、ホストのファイルの違いは `ccPages.port: 7801 → 7802` だけだった。clone は変わらなかった
- skill の読み方を subagent で確かめた。今までの skill と出力では、作業ツリーの compare が `shared/` の値だけで 1 になると表に当てはまる
  行が無く、skill の外から出どころを推してユーザーへの問いを足した (preview には `hosts/` しか無いので、確認の時点の compare は 0 だった)。
  直した skill と新しい出力では、preview に `shared/` も写し、「同じ (shared/ の値だけ違う)」を 0 と読んで下書きを直さず、`shared/` が足す値を
  確認に並べた

## 7. 移行・運用手順

本体を新しくする (`~/dotfiles/setup --self-update --update`。script は本体の checkout から使い、skill は switch で配る) だけで効く。
登録の手順は skill `pjp-dotfiles-register-host` のまま:

```sh
p=~/ghq/github.com/pollenjp/dotfiles/nix/scripts/private-host.sh
bash $p compare --base <ホスト> --private <作業ツリー>   # 0 なら、ホストのファイルは元のホストの値を全部写せている
```

「同じ (shared/ の値だけ違う)」と出たら、出力の「shared/ が足す値」を確認と PR の本文に書く (登録すると、この PC にも当たる値)。
