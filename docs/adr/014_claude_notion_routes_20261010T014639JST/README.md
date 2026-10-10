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

規則のキーは `"owner/*"` か `"owner/repo"`。全マシンで共通の規則は private の claude-skills の
`profiles.toml` の `[routes]` に置き、仕事の org 名を public なこのリポジトリに出さない。

### B. マシンごとの上書きは host option `dotfiles.claude.notion.routes`

共通の規則より先に見る (共通の規則の repo の行にも勝つ)。どちらにも当たらない repo と repo の外では
`dotfiles.claude.notion.profile` (このマシンの既定) を使う。既定も無ければ skill は止まる。

### C. override はプロファイルの名前ごとに書く

1 台で複数のプロファイルを使うので、`{ personal = { … }; }` の形にする。profile を書かずに
override だけで宛先を組む使い方は無くす。

### D. 認証は host option に持たせない

そのマシンに `PJP_NOTION_TOKEN_<名前>` (環境変数か `~/.config/pjp/env`) があれば API キー、無ければ
workspace ごとの ntn login。変数名はプロファイル名を大文字にし `-` を `_` にする
(personal → `PJP_NOTION_TOKEN_PERSONAL`)。ntn が読まない名前なので、ほかの workspace への呼び出しは
上書きしない。秘密は store に置けないので、host option ではなくマシンローカルの環境変数ファイルに置く。

環境にもう `NOTION_API_TOKEN` があれば、何も足さずにそれに従う (repo の devShell が `.env` で入れる token を
壊さないため)。だから `NOTION_API_TOKEN` は `~/.config/pjp/env` に書かない。シェルが環境へ読み込むので、
repo の規則で決まる認証を通らず、どの repo でもそれが使われてしまう。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.notion.routes` を足す。profile と override の説明を直す |
| `nix/home/modules/claude.nix` | `claude-notion.json` に routes を足す。warnings の条件から override を外す |
| `nix/tests/claude-notion.nix`・`nix/flake.nix` | JSON の中身と warnings を評価時に確かめる check (`claude-notion-state`) |
| `nix/scripts/setup-local-flake.sh` | 雛形に routes と、プロファイルごとの override の例。`notion.profile` が無い flake.nix への警告を「規則に当たらない repo と repo の外で止まる」に直す |
| `nix/scripts/setup.sh` | `--update` の最後の案内を、同じ言い方に直す |
| `nix/lib/mk-home.nix`・`nix/hosts/default.nix` | `claude.notion.routes` のコメント |
| `nix/README.md` | 「Notion の宛先を host ごとに選ぶ」節 |
| `docs/adr/011_…/README.md` | 冒頭の表に後続 ADR の行（本文はそのまま） |
| `docs/adr/README.md` | 一覧に 014 |

## 4. 検討した代替案

| 案 | 却下理由 |
| --- | --- |
| マシン単位のまま (ADR 011) | 1 台で仕事と個人の repo を触ると、どちらかの Dev Tracker に混ざる |
| claude-personal / claude-work の起動で切り替える | 同じアカウントで両方の repo を触るので、repo との対応にならない |
| clone ごとの git config で指定する | clone のたび・マシンのたびに設定が要り、忘れると黙って既定へ書く |
| ディレクトリの環境変数 (.envrc / devShell の .env) | Claude の環境は起動時に固まり、Bash tool は direnv を通らない |
| 規則を host option だけに書く | 同じ規則を全マシンのローカル flake に書き写すことになる |
| B: マシンごとの上書きを、profiles.toml にホスト名ごとの表として置く | マシンごとの差が共通の表に混ざり、マシンを足すたびに claude-skills を直して配ることになる。マシンごとの差は ADR 002 / 007 / 011 と同じくローカル flake に置く |
| B: repo の行を層より優先する (共通の `pollenjp/foo` が、マシンの `pollenjp/*` に勝つ) | 「このマシンでは `pollenjp/*` を全部 work に」の「全部」が効かなくなる。共通の規則に例外の repo の行があると、その repo だけ personal のまま残る。層の順番を先に決め、repo の行が owner の行に勝つのは同じ層の中だけにした |
| B: 表に当たらない repo では止まる (マシンの既定を持たない) | 規則に載せていない repo (OSS の clone など) と、repo の外で動く skill (`pjp-scan-to-notion`) が毎回止まる。マシンの既定 (`profile`) を使い、既定も無いときだけ止める |
| C: override を、選んだ 1 つのプロファイルに重ねる (ADR 011 の形) | 1 台で複数のプロファイルを使うと、どちらに重ねるのかが決まらない。プロファイルの名前ごとに書く |

## 5. 影響 (Consequences)

- 良くなること: 1 台で仕事と個人の repo を触っても、会話はそれぞれの workspace の Dev Tracker に書かれる。
  規則は全マシンで共通なので、新しいマシンでは既定の profile を選ぶだけで済む
- 注意: routes のキーと値の綴りは Nix の評価では捕まらず、skill が使うときに resolver が止める
- 注意: profile が null のマシンでは、規則に当たらない repo と repo の外で skill が止まる
  (黙って別の workspace へ書かないため)。Dev Tracker を使うマシン (`devTracker.enable = true`) では、
  switch のときに警告が出る
- 注意: override の形が変わった。外側に profiles.toml のキー (`devTracker` など) を書いた古い override は、
  resolver が書き直し方を出して止める
- 注意: 1 台で 2 つの workspace を ntn login で使うなら、ntn login は workspace ごとに要る

## 6. 検証 (Verification)

| 確認 | 結果 |
| --- | --- |
| `nix build ./nix#checks.x86_64-linux.claude-notion-state` (評価時の assert。6 項目) | 通過。既定の JSON・値を入れた JSON・profile が null なら warnings が出る・profile があれば出ない・profile が null で routes や override だけでも出る・`devTracker.enable = false` なら出ない |
| warnings の条件を壊すと、上の check が落ちる | 期待どおり、条件に `override == { }` を戻すと「routes や override だけあっても warnings が出る」の項目だけが、`cfg.devTracker.enable &&` を外すと「devTracker.enable = false なら…」の項目だけが落ちた |
| `nix flake check --all-systems --no-build ./nix` (CI と同じ。3 system) | 通過 |
| CI と同じ「`sandbox` の `config.warnings` が `[]`」 | 通過 (`[]`) |
| `nixfmt --check` / `shfmt -d` / `shellcheck` (`nix/` の `*.sh` 35 本) | 通過 |
| 雛形 (`setup-local-flake.sh`) から作ったローカル flake が評価でき、comment の例 (profile・routes・override) を外すと JSON に入る | 通過。`{"override":{"personal":{"scanData":"…"}},"profile":"personal","routes":{"pollenjp/*":"work"}}` |
| `nix/scripts/verify.sh` (flake check・sandbox の activate・冪等性) | flake check から冪等性まで通過。最後の段 (`nix/files/` の `dotfiles/` の grep) は main でも同じ 10 行が当たって落ちる既知の誤検知で、この変更は `nix/files/` に触れていない |
| claude-skills 側 (resolver の規則の順番・認証・本物の ntn をダミー API に向けた test) | claude-skills の PR で確かめる |
| 実機での switch 後の `~/.local/state/dotfiles/claude-notion.json` | 未確認。merge した後に、下の手順で確かめる |

## 7. 移行・運用手順

```sh
# dotfiles を更新して switch (claude-notion.json に routes が入る)
~/dotfiles/setup --update
cat ~/.local/state/dotfiles/claude-notion.json   # {"override":{},"profile":"personal","routes":{}}

# このマシンだけ規則を変えるなら local に書いて switch (例: 会社の PC で pollenjp の repo も work に書く)
$EDITOR ~/dotfiles/flake.nix   # local = { dotfiles.claude.notion.routes = { "pollenjp/*" = "work"; }; };
~/dotfiles/setup --update

# repo の中で、決まったプロファイルと認証を確かめる
~/.claude/skills/pjp-notion-profile/scripts/notion-profile.sh show
~/.claude/skills/pjp-notion-profile/scripts/notion-profile.sh check
```

- override を使っていたマシンは `{ <プロファイル名> = { … }; }` の形に書き直す
- 使う workspace ごとに認証を用意する: ntn login なら workspace ごとに入る。API キーなら `~/.config/pjp/env` に
  `PJP_NOTION_TOKEN_<名前>` (大文字、`-` は `_`) を書く。`NOTION_API_TOKEN` は書かない (2 節 D)
