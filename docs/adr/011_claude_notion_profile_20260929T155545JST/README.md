# ADR: Notion へ書く skill の宛先をプロファイルで選び、名前と上書きだけを host option に持たせる

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-09-29 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-44](https://app.notion.com/p/Notion-skill-workspace-DB-URL-3e979149a66f810a87cbc3357dada5f3) |
| 前提 ADR | [002](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)（ローカル flake）/ [007](../007_claude_skill_host_option_20260926T130250JST/README.md)（`dotfiles.claude.*` と `~/.local/state/dotfiles/` の JSON） |
| 運用手順 | [`nix/README.md`「Notion の宛先を host ごとに選ぶ」](../../../nix/README.md#notion-の宛先を-host-ごとに選ぶ) |

---

## 1. 背景 (Context)

- private な `claude-skills` に、Notion へ書く skill が 4 つある（`pjp-dev-tracker`・`pjp-notion-authoring`・`pjp-docs-to-notion`・`pjp-scan-to-notion`）
- 書き込み先の workspace とページ・DB はマシンによって違う（会社のマシンは仕事の workspace、自宅は個人の workspace）
- 宛先を持っていたのは `pjp-dev-tracker` だけで、`ticket.py` の先頭に直書きしていた。他の 3 つは毎回決めるか聞いていた
- 値（ページ名入りの URL）は public なこのリポジトリに書きたくない。一方で「どのマシンがどれを使うか」は ADR 002 / 007 と同じくローカル flake で宣言したい

## 2. 決定 (Decision)

### A. host option は「名前」と「このマシンだけの上書き」の 2 つだけにする

`home/options.nix` に `dotfiles.claude.notion.profile`（`null` か `[a-z0-9][a-z0-9_-]*`、既定 `null`）と
`dotfiles.claude.notion.override`（JSON にできる値の attrset、既定 `{}`）を足す。

### B. 値は claude-skills のプロファイルが持つ

workspace の id・Dev Tracker の場所・既定の親ページ・Scan Data DB は、`claude-skills` の
`skills/pjp-notion-profile/profiles.toml` に `[personal]` / `[work]` の表として置く。キーの形
（スキーマ）も同じ skill の resolver が持ち、このリポジトリはキーの意味を知らない。

### C. JSON 1 つで渡す

`home/modules/claude.nix` が `~/.local/state/dotfiles/claude-notion.json`
（`{"override":{…},"profile":"personal"}`）を置く。null / 空でも必ず書く（「dotfiles が古い」と
「選んでいない」を resolver が見分けて案内するため）。resolver は profile の値へ override を
入れ子ごとに重ね（同じキーは override、null はキーを消す）、決まらなければ skill を止める。

### D. ローカル flake の雛形は `profile = null`

選ぶまで skill は止まる。黙って個人の workspace へ倒すと、会社のマシンで個人の workspace へ
書きに行くため。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.notion.{profile,override}` |
| `nix/home/modules/claude.nix` | `~/.local/state/dotfiles/claude-notion.json` を書く。Dev Tracker を使うのに宛先が未設定なら `warnings` を出す |
| `nix/scripts/setup.sh` | `--update` の最後の案内を「local が無いと宛先を選べず止まる」に直し、`notion.profile` の無い flake.nix も知らせる |
| `nix/scripts/setup-local-flake.sh` | 雛形の `local` に `dotfiles.claude.notion.profile = null;` と override の例。既存の flake.nix に無ければ警告 |
| `nix/lib/mk-home.nix`・`nix/hosts/default.nix` | `claude.notion.profile` のコメント。検証用の `sandbox` には `claude.notion.profile = "personal"` を渡す（CI の「warnings が空」を満たすため） |
| `nix/README.md` | 「Notion の宛先を host ごとに選ぶ」節、配置の表 |

## 4. 検討した代替案

| 案 | 却下理由 |
| --- | --- |
| override を型付きの option にする（`dotfiles.claude.notion.override.devTracker.hub` など） | キーの定義が public なこのリポジトリにも要り、キーを足すたびに両方の repo を直すことになる |
| `home.sessionVariables` の環境変数で渡す | シェルを通らない起動（herdr・IDE）で届かず、変えたらログインし直しが要る |
| 値そのものをローカル flake に書く | 版管理されず、同じ値を個人用のマシンごとに書き写すことになる |
| 値を `hosts/default.nix` に書く | ページ名入りの URL が公開される |
| 未設定なら personal に倒す | 会社のマシンで個人の workspace へ書きに行く |

## 5. 影響 (Consequences)

- 良くなること: public に出るのは option 2 つと JSON の置き場所だけ。宛先のキーを足すときは `claude-skills` だけ直せばよい。値がファイルで渡るので、どの起動経路でも同じ宛先になる
- 注意: override のキーの綴りは Nix の評価では捕まらず、skill が使うときに resolver が止める
- 注意: 選んでいないマシン（雛形のまま）では Notion へ書く skill が止まる。止まったら `local` に `profile` を書いて switch する。Dev Tracker を使うマシン（`devTracker.enable = true`）では switch のときに警告が出る
- 注意: 登録簿のホストは profile を持たないので、`nix flake check`（CI）と `verify.sh` の評価でも同じ警告が trace として出る。失敗にはならない

## 6. 検証 (Verification)

| 確認 | 結果 |
| --- | --- |
| `nix/scripts/verify.sh`（flake check・sandbox の activate・冪等性） | ✅ flake check・sandbox の build・配置の一覧（`claude-notion.json` が出る）・activate・冪等性まで通過。最後の段（`nix/files/` の `dotfiles/` の grep）は main でも同じ 10 行が当たって落ちる既知の誤検知で、この変更は `nix/files/` に触れていない |
| nixfmt / shfmt / shellcheck | ✅ |
| 既定（`local` 無し）の `claude-notion.json` | ✅ `{"override":{},"profile":null}` |
| `local` で profile と override を当てた `claude-notion.json` | ✅ `{"override":{"devTracker":{"hub":"0123456789abcdef0123456789abcdef"},"scanData":null},"profile":"personal"}` |
| profile に `"Work"` を入れると評価で落ちる | ✅ `is not of type` |
| CI と同じ「`sandbox` の `config.warnings` が `[]`」 | ✅ `[]` |
| `config.warnings`（登録簿の `pollenjp@laptop`） | ✅ 未設定なら警告 1 件、`profile = "personal"` を当てると `[]`、`devTracker.enable = false` なら `[]` |
| 雛形から作ったローカル flake が評価でき、`notion.profile` の無い flake.nix で警告が出る | ✅ |

## 7. 移行・運用手順

```sh
# 既存のマシン: local に書いて switch
$EDITOR ~/dotfiles/flake.nix      # local = { dotfiles.claude.notion.profile = "personal"; ... };
~/dotfiles/setup --update
cat ~/.local/state/dotfiles/claude-notion.json
```

`~/dotfiles/flake.nix` が古い雛形（`local` / `hostsWith` が無い）なら、手で足したホストが無いことを
確かめてから `setup-local-flake.sh --force` で作り直し、`local` に書く。
