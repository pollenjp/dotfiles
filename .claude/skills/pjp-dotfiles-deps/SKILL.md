---
name: pjp-dotfiles-deps
description: >-
  dotfiles (この repo) の依存の更新の、repo 固有の手順と設定 (repo の拡張)。依存の更新の skill (repo の手入れの pack) が、
  この repo を流すときに見つけて段ごとに読む。「dotfiles を更新して」「dotfiles の依存を上げて」「dotfiles に package update して」
  「Windows に固定した版を上げて」と言われてこの skill を先に開いたら、ここから始めず、依存の更新の skill の流れで進め、その段で
  ここの節を読む。閉包スキャンが whitelist に無い findings で止めたとき、Windows に固定した版 (OpenSSH・herdr・Google 日本語入力・
  ntn・Claude Code・Tailscale・ghq・fzf・starship・herdr-app・herdr-core と、bootstrap の Git for Windows・gh・Visual Studio Build Tools・rustup) の上げ先を聞くとき、
  merge の後の反映 (setup・mise の go と node・Windows のアプリ) を案内するときに読む。
metadata:
  pjp-extends: deps
---

# pjp-dotfiles-deps

dotfiles の依存の更新の、この repo 固有の手順と設定 (repo の拡張)。依存の更新の skill (repo の手入れの pack) が、この repo を
流すときに印 (frontmatter の `metadata` の `pjp-extends: deps`) で見つけ、下の節を段ごとに読む。設定は隣の `deps.toml` で、
その skill の script が読む (flake.lock の道具・見ないパス・例外の片付け・Windows に固定した版の口・PR の前の確かめ)。
この skill だけで依存を上げる手順にはしていない。

- dotfiles の更新は、いつも worktree の PR で行う。`~/dotfiles/setup --flake-update --update` は打たない (この PC の checkout の
  `nix/flake.lock` を書き換えたまま止まり、未 commit の変更のある checkout では `--self-update` が本体を pull しなくなる)。
  反映は merge の後にユーザーが打つ (「反映」)
- 長い中身は `references/` に分けた: `closure-scan.md` (閉包スキャンの findings の切り分けと 2 択)・`windows-pins.md`
  (Windows に固定した版の問い・直す所・merge の後の揃え方)
- 関連: `nix/README.md` の「依存 (flake.lock) の更新」「猶予の日数と例外」「閉包のスキャンと pin↔先端の差分」「Cargo.lock の既知の
  脆弱性 (osv-scanner)」、`win/README.md` の「固定した版より新しい版の知らせ」、ADR 005 (遅延)・006 (閉包スキャン)・032 (猶予の日数と
  例外)・055 (Windows の固定の知らせ)・056 (この拡張)・097 (Cargo.lock の脆弱性の CI)

## 範囲

足すもの:

| 対象 | わけ |
| --- | --- |
| Windows に固定した版 (`deps.toml` の `[[pins]]` の `windows`): OpenSSH・herdr・Google 日本語入力・ntn・Claude Code・Tailscale・ghq・fzf・starship・herdr-app・herdr-core と、bootstrap の git・gh・vs-buildtools・rustup | 版を `win/<名前>/Install-*.ps1`・`win/bootstrap/Install-Bootstrap.ps1` (bootstrap の 4 つ。名前ごとの param) と `nix/pkgs/herdr-core/releases.json` に固定している。repo の口 (`nix/scripts/bootstrap-windows-pin-updates.sh --candidates --json`) が、猶予ごとの上げ先を出す |

外すもの:

| 対象 | わけ |
| --- | --- |
| type-clipboard (`win/type-clipboard/`) | 自作のアプリ。公開からの猶予を置かず、Release を出す流れで上げる。Smart App Control の評判の確かめが要る (`win/README.md` の「type-clipboard の新しい版を出したとき」) |
| op-reason (`nix/pkgs/op-reason/` と `win/op-reason/`。`deps.toml` の `skip`) | 自作のアプリ (WSL の op の wrapper)。公開からの猶予を置かず、Release を出す流れで WSL と Windows を同じ PR で上げる (呼び出しの取り決め (payload の版) が変わった版どうしでは、WSL の op が Windows の `op-reason.exe` に断られる。`nix/README.md` の「op-reason の新しい版を出したとき」) |
| PowerToys | 版を固定しない |
| `nix/pkgs/upstream/` (`deps.toml` の `skip`) | 期間付きの例外 (`fromUpstream`) の中身。上げずに、片付け (「上げ方」) で扱う。項目が無いあいだはディレクトリも無い (`skip` と `[upstream_cleanup]` は、次に足す例外のために残す) |
| `nix/pkgs/herdr-core/` の fetchurl (`deps.toml` の `skip`) | 版は `releases.json` に固定していて、Windows に固定した版 (pins の herdr-app・herdr-core) で見る。印 `# release-source:` を置かず、2 か所で知らせない (build の確かめは `[[checks]]` の `herdr-core` のまま流れる) |
| mise のグローバルの道具 (go・node・usage・claude) | repo に版を書いていない (`nix/scripts/bootstrap-mise.sh` が版を書かずに入れる)。repo の範囲では上げず、merge の後の反映で案内する (「反映」) |

ほかの対象 (`nix/flake.lock` と skill の flake の `flake.lock`・印 `# release-source:` のある `nix/pkgs/ntn`・GitHub Actions) は、
依存の更新の skill のいつもの扱いのまま。

## 人が決めること

### 閉包スキャンの findings

flake.lock を上げる `update` (`deps.toml` の `flake_lock_age`) の最後に、閉包スキャンがゲートとして挟まる。whitelist
(`nix/vulnxscan-whitelist.csv`) に無い findings があると落ちる (skill の flake は whitelist が無く、表示だけ)。

- 会話: `references/closure-scan.md` の「切り分け」で全件を A (誤マッチ) と B (実在) に分け、表を出して止まり、2 択 (pin を
  動かす・意図して受け入れる) をユーザーに聞く。承認を得るまでしないことも、そこに並べた
- 定期実行: 聞かない。切り分けの表を PR の本文とチケットに書いて終わる。whitelist には足さない (PR は CI の閉包スキャンで
  赤いまま残り、人が決める)
- スキャナ (sbomnix) を組めずに止まったときは findings の話ではない (`references/closure-scan.md` の「スキャナを組めずに
  止まったとき」)

### Windows に固定した版

`deps.toml` の `ask = "interactive"`。候補は、依存の更新の skill が repo の口の JSON から出す (猶予 1・3・7 日の上げ先)。

- 会話: 見送っていない新しい版がある名前ごとに 1 問。問いの形 (選択肢・推奨・「見送る」「今は決めない」・見送る理由) は
  `references/windows-pins.md` の「問い」
- 定期実行: 聞かない。猶予 (`nix/release-age.nix` の `minimumReleaseAgeDays`。今は 7 日) どおりの上げ先だけを上げ、猶予の
  内側の新しい版は PR の本文に候補として並べる
- 猶予より新しい版を黙って選ばない。どの版を入れるか (上げないかも) はユーザーが決めること

### Cargo.lock の advisory の受け入れ

git が追う `Cargo.lock` (win/runner・nix/pkgs/claude-selector・nix/pkgs/pjp-ghq-pull) は、CI の `cargo-lock-vulns` が依存の更新と同じ
osv-scanner で照らし、受け入れていない advisory があれば重大度を問わず落ちる (要対応の線より広い)。受け入れはその `Cargo.lock` の隣の
`osv-scanner.toml` の `[[IgnoredVulns]]` (id・ignoreUntil (90 日先まで)・reason。書き方は `nix/README.md` の「Cargo.lock の既知の
脆弱性 (osv-scanner)」) で、依存の更新の osv-scanner も同じファイルを読む。

- 直した版が猶予の内側にしか無い・無い・major をまたぐ advisory を、直さずに受け入れるか (期限と理由) は人が決める。会話では、
  直した版と公開日・猶予が明ける日を並べて聞く。定期実行では聞かず、足さない (PR の本文とチケットに案を書く)
- 受け入れを足す・延ばすときは、ほかと混ぜない人の判断の PR (`Dependency-Refresh` の trailer なし) にする。直したら同じ PR で項目を消す

## 上げ方

| 対象 | すること |
| --- | --- |
| flake.lock | `deps.toml` の `flake_lock_age` に `update <flake のディレクトリ>` を続けて打つ (`nix/scripts/flake-lock-age.sh update "$PWD/nix"`。ディレクトリは絶対パスか `./…`)。素の `nix flake update`・`nix flake lock` は使わない。猶予の日数と期間付きの例外 (全体・一部 nixpkgs・一部 upstream) は `nix/release-age.nix` で、書き方は `nix/README.md` の「猶予の日数と例外」。例外を足すのは人の判断 (「人が決めること」) |
| 例外の片付け | `nix/release-age.nix` の消し時の過ぎた項目を消す。`fromUpstream` は lock の nixpkgs の版が追いついたら、項目と `nix/pkgs/upstream/<pkg>.nix` を一緒に消す (依存の更新の skill が `deps.toml` の `upstream_cleanup` で消し時を出す) |
| `nix/pkgs/ntn` (印のある fetchurl) | 依存の更新の skill の apply が版と hash を書く。残った古い版 (コメントなど) は、その skill が出す「手で直す」の行に従う |
| Windows に固定した版 | 決まった版を、名前ごとの直す所に書く。上げる前に release notes を読み、見送るなら見送りの一覧に足す。herdr-app は、増えた既定のキーも同じ PR で `win/herdr-app/keys.json` に足す (`references/windows-pins.md` の「直す所」) |

## 確かめ方

`deps.toml` の `[[checks]]` (ntn と herdr-core の build・Windows の ps1 のテスト・frontmatter) は、依存の更新の skill が PR の前に
変わったパスで選んで流すので、ここには書かない。書くのは `deps.toml` で書けない確かめだけ。

- Google 日本語入力の版は、Windows で上げて設定を読み書きできるかを確かめてから merge する (`win/README.md` の「Google 日本語入力」の
  「版を上げる」の 2〜4)。Windows の手元でしかできないので、上げた PR の本文に「merge の前に Windows で確かめる」と書いて人に任せる
  (Claude はこの PC の Windows 側を書き換えない)。設定を読み書きできなければ、見送る (`references/windows-pins.md` の「直す所」)
- OpenSSH には、入れずに試す手順がある (`win/README.md` の「OpenSSH の新しい版が出たとき」)。これも Windows の手元でしかできないので、
  上げた PR の本文に書いて人に任せる
- 閉包スキャンは、flake.lock を上げる `update` が挟むゲート。別には流さない (落ちたら「人が決めること」)
- PR を出すと、CI の `nix` (lint・lock-age・閉包スキャン) と、`win/` を触った PR なら `winget-versions`・`herdr-app-installers`
  (書いた版が winget にあるか・成果物の sha256)、`Cargo.lock`・`Cargo.toml`・`nix/flake.lock` を触った PR なら `cargo-lock-vulns`
  (Cargo.lock の既知の脆弱性) が走る。落ちたら直すか、直せなければ PR の本文に書く

## 反映

merge の後に、ユーザーが各マシンで打つ。Claude は打たない (その PC の環境を書き換える)。PR を返すときに、ここを添える。

```sh
~/dotfiles/setup --self-update --update
```

- flake.lock・`nix/pkgs/ntn`・Linux の herdr-core は switch で入る (`--self-update` が本体を pull し、switch が `~/dotfiles` の
  lock も張り直す)
- Windows に固定した版は、名前ごとに揃い方が違う (`references/windows-pins.md` の「merge の後」)。受け持ちを Windows の runner に切り替えた
  ホストでは setup は Windows に触らないので、Windows で `dotfiles --self-update apply` (3 つの clone を進めてから `dotfiles apply`) を流す (同じ節)
- mise のグローバルの go・node は setup が上げない (`bootstrap-mise.sh` は claude だけを猶予 1 日で上げ、go・node・usage は入っている
  版のまま)。依存の更新の skill の PC の範囲の案 (上げ先と打つコマンド) を見せ、ユーザーの了承を得てから `mise up go node` を
  打つ (mise の猶予 `dotfiles.mise.minimumReleaseAge` が効く)。了承が無ければ打たない
- 設定グループ・道具の switch で入れないホスト (グループ minimum でその道具を足していないホストなど。`nix/README.md` の「設定グループ」) では、入れていないもの (ntn・
  herdr-core・mise の claude・Windows の Claude Code と herdr など) を setup も switch も揃えず、上げもしない。この節と
  `references/windows-pins.md` の「merge の後」は、入れているホストでのこと
