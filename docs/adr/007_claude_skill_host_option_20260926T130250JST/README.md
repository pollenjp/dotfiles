# ADR: Claude Code の skill の on / off を host option に持たせ、settings.json へ流す経路を決める

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-09-26 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-21](https://app.notion.com/p/claude-host-option-1-pjp-dev-tracker-CLAUDE-md-skillOverrides-3e779149a66f81dfa42cdb52f3db2177) |
| 前提 ADR | [002_nix_hosts_and_local_flake](../002_nix_hosts_and_local_flake_20260810T153848JST/README.md)（マシン固有設定は option で明示する / ローカル flake の位置づけ） |
| 運用手順 | [`nix/README.md`「Claude Code の skill を host ごとに止める」](../../../nix/README.md#claude-code-の-skill-を-host-ごとに止める) |

---

## 1. 背景 (Context)

### やりたかったこと

実装作業を Notion の Dev Tracker のチケットに紐づける運用を、`pjp-dev-tracker` skill と
`~/.claude/CLAUDE.md` の「タスク管理」の節で回している (#78 / TKT-13)。これを
**会社のマシンでは発火させたくない**。個人の Notion workspace を業務のマシンから
触らせない、というだけの話だが、skill を「そのマシンでだけ」止める手段が無かった。

### 発火は 3 層で、管理主体がそれぞれ違う

| 層 | 実体 | 管理主体 |
| --- | --- | --- |
| ① CLAUDE.md の「タスク管理」の節 | `nix/files/claude/CLAUDE.md` | Nix。**全マシン共通** |
| ② skill 一覧の description | `~/.claude/skills/pjp-dev-tracker` (claude-skills への symlink) | `bootstrap-claude-skills.sh`。マシンごと |
| ③ SKILL.md 本文と `ticket.sh` | 同上 | 同上 |

Claude は ② の description だけを見て起動を決めるので、② が見えなければ自発的には
発火しない。ただし ① が「skill を読め」と命じたままだと、無い skill を探しに行く。
**② と ① を同時に切らないと壊れ方が悪い**、というのが出発点。

### ② を切る手段は settings.json にしか無い

Claude Code は `settings.json` の `skillOverrides` で skill ごとの見え方を変えられる
(`"off"` で一覧からも `/` メニューからも消える。公式 docs `skills` と、手元の 2.1.270 の
バイナリで確認)。permission rule (`Skill(pjp-dev-tracker)` を deny) もあるが、それは
Claude が呼ぼうとした時点で止める仕組みで、description は context に残る (§4)。

一方 `~/.claude/settings.json` は Claude Code 自身が書き換えるファイルなので Nix 管理下に
置けず、これまではフックの登録・statusLine・`env` を `bootstrap-claude-*.sh` が
**「足すだけ」**の形で注入してきた (`home/modules/claude.nix` の「管理しないもの」)。
「host ごとに値が違い、戻しもある」設定を settings.json へ流す経路は無かった。

### 会社のマシンは public な登録簿に載せたくない

`hosts/default.nix` は public リポジトリにある。会社のマシンの差分は
ADR 002 で用意した **ローカル flake (`~/dotfiles/flake.nix`、git 管理外)** の側に
置きたい。ところがローカル flake は登録簿を `dotfiles.homeConfigurations // { ... }` で
再輸出するだけで、**登録簿のホストに対してこのマシンだけの設定を当てる手段が無かった**。

## 2. 決定 (Decision)

### A. 「このマシンで Dev Tracker を使うか」を host option にする

`dotfiles.claude.devTracker.enable` (bool、既定 true) を `home/options.nix` に足す。
`mkHome` は `wsl` と同じ形で `claude ? { }` を受け取り、`dotfiles.claude` に入れる。

この 1 つの値から 2 層が決まる。

| 層 | enable = true | enable = false |
| --- | --- | --- |
| ① `~/.claude/CLAUDE.md` | 常時部分 + 空行 + 「タスク管理」の節 (**分割前とバイト単位で同一**) | 常時部分だけ |
| ② `settings.json` の `skillOverrides.pjp-dev-tracker` | `"on"` | `"off"` |

① のために `CLAUDE.md` を「常時部分」と「節の断片 (`CLAUDE.dev-tracker.md`)」に割り、
`claude.nix` が `text` で連結して生成する。

### B. settings.json へは「Nix が値を置き、bootstrap が写す」経路で流す

`claude.nix` が `~/.local/state/dotfiles/claude-skill-overrides.json` に
`skillOverrides` へ merge する map そのもの (`{"pjp-dev-tracker":"off"}`) を置く。
置き場は `mise.nix` の `package-manager` マーカーと同じ「Nix が script に伝える値」の場所。

新しい `nix/scripts/bootstrap-claude-skill-overrides.sh` がそれを `jq` で
`.skillOverrides` へ上書き merge する。`bootstrap-claude-env.sh` と同じ流儀で、
冪等・他のキーは保持・`bootstrap-*.sh` の自動列挙で `setup --update` に入る。

取り決めは 3 つ。

- 生成 JSON に載っている key だけ触る。`/skills` で切った他の skill には触らない
- 逆に載っている key は **option が正**で、`/skills` で手で変えても次の update で戻る
- 反映は 2 段。`home-manager switch` だけでは settings.json に届かず、
  `~/dotfiles/setup --update` (bootstrap まで走る) で揃う

`"on"` は docs 上「書かないのと同じ」だが、この key を option が所有していることが
settings.json 側からも読めるよう、enable = true でも明示して書く。

### C. ローカル flake は登録簿のホストにも当たる `local` を持ち、既定は false

本体の flake に `lib.hostsWith` を足す。登録簿の全ホストに引数の module を前置して
組み立て直すもので、`homeConfigurations` 自体が `hostsWith [ ]` になる。

`setup-local-flake.sh` の雛形は次の形になり、**`local` に
`dotfiles.claude.devTracker.enable = false` を持つ**。`~/dotfiles` 経由のマシンは
「Dev Tracker を使うところだけ true に直す」向き。会社のマシンの差分を public な
登録簿に書かずに済む。

```nix
outputs = { dotfiles, ... }:
  let
    local = { dotfiles.claude.devTracker.enable = false; };
  in {
    homeConfigurations = dotfiles.lib.hostsWith [ local ] // { ... };
  };
```

既にある `~/dotfiles/flake.nix` は触らない (雛形は初回だけ書く)。古い形のままだと
`local` が当たらないので、`setup-local-flake.sh` は `hostsWith` の無い flake.nix を
見つけたら警告する。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/options.nix` | `dotfiles.claude.devTracker.enable` (bool、既定 true) を追加 |
| `nix/lib/mk-home.nix` | `claude ? { }` を受け取り `dotfiles.claude` へ |
| `nix/flake.nix` | `hostsWith` を追加し `lib` で公開。`homeConfigurations = hostsWith [ ]` |
| `nix/home/modules/claude.nix` | `~/.claude/CLAUDE.md` を `text` で生成 (常時部分 + option で節)。`~/.local/state/dotfiles/claude-skill-overrides.json` を置く |
| `nix/files/claude/CLAUDE.md` | 「タスク管理」の節を抜く (常時部分) |
| `nix/files/claude/CLAUDE.dev-tracker.md` | 新規。抜いた節そのもの |
| `nix/scripts/bootstrap-claude-skill-overrides.sh` | 新規。生成 JSON を settings.json の `skillOverrides` へ merge (冪等) |
| `nix/scripts/setup-local-flake.sh` | 雛形に `local` (`devTracker.enable = false`) と `hostsWith` を入れる。古い雛形への警告 |
| `nix/files/claude/hooks/nix-managed-guard.sh` | 案内文に断片ファイルの 2 行を足す |
| `nix/hosts/default.nix` | ヘッダに `claude` 引数の説明 (登録簿のホストは変えない) |
| `nix/README.md` | 手順表 6.3、「登録簿に載せずにマシンを足す」の雛形、「Claude Code の skill を host ごとに止める」 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| `settings.json` に `skillOverrides` を手で書く + CLAUDE.md の文言を「一覧に無い環境では無視」にする | 今すぐ効くが、宣言が settings.json と CLAUDE.md の文言の 2 箇所に散り、片方だけ戻す事故が起きる。host の性質として残すなら option |
| SKILL.md の frontmatter `disable-model-invocation: true` | skill は git (claude-skills) で全マシンに配られるので、使うマシンでも止まる |
| `permissions.deny` に `Skill(pjp-dev-tracker)` (公式 docs `skills` の "Restrict Claude's skill access") | 呼ぼうとした時点で止める仕組みなので description は context に残り、毎回発火してから拒否される。rule 自体も settings.json にしか書けず「host ごとの値をどこで宣言するか」は解決しない。① も残る |
| `PreToolUse` フックで `Skill` tool の `pjp-dev-tracker` を deny | 上と同じく反応型。加えて hook script と登録の改修が要る |
| skill 側 (SKILL.md / `ticket.sh`) で env の印を見て何もしない | 毎回 SKILL.md を読み込む token を払い、降りるかどうかを Claude の判断に委ねる |
| `bootstrap-claude-skills.sh` に除外リストを足して symlink を張らない | ファイルまで消えるが script の改修が要る。`skillOverrides` で ② が消える以上、ファイルの有無まで気にする理由が無い |
| `home.activation` で settings.json を書く | Claude Code 所有のファイルを switch が書くことになり、「Nix 管理か否か」の線が崩れる (`bootstrap-local-env.sh` が退けたのと同じ理由) |
| CLAUDE.md を 1 ファイルのまま、Nix でマーカー間を切り抜く | `builtins.match` は複数行の切り抜きが書きづらく、節を編集したとき黙って壊れうる |
| 汎用の `dotfiles.claude.skillOverrides` (attrset をそのまま流す) | CLAUDE.md の断片との対応が名前規約頼みになる。今は 1 skill なので専用 option の方が意味が読める。生成 JSON は map の形なので、後から汎用化しても script は変えずに済む |
| ローカル flake 側で `builtins.mapAttrs (_: h: h.extendModules { modules = [ local ]; }) dotfiles.homeConfigurations` と書く | 動く (`extendModules` の結果にも `activationPackage` は残る) ので、本体に `hostsWith` を足さなくても実現はできた。それでも `hostsWith` にしたのは、ホストの構築経路を `mkHome` 1 本に保つため・雛形に module system の API を出さないため・本体の `homeConfigurations` が `hostsWith [ ]` に等しいと説明できるため |

## 5. 影響 (Consequences)

良くなること。

- 「このマシンで Dev Tracker を使うか」が host の宣言 1 つになり、CLAUDE.md の節と
  skill の可視性が構造的に揃う
- ローカル flake から登録簿のホストへ「このマシンだけの設定」を当てられるようになった
  (`hostsWith`)。Dev Tracker 以外にも使える
- settings.json にしか置けない host ごとの値を流す経路が 1 本できた
  (Nix が値を置く → bootstrap が写す)

注意が必要なこと。

- `~/.claude/CLAUDE.md` の元が 2 ファイルになる。通して読みたいときは生成物を見る
- `settings.json` の `skillOverrides.pjp-dev-tracker` は option が所有する。`/skills` で
  切り替えても次の `setup --update` で戻る (他の key は触らない)
- 反映が 2 段。`switch` 直後は CLAUDE.md だけ変わった状態があり得る。`setup --update` で揃える
- 雛形を更新しても既存の `~/dotfiles/flake.nix` は変わらない。古い形には警告が出るので、
  手で足したホストが無ければ `setup-local-flake.sh --force` で作り直す
- 自宅側 (option 既定 true、または `local` を true にしたマシン) では settings.json に
  `"pjp-dev-tracker": "on"` が 1 行増えるだけで挙動は変わらない

## 6. 検証 (Verification)

`feat/TKT-21-claude-dev-tracker-host-option` で実施。

| 確認 | 方法 | 結果 |
| --- | --- | --- |
| enable = true の CLAUDE.md が分割前と同一 | `nix eval` で `sandbox` の `home.file.".claude/CLAUDE.md".text` を取り出し `git show main:nix/files/claude/CLAUDE.md` と `diff` | 差分なし |
| enable = false で節が消え、他の節は残る | `lib.hostsWith [ { dotfiles.claude.devTracker.enable = false; } ]` の `sandbox` で同じ eval | 「タスク管理」0 件、「## 命名」1 件 |
| 生成 JSON | 同上 | true: `{"pjp-dev-tracker":"on"}` / false: `{"pjp-dev-tracker":"off"}` |
| `mkHome` の `claude` 引数 | `lib.mkHome { …; claude.devTracker.enable = false; }` の `config.dotfiles.claude.devTracker.enable` | `false` |
| bootstrap script | 使い捨て `HOME` で 18 項目 (生成 JSON 無し → exit 0 で settings 不変 / 他キーと他 skill の override を保持して merge / 2 回目は「登録済み」で不変 / on へ追随 / settings.json 無しでも作る / 壊れた JSON は exit 1 で不変・一時ファイル無し) | 18 / 18 |
| 雛形 | `DOTFILES_LOCAL_DIR` を使い捨てにして `setup-local-flake.sh` で生成し、その flake を `nix eval` | `parse_hosts` は `local` を拾わない / `sandbox` と `pollenjp@wsl` の両方で `devTracker.enable = false` / 古い雛形には警告 |
| 静的 | `nixfmt --check` / `shfmt -d` / `shellcheck` (CI と同じ集合) | 指摘なし |
| flake / activation | `./nix/scripts/verify.sh` (`nix flake check --all-systems --no-build` + sandbox の activationPackage ビルド + activate 2 回) | ここまで通過。配置一覧に `.claude/CLAUDE.md` と `.local/state/dotfiles/claude-skill-overrides.json` が出る |
| (既知) verify.sh 最後の `~~/dotfiles` 参照チェック | `grep -rn 'dotfiles/' files/` | **main でも同じ 10 件で落ちる**。`~/dotfiles` がローカル flake の正規の入口になった後に skill の文書が参照しているもので、この ADR の変更では増減していない。検査の見直しは別チケット |

## 7. 移行・運用手順

会社のマシン (Dev Tracker を使わない):

```sh
# ~/dotfiles/flake.nix が古い雛形なら作り直す (手で足したホストが無い場合)
~/dotfiles/setup --steps local-flake     # 既にあれば警告だけ。作り直すなら:
./nix/scripts/setup-local-flake.sh --force

~/dotfiles/setup --update                 # switch + bootstrap
jq .skillOverrides ~/.claude/settings.json     # {"pjp-dev-tracker":"off"}
grep -c 'タスク管理' ~/.claude/CLAUDE.md          # 0
```

Dev Tracker を使うマシン:

- 既存の `~/dotfiles/flake.nix` (古い雛形) のままなら option の既定 (true) が効く。何もしなくてよい
- 雛形を作り直したら `local` の `devTracker.enable` を `true` に直してから `setup --update`

戻す (使わない → 使う):

```sh
$EDITOR ~/dotfiles/flake.nix              # local の devTracker.enable = true
~/dotfiles/setup --update                 # "on" が merge され、CLAUDE.md に節が戻る
```
