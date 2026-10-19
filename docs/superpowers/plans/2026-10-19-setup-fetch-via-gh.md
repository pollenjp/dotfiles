# setup の取得を gh 優先にする 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `dotfiles.claude.gitViaGh.enable` が true のマシンでは、setup が GitHub から取る 4 か所 (bootstrap の 3 つの clone / 取得と、本体の更新の fetch) を `git gh` → ssh の順で試す。

**Architecture:** home-manager が option の値を `~/.local/state/dotfiles/git-via-gh.json` に書き、4 つの script が同じ関数 `git_github` でそれを読んで `git gh` → `git` の順に流す。bootstrap の pull は fetch と `merge --ff-only` に分け、ssh で取り直すのは取得の失敗だけにする。

**Tech Stack:** bash (shfmt / shellcheck、setup.sh は bash 3.2 互換)、Nix (home-manager の module・flake の `checks`・評価時の assert)、git

**Spec:** `docs/superpowers/specs/2026-10-19-setup-fetch-via-gh-design.md` (チケットは TKT-221)

## Global Constraints

- 状態ファイルは `home.file.".local/state/dotfiles/git-via-gh.json".text = builtins.toJSON { enable = cfg.gitViaGh.enable; } + "\n";` (`nix/home/modules/claude.nix`)。中身は `{"enable":true}` / `{"enable":false}`
- 読む側は jq を使わない。`[[ ${json} =~ \"enable\"[[:space:]]*:[[:space:]]*true ]]` に合うときだけ true。無い・読めない・ほかの値は false
- 関数 `git_github` の本文は 4 つの script (`setup.sh`・`bootstrap-cc-pages.sh`・`bootstrap-claude-skills.sh`・`bootstrap-dotfiles-private.sh`) で 1 字も違わない (テストが文字列の一致を見る)。本文は Task 2 のとおり
- 各 script は top-level で `git_github_hint=""` を置く (`set -u` の下で、関数を通らない経路から参照しても落ちない)
- 経路の 1 行 (`printf '  %s\n'`、stdout):
  - `gh (git gh) が見つからないので、ssh (ssh-agent) で取ります。`
  - `gh が github.com にログインしていないので、ssh (ssh-agent) で取ります。`
  - `gh の資格情報 (HTTPS) で取りました。`
  - `gh の資格情報では取れませんでした。ssh (ssh-agent) で取り直します。`
- gh で取れず ssh で取れたときの警告: `warn "gh の資格情報では取れず、ssh (ssh-agent) で取りました。" "gh の token が切れていると Claude の git (gitViaGh) も通りません。gh auth status で確かめてください。"`
- `git_github_hint` の 3 通り:
  - ssh だけで試した: `SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。`
  - gh が使えず ssh で落ちた: `gh が使えず、SSH 鍵 (ssh-agent) でも取れませんでした。gh auth login すれば ssh-agent なしで取れます。`
  - gh でも ssh でも落ちた: `gh の資格情報でも SSH 鍵 (ssh-agent) でも取れませんでした。gh auth status と ssh -T git@github.com で確かめてください。`
- `GIT_TERMINAL_PROMPT=0` と `GIT_SSH_COMMAND` の `-o BatchMode=yes` は残す。取得に失敗しても bootstrap は exit 0
- shfmt (`.editorconfig`: 2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt を通す。テストの先頭に check の名前と「## 確かめること」、判定の `grep -q` をパイプの先に置かない、偽のコマンドの shebang は `$BASH`、「gh が無い」は要るコマンドだけの PATH で作る
- テストは `GIT_CONFIG_COUNT=0` を付けて流す (Claude のセッションの `GIT_CONFIG_*` で ssh の URL が https に読み替わるのを防ぐ。`env -i` で流すテストは要らない)
- commit は日本語の `<種類>(<範囲>): … (TKT-221)`、本文の後に空行と `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 新しいファイルは `./nix` を読む (`nix build './nix#…'`) 前に `git add` する (flake は git に載ったファイルしか見ない)

## Review Focus

- 状態ファイルが無い・`{"enable":false}` のマシン (古い世代・gh を使わないマシン): 今と同じ ssh の経路だけで、gh も git-gh も呼ばず、経路の 1 行も出さない (Task 2 の関数のケース 1・2、Task 4 のケース 1)
- 状態ファイルが壊れている・`{"enable":"true"}` (文字列)・空: false と同じ (Task 2 の関数のケース 10)
- 履歴が分岐している: ssh で取り直さず、fast-forward の警告を 1 回だけ出し、手元の commit を残す (Task 2・3・4 の分岐のケース)
- `--dry-run`: `git_github` を動かさず、git-gh を呼ばず、HEAD も動かない (Task 4 のケース 5)
- `--self-update` で本体が進んで exec し直す (いちばん普通の場面): fetch で出た警告がまとめから落ちない (Task 5 のケース 16)
- jq が無い (setup.sh は Nix より前にも走る): 関数は jq なしで状態ファイルを読む (Task 2 の関数のテストは jq を PATH に入れずに流す)

---

### Task 1: option の値を状態ファイルに置く

**Files:**
- Modify: `nix/home/modules/claude.nix` (`claude-env.json` の塊の直後に 1 つ足す)
- Modify: `nix/tests/claude-env.nix` (ケースと「## 確かめること」)

**Interfaces:**
- Produces: `~/.local/state/dotfiles/git-via-gh.json` (`{"enable":true}\n` / `{"enable":false}\n`)。Task 2〜5 の `git_github` が読む

- [ ] **Step 1: テストを足す** — `nix/tests/claude-env.nix` に `viaGhOf = cfg: cfg.home.file.".local/state/dotfiles/git-via-gh.json".text;` と次のケースを足し、「## 確かめること」に 1 行足す

```nix
    {
      name = "git-via-gh.json は既定 (true) で {\"enable\":true}、false で {\"enable\":false}。改行で終わる";
      ok = viaGhOf byDefault == "{\"enable\":true}\n" && viaGhOf disabled == "{\"enable\":false}\n";
    }
```

- [ ] **Step 2: 落ちることを確かめる** — `nix build --no-link -L './nix#checks.x86_64-linux.claude-env-state'` → 評価で落ちる (`git-via-gh.json` の属性が無い)
- [ ] **Step 3: 実装する** — `claude.nix` に `".local/state/dotfiles/git-via-gh.json".text = builtins.toJSON { enable = cfg.gitViaGh.enable; } + "\n";` の塊を足す。上のコメントに、読むのは nix/scripts/ の `git_github` (setup の取得) で、setup.sh は Nix より前にも走るので jq なしで読める形にし、値によらず必ず書くこと (TKT-221)
- [ ] **Step 4: 通ることを確かめる** — Step 2 の build が成功し、`ok   git-via-gh.json は…` が出る。`nix develop ./nix --command nixfmt --check nix/home/modules/claude.nix nix/tests/claude-env.nix`
- [ ] **Step 5: commit** — `feat(claude): gitViaGh.enable の値を ~/.local/state/dotfiles/git-via-gh.json に置く (TKT-221)`

### Task 2: 関数 git_github と、bootstrap-dotfiles-private の取得

**Files:**
- Create: `nix/tests/git-github-helpers.test.sh`
- Modify: `nix/flake.nix` (`warn-helpers-test` の次に `git-github-helpers-test = scriptTest "git-github-helpers" ./scripts;`。上に「script 1 本ではなく scripts/ を丸ごと渡す (git_github を持つ script を全部見る)」)
- Modify: `nix/scripts/bootstrap-dotfiles-private.sh` (先頭のコメント・`--help`・`git_github_hint`・`git_github`・取得と clone)
- Modify: `nix/tests/bootstrap-dotfiles-private.test.sh`

**Interfaces:**
- Consumes: Task 1 の状態ファイル
- Produces: `git_github <git の引数>…` — 終了コードは取れたら 0、取れなければ git の終了コード。グローバル `git_github_hint` (取れなかったときの案内 1 行)。`warn` / `summary_warn` を使う。Task 3〜5 はこの本文をそのまま写す

関数の本文 (4 つの script で同じ。上に置くコメントは script ごとでよいが、意味は「GitHub と通信する git (clone / fetch) を流す。gitViaGh のマシンは gh → ssh。jq を使わない。4 つの script に同じ形 (git-github-helpers.test.sh)」):

```bash
git_github() {
  local state="${HOME}/.local/state/dotfiles/git-via-gh.json" json="" rc=0
  git_github_hint=""
  if [[ -r ${state} ]]; then
    json=$(<"${state}") || json=""
  fi
  if ! [[ ${json} =~ \"enable\"[[:space:]]*:[[:space:]]*true ]]; then
    git "$@" || rc=$?
    if ((rc != 0)); then
      git_github_hint="SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。"
    fi
    return "${rc}"
  fi
  if ! command -v gh &>/dev/null || ! command -v git-gh &>/dev/null; then
    printf '  %s\n' "gh (git gh) が見つからないので、ssh (ssh-agent) で取ります。"
  elif ! gh auth token --hostname github.com &>/dev/null; then
    printf '  %s\n' "gh が github.com にログインしていないので、ssh (ssh-agent) で取ります。"
  else
    git gh "$@" || rc=$?
    if ((rc == 0)); then
      printf '  %s\n' "gh の資格情報 (HTTPS) で取りました。"
      return 0
    fi
    printf '  %s\n' "gh の資格情報では取れませんでした。ssh (ssh-agent) で取り直します。"
    rc=0
    git "$@" || rc=$?
    if ((rc == 0)); then
      warn "gh の資格情報では取れず、ssh (ssh-agent) で取りました。" \
        "gh の token が切れていると Claude の git (gitViaGh) も通りません。gh auth status で確かめてください。"
      return 0
    fi
    git_github_hint="gh の資格情報でも SSH 鍵 (ssh-agent) でも取れませんでした。gh auth status と ssh -T git@github.com で確かめてください。"
    return "${rc}"
  fi
  git "$@" || rc=$?
  if ((rc != 0)); then
    git_github_hint="gh が使えず、SSH 鍵 (ssh-agent) でも取れませんでした。gh auth login すれば ssh-agent なしで取れます。"
  fi
  return "${rc}"
}
```

- [ ] **Step 1: 関数のテストを書く** — `nix/tests/git-github-helpers.test.sh` (`warn-helpers.test.sh` と同じ骨組み。引数は scripts のディレクトリ)
  - `expected=(bootstrap-dotfiles-private.sh)` (Task 3〜5 で足す)。この全部が `git_github() {` を定義していなければ落ちる。定義する script が 1 つも無くても落ちる
  - 各 script から `git_github`・`warn`・`summary_warn` の定義を awk で切り出す。`git_github` の本文が script 間で 1 字でも違えば落ちる
  - 偽の `git` (引数を `${FAKE_LOG}` に 1 行で書き、`$1 == gh` なら `${FAKE_GH_RC:-0}`、ほかは `${FAKE_SSH_RC:-0}` で終わる)・偽の `gh` (`auth token` なら `${FAKE_GH_AUTH_RC:-0}`)・中身が `exit 99` の `git-gh` を置く。gh と git-gh は別のディレクトリに置き、「gh 無し」はそれを PATH に入れない。PATH には jq を入れない
  - 1 回の呼び出しは `"${BASH}" -c` に定義と `set -eu -o pipefail; rc=0; git_github -C /x fetch --quiet || rc=$?; printf 'RC=%s\nHINT=%s\n' "${rc}" "${git_github_hint}"` を渡し、stdout・stderr・`FAKE_LOG`・まとめのファイル (`DOTFILES_SETUP_WARNINGS`) を残す。`c_yellow=""`・`c_reset=""` を渡す (setup.sh の warn が使う)
  - ケース (script ごと):

| # | 状態ファイル・PATH・偽の終了コード | 期待 |
| --- | --- | --- |
| 1 | 無し | FAKE_LOG は `-C /x fetch --quiet` の 1 行だけ。stdout は `RC=0` と空の `HINT=` だけ。stderr 空 |
| 2 | `{"enable":false}` | 1 と同じ |
| 3 | `{"enable":true}`・gh 無し | FAKE_LOG は ssh の 1 行だけ。stdout に `gh (git gh) が見つからないので` |
| 4 | true・`FAKE_GH_AUTH_RC=1` | FAKE_LOG は ssh の 1 行だけ。stdout に `ログインしていないので` |
| 5 | true・gh で取れる | FAKE_LOG は `gh -C /x fetch --quiet` の 1 行だけ。stdout に `gh の資格情報 (HTTPS) で取りました。`。stderr とまとめは空 |
| 6 | true・`FAKE_GH_RC=1` | FAKE_LOG は gh の行、ssh の行の順。stdout に `取り直します`。stderr は `!! gh の資格情報では取れず、ssh (ssh-agent) で取りました。` で始まり、まとめのファイルの 1 行目も同じ文 (`!! ` 無し)。`RC=0` |
| 7 | true・`FAKE_GH_RC=1 FAKE_SSH_RC=128` | `RC=128`。`HINT=` が `gh auth status` と `ssh -T git@github.com` を含む |
| 8 | 無し・`FAKE_SSH_RC=128` | `RC=128`。`HINT=SSH 鍵 (ssh-agent) で取れませんでした。…`、`gh` を含まない |
| 9 | true・`FAKE_GH_AUTH_RC=1 FAKE_SSH_RC=128` | `RC=128`。`HINT=` が `gh auth login` を含む |
| 10 | `{ "enable" : true }` (空白と改行入り) は 5 と同じ。`{"enable":"true"}`・空のファイル・`not json` は 1 と同じ | |
| 11 | true・gh で取れる・引数 `clone git@github.com:o/r.git /tmp/d` | FAKE_LOG は `gh clone git@github.com:o/r.git /tmp/d` |

- [ ] **Step 2: bootstrap-dotfiles-private のテストを足す** — `bootstrap-dotfiles-private.test.sh` の先頭で `export GIT_CONFIG_COUNT=0`。偽の `gh` (`auth token` なら `${FAKE_GH_AUTH_RC:-0}`) と偽の `git-gh` (`"$*"` を `${GITGH_LOG}` に足し、`FAKE_GITGH_FAIL=1` なら stderr に一言出して 128、でなければ `exec git "$@"`) を `${work}/fake-bin` に置く。`run_gh` は HOME に `{"enable":true}` の状態ファイルを置き、`PATH="${work}/fake-bin:${PATH}" GITGH_LOG="${h}/gitgh.log"` を付けて `run` と同じく流す。ケース:
  - 8: `run_gh` で clone → rc 0・辞書がある・`gitgh.log` の 1 行目が `clone ` で始まる・`gh の資格情報 (HTTPS) で取りました。`
  - 9: bare repo に commit を足して `run_gh` → 追いつく・`gitgh.log` に `fetch --quiet` を含む行・`更新しました`
  - 10: commit を足して `FAKE_GITGH_FAIL=1 DOTFILES_SETUP_WARNINGS=…` で `run_gh` → 追いつく・`取り直します`・まとめの 1 行目が `gh の資格情報では取れず、ssh (ssh-agent) で取りました。`
  - 11: clone で commit してから bare repo に別の commit を足し、`run_gh` → rc 0・`fast-forward できません`・`取り直します` を含まない・HEAD は手元の commit のまま
  - 12: 状態ファイル `{"enable":false}` で fake-bin を PATH に入れて流す → 追いつく・`gitgh.log` が無い
  - 7 の期待を変える: まとめの続きの行は `^[[:space:]]+SSH 鍵 \(ssh-agent\) で取れませんでした`、その場の続きの行は `   SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。` に `grep -qx` で合う
- [ ] **Step 3: 落ちることを確かめる** — `git add -A nix/tests && bash nix/tests/git-github-helpers.test.sh nix/scripts` (定義が無くて落ちる)、`bash nix/tests/bootstrap-dotfiles-private.test.sh` (8〜12 と 7 が落ちる)
- [ ] **Step 4: 実装する** — `bootstrap-dotfiles-private.sh`:
  - `summary_warn` の後に `git_github` を置き、`repo_url=` の近くに `git_github_hint=""`
  - pull を `git_github -C "${dir}" fetch --quiet` と `git -C "${dir}" merge --ff-only --quiet '@{u}'` に分ける。取得の失敗は `warn "取得 (fetch) に失敗しました。手元の clone のまま続けます: ${dir}" "${git_github_hint}"`、merge の失敗は `warn "fast-forward できません。手元の clone のまま続けます: ${dir}" "履歴が分岐していないか確かめてください: git -C ${dir} status"`。どちらも exit 0
  - clone を `git_github clone --quiet "${repo_url}" "${dir}"` にし、失敗の警告の 2 行目 (SSH 鍵が要ります) を `"${git_github_hint}"` に置き換える (3 行目の「取れないあいだ…」は残す)
  - 先頭のコメントの「何をするか」と `--help` に、gitViaGh のマシンでは gh の資格情報で先に取り、だめなら ssh で取ること (TKT-221) を足す
- [ ] **Step 5: flake の check を足して通す** — `nix/flake.nix` に `git-github-helpers-test` を足し、`git add -A` してから `nix build --no-link -L './nix#checks.x86_64-linux.git-github-helpers-test' './nix#checks.x86_64-linux.bootstrap-dotfiles-private-test' './nix#checks.x86_64-linux.warn-helpers-test'` → 3 つとも成功
- [ ] **Step 6: lint** — `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-dotfiles-private.sh nix/tests/git-github-helpers.test.sh nix/tests/bootstrap-dotfiles-private.test.sh && shellcheck nix/scripts/bootstrap-dotfiles-private.sh nix/tests/git-github-helpers.test.sh nix/tests/bootstrap-dotfiles-private.test.sh && nixfmt --check nix/flake.nix && ./nix/scripts/check-test-grep-q.sh'` と `./nix/scripts/check-test-headers.sh`
- [ ] **Step 7: commit** — `feat(nix): bootstrap-dotfiles-private の取得を、gitViaGh のマシンでは gh の資格情報で先に試す (TKT-221)`

### Task 3: bootstrap-cc-pages の取得

**Files:**
- Modify: `nix/scripts/bootstrap-cc-pages.sh` (先頭のコメント・`--help`・`git_github_hint`・`git_github` (`run` の後)・取得と clone)
- Modify: `nix/tests/bootstrap-cc-pages.test.sh` (取得のケースと「## 確かめること」)
- Modify: `nix/tests/git-github-helpers.test.sh` (`expected` に `bootstrap-cc-pages.sh`)

**Interfaces:**
- Consumes: Task 2 の `git_github` の本文 (そのまま写す)

- [ ] **Step 1: テストを足す** — `GIT_CONFIG_COUNT=0`。bare repo と、それを clone した `${work}/cc` を用意する。要るコマンド (git・mkdir・dirname・cat・rm・ln・env) だけを symlink で並べた PATH に Task 2 と同じ偽の gh・git-gh を足し、go は入れない (ビルドの手前の「go が見つかりません」で止まる)。`--dir "${work}/cc"` と使い捨ての HOME で流す。ケース:
  - gh で取得: bare repo に commit を足し、状態ファイル true で流す → rc 0・HEAD が bare repo と同じ・`gh の資格情報 (HTTPS) で取りました。`・`gitgh.log` に `fetch` を含む行・`go が見つかりません`
  - gh で落ちて ssh: `FAKE_GITGH_FAIL=1` → 追いつく・まとめの 1 行目が `gh の資格情報では取れず、ssh (ssh-agent) で取りました。`
  - 履歴の分岐: 手元に commit し bare repo に別の commit → rc 0・`fast-forward できませんでした`・`取り直します` を含まない・HEAD は手元の commit
  - `--status` の既存のケースはそのまま通る
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/bootstrap-cc-pages.test.sh` と `bash nix/tests/git-github-helpers.test.sh nix/scripts` が落ちる
- [ ] **Step 3: 実装する** — `git_github` を `run` の後に写し、`repo_url=` の近くに `git_github_hint=""`。`run git -C "${dir}" pull --ff-only` を `run git_github -C "${dir}" fetch` (失敗: `warn "取得できませんでした。手元のクローンのまま続けます。" "${git_github_hint}"`) と `run git -C "${dir}" merge --ff-only '@{u}'` (失敗: `warn "fast-forward できませんでした。手元のクローンのまま続けます。" "履歴が分岐していないか確かめてください: git -C ${dir} status"`) に分け、どちらも `stale=1`。clone を `run git_github clone "${repo_url}" "${dir}"` にし、失敗の警告に `"${git_github_hint}"` を足す。先頭のコメント (`## 何をするか`・`## cc-pages へアクセスできないマシンでも止まらない`) と `--help` に gh を先に試すことを足す
- [ ] **Step 4: 通ることを確かめる** — `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-cc-pages-test' './nix#checks.x86_64-linux.git-github-helpers-test'` が成功
- [ ] **Step 5: lint** — Task 2 の Step 6 と同じ (対象を `bootstrap-cc-pages.sh` と 2 つのテストに)
- [ ] **Step 6: commit** — `feat(nix): bootstrap-cc-pages の取得を、gitViaGh のマシンでは gh の資格情報で先に試す (TKT-221)`

### Task 4: bootstrap-claude-skills の取得

**Files:**
- Modify: `nix/scripts/bootstrap-claude-skills.sh` (先頭のコメント・`--help`・`git_github_hint`・`git_github` (`run` の後)・`ensure_clone`)
- Create: `nix/tests/bootstrap-claude-skills.test.sh` (check `bootstrap-claude-skills-test`)
- Modify: `nix/flake.nix` (`bootstrap-cc-pages-test` の次に `bootstrap-claude-skills-test = scriptTest "bootstrap-claude-skills" ./scripts/bootstrap-claude-skills.sh;`)
- Modify: `nix/tests/git-github-helpers.test.sh` (`expected` に `bootstrap-claude-skills.sh`)

**Interfaces:**
- Consumes: Task 2 の `git_github` の本文

- [ ] **Step 1: テストを書く** — 先頭に check の名前と「## 確かめること」(取得の側だけを確かめ、clone の URL は固定なので clone は見ないこと)。`GIT_CONFIG_COUNT=0`。bare repo に `skills/a/SKILL.md` を置いて clone し、`--dir` と使い捨ての HOME で流す。偽の gh・git-gh は Task 2 と同じ。ケース:
  - 1: 状態ファイル無し・fake-bin を PATH に入れて、bare repo に `skills/b/SKILL.md` を足して流す → rc 0・`~/.claude/skills/b` が clone の `skills/b` を指す・`gitgh.log` が無い
  - 2: true → bare repo に commit を足して流す → 追いつく・`gh の資格情報 (HTTPS) で取りました。`・`gitgh.log` に `fetch` を含む行
  - 3: true・`FAKE_GITGH_FAIL=1` → 追いつく・まとめの 1 行目が `gh の資格情報では取れず、ssh (ssh-agent) で取りました。`
  - 4: 履歴の分岐 → rc 0・`fast-forward できません`・`claude-skills を更新できていません`・`取り直します` を含まない・リンクは残る
  - 5: `--dry-run` → stdout に `+ git_github -C <dir> fetch`・`gitgh.log` が増えない・HEAD が動かない
- [ ] **Step 2: 落ちることを確かめる** — `git add nix/tests/bootstrap-claude-skills.test.sh && bash nix/tests/bootstrap-claude-skills.test.sh` が落ちる
- [ ] **Step 3: 実装する** — `git_github` を `run` の後に写し、`repo_url=` の近くに `git_github_hint=""`。`ensure_clone` の pull を `run git_github -C "${dir}" fetch` (失敗: `warn "取得 (fetch) に失敗しました。手元のクローンのまま続けます: ${dir}" "${git_github_hint}"`) と `run git -C "${dir}" merge --ff-only '@{u}'` (失敗: `warn "fast-forward できません。手元のクローンのまま続けます: ${dir}" "履歴が分岐していないか確かめてください: git -C ${dir} status"`) に分け、どちらも `stale=1`。clone を `run git_github clone "${repo_url}" "${dir}"` にし、失敗の警告の続きの行 (SSH 鍵が要ります・ssh -T) を `"${git_github_hint}"` に置き換える。先頭のコメントと `--help` に gh を先に試すことを足す
- [ ] **Step 4: flake の check を足して通す** — `nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-claude-skills-test' './nix#checks.x86_64-linux.git-github-helpers-test'` が成功
- [ ] **Step 5: lint** — Task 2 の Step 6 と同じ (対象を `bootstrap-claude-skills.sh`・2 つのテスト・`flake.nix` に)
- [ ] **Step 6: commit** — `feat(nix): bootstrap-claude-skills の取得を、gitViaGh のマシンでは gh の資格情報で先に試す (TKT-221)`

### Task 5: setup.sh の本体の更新

**Files:**
- Modify: `nix/scripts/setup.sh` (`git_github_hint` を大域の変数の並びに・`git_github` を `run` の後に・`pull_repo` の fetch・`self_update_and_reexec` で警告を env で渡す・警告の置き場を作った直後に書き戻す・`--help` の「本体の更新」・「本体の更新 (--self-update)」の節のコメント)
- Modify: `nix/tests/setup-post-notes.test.sh` (ケース 15・16 と「## 確かめること」)
- Modify: `nix/tests/git-github-helpers.test.sh` (`expected` に `setup.sh`。これで 4 つ)
- Modify: `nix/README.md` (「途中の警告のまとめ」の `[本体の更新]` の説明)

**Interfaces:**
- Consumes: Task 2 の `git_github` の本文

- [ ] **Step 1: テストを足す** — 今の 14 番と同じ組み立て (bare の origin・別の clone から 1 commit 進める・`sed` で shebang を `$BASH` に) で 2 つ足す。`env -i` で流すので、偽の git-gh は書き留め先 (`<ケース>/gitgh.log`) を中に書き込んで作る。HOME (`<ケース>/home`) に `{"enable":true}` の状態ファイルを置き、`PATH_EXTRA="<偽の gh と git-gh>:${git_bin}"`
  - 15: git-gh は書き留めて `exec git "$@"` → rc 0・`next.txt` がある・`gitgh.log` に `fetch origin main` を含む行・`途中で出た警告` が出ない
  - 16: git-gh は落ちる → rc 0・`next.txt` がある (本体が進んで exec し直した)・`新しい setup.sh で続けます`・結果の後に `[本体の更新]` と `gh の資格情報では取れず、ssh (ssh-agent) で取りました。`・`tmp_left` が空
  - 17: `DOTFILES_SETUP_SELF_UPDATE_WARNINGS` を外から渡しても、exec されたのでなければ (`DOTFILES_SETUP_SELF_UPDATED` が無い) まとめに載らない
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/setup-post-notes.test.sh` (15・16 が落ちる)、`bash nix/tests/git-github-helpers.test.sh nix/scripts` (setup.sh に定義が無い)
- [ ] **Step 3: 実装する** — `git_github` を `run` の後に写す (bash 3.2 で動く書き方のまま)。`pull_repo` の `run git -C "${repo_dir}" fetch "${remote}" "${branch}"` を `run git_github …` にし、失敗の警告に続きの行 `"${git_github_hint}"` を足す。`self_update_and_reexec` の `cleanup_warnings` の前で、`${warn_dir}/self-update` が空でなければ中身を `DOTFILES_SETUP_SELF_UPDATE_WARNINGS` に入れて export する。top-level の `warn_dir=$(mktemp …)` の直後で、`self_updated == 1` かつ値があれば `${warn_dir}/self-update` へ書き戻し (書けなくても黙って続ける)、値の有無によらず unset する。`--help` の「本体の更新」に「gitViaGh.enable のマシンでは fetch を gh の資格情報で先に試し、だめなら ssh で取り直す」の 1 行。`--self-update` の節のコメントにも同じこと。README「途中の警告のまとめ」の `[本体の更新]` の説明を「本体の更新で出た警告 (更新しなかった理由や、fetch を gh で取れず ssh で取ったこと)。本体を更新して exec し直したときも、新しい setup が引き継ぐ」に
- [ ] **Step 4: 通ることを確かめる** — `nix build --no-link -L './nix#checks.x86_64-linux.setup-post-notes-test' './nix#checks.x86_64-linux.git-github-helpers-test' './nix#checks.x86_64-linux.warn-helpers-test'` が成功
- [ ] **Step 5: lint** — Task 2 の Step 6 と同じ (対象を `setup.sh` と 2 つのテストに)
- [ ] **Step 6: commit** — `feat(nix): setup の本体の更新の fetch を、gitViaGh のマシンでは gh の資格情報で先に試す (TKT-221)`

### Task 6: 文書と全体の確かめ

**Files:**
- Modify: `nix/README.md` (「fetch 系を gh の資格情報で通す (git gh)」に setup の取得の小節・「本体を最新にする (`--self-update`)」に 1 行・claude-skills と cc-pages の「取得できないマシンでも止まらない」の表)
- Modify: `nix/home/options.nix` (冒頭の一覧の gitViaGh の行と、gitViaGh.enable の description)
- Modify: `nix/hosts/default.nix`・`nix/lib/mk-home.nix`・`nix/scripts/setup-local-flake.sh`・`nix/home/modules/packages.nix`・`nix/pkgs/git-gh/default.nix` (gitViaGh の意味・git gh を使うものの一覧のコメントに setup の取得を足す)

- [ ] **Step 1: README を書く** — setup の取得の小節に: 4 か所、流れ (状態ファイル → gh・git-gh・`gh auth token` → `git gh` → ssh)、経路の 1 行と警告の出方 (gh で取れず ssh で取れたときはまとめにも出す・gh が使えずに ssh へ回したときは出さない)、bootstrap は取得と fast-forward を分けたこと、状態ファイル (`git-via-gh.json`) は home-manager が置くので switch の後に効く (本体の更新は前の世代の値) こと。claude-skills と cc-pages の表は「取得できない」「fast-forward できない」の 2 行にし、gh を先に試す小節へリンクする
- [ ] **Step 2: option とコメントを直す** — description の「自分のターミナルでは…」の段落の後に、setup の取得 (bootstrap の clone / 取得と本体の更新の fetch) も gh を先に試し、gh が使えない・取れないときは ssh で取り直すこと、値は `~/.local/state/dotfiles/git-via-gh.json` (home/modules/claude.nix) に落ちること。ほかのコメントは「Claude の git と fetch 系の abbr / alias」を「Claude の git と fetch 系の abbr / alias と setup の取得」に
- [ ] **Step 3: 全体を確かめる** — `nix develop ./nix --command bash -c 'mapfile -t f < <(find nix -type f -name "*.sh" | sort); shfmt -d "${f[@]}" && shellcheck "${f[@]}"'`・`nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'`・`./nix/scripts/check-test-headers.sh`・`nix develop ./nix --command ./nix/scripts/check-test-grep-q.sh`・`nix flake check ./nix` がどれも通る
- [ ] **Step 4: 実機で確かめる** — この worktree の script を、今の herdr のペイン (SSH_AUTH_SOCK が切れている) で `GIT_CONFIG_COUNT=0` を付けて流す: `HOME` はそのままで、`bash nix/scripts/bootstrap-claude-skills.sh --dry-run` と、状態ファイルを手で置いた使い捨ての HOME で `bash nix/scripts/bootstrap-dotfiles-private.sh` (`DOTFILES_PRIVATE_DIR` を使い捨ての場所に) を流し、`gh の資格情報 (HTTPS) で取りました。` で clone できることを見る
- [ ] **Step 5: commit** — `docs(nix): setup の取得を gh で先に試すことを README・option の説明・コメントに書く (TKT-221)`
