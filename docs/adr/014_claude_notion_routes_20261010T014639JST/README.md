# ADR: Notion へ書く skill の宛先を、マシンではなく作業中の repo で決める

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-10-09 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-120](https://app.notion.com/p/Notion-skill-repo-3f479149a66f81c79f0bc6b937b95e3a) |
| 前提 ADR | [011](../011_claude_notion_profile_20260929T155545JST/README.md)（プロファイルを host option で選ぶ） |
| 運用手順 | [`nix/README.md`「Notion の宛先を host ごとに選ぶ」](../../../nix/README.md#notion-の宛先を-host-ごとに選ぶ) |

---

## 1. 背景 (Context)

ADR 011 では、Notion へ書く skill の宛先をマシン単位 (1 台 = 1 プロファイル) で選んだ。
work の workspace は会社のマシンで使う前提だった。

個人の PC でも仕事の org の repo を触るようになり、仕事の repo の会話も個人の
Dev Tracker へ書かれるようになった。逆に、会社の PC で個人の repo を触ることもある。

## 2. 決定 (Decision)

### A. 宛先は作業中の repo (origin の owner/repo) で決める

全マシンで共通の規則は private の claude-skills の `profiles.toml` の `[routes]` に置く。
キーは `"owner/*"` か `"owner/repo"`。owner 名を public なこのリポジトリに出さない。

### B. マシンごとの上書きは host option `dotfiles.claude.notion.routes`

共通の規則より先に見る (共通の規則の repo の行にも勝つ)。どちらにも当たらない repo と repo の外では
`dotfiles.claude.notion.profile` (このマシンの既定) を使う。既定も無ければ skill は止まる。

### C. override はプロファイルの名前ごとに書く

1 台で複数のプロファイルを使うので、`{ personal = { … }; }` の形にする。profile を書かずに
override だけで宛先を組む使い方は無くす。

### D. 認証は host option に持たせない

そのマシンに `PJP_NOTION_TOKEN_<名前>` (`~/.config/pjp/env`) があれば API キー、無ければ ntn login。
秘密は store に置けないので、host option ではなくマシンローカルの環境変数ファイルに置く。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.notion.routes` を足す。profile と override の説明を直す |
| `nix/home/modules/claude.nix` | `claude-notion.json` に routes を足す。warnings の条件から override を外す |
| `nix/tests/claude-notion.nix`・`nix/flake.nix` | JSON の中身と warnings を評価時に確かめる check (`claude-notion-state`) |
| `nix/scripts/setup-local-flake.sh` | 雛形に routes と、プロファイルごとの override の例 |
| `nix/lib/mk-home.nix` | `claude.notion.routes` のコメント |
| `nix/README.md` | 「Notion の宛先を host ごとに選ぶ」節 |

## 4. 検討した代替案

| 案 | 却下理由 |
| --- | --- |
| マシン単位のまま (ADR 011) | 1 台で仕事と個人の repo を触ると、どちらかの Dev Tracker に混ざる |
| claude-personal / claude-work の起動で切り替える | 同じアカウントで両方の repo を触るので、repo との対応にならない |
| clone ごとの git config で指定する | clone のたび・マシンのたびに設定が要り、忘れると黙って既定へ書く |
| ディレクトリの環境変数 (.envrc / devShell の .env) | Claude の環境は起動時に固まり、Bash tool は direnv を通らない |
| 規則を host option だけに書く | 同じ規則を全マシンのローカル flake に書き写すことになる |
