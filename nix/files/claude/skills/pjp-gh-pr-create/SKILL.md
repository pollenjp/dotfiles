---
name: pjp-gh-pr-create
description: >-
  GitHub に PR (pull request) を作るときに読む。作った PR の Assignees に gh で認証しているユーザーを付けて
  確かめる手順 (ユーザーの既定)。gh pr create (gh pr new) を打つ前、gh api で PR を作るとき
  (POST /repos/OWNER/REPO/pulls)、「PR を出して」「PR にして」「push して PR まで」と頼まれたときに使う。
  ほかの skill や command (superpowers の finishing-a-development-branch・commit-push-pr など) の手順の途中で
  PR を作るとき、herdr の子や subagent として PR を出すとき、draft の PR を作るときも、作る前に読む
---

# pjp-gh-pr-create

GitHub に PR を作ったら、gh で認証しているユーザー (`@me`) を Assignees に付ける。ユーザーの既定なので、
付ける前に確認を取らない。ユーザーがその会話で別の assignee を言ったら、それに従う。

`@me` は gh が今の認証のユーザーの login に置き換える。どのアカウントになるかは gh の認証 (`gh auth status`・
`GH_TOKEN`・`gh auth switch`) で決まるので、仕事の PC で別のアカウントにログインしていれば、そのアカウントが付く。

## 手順

1. `gh pr create` に `--assignee @me` を足す (`-a @me` でもよい)

   ```sh
   gh pr create --assignee @me --title "…" --body "…"
   ```

2. 作った PR の Assignees に、自分の login が入っているかを確かめる (`<PR>` は gh pr create が出した URL。
   番号・branch 名でもよい)

   ```sh
   gh api user --jq .login                                        # 自分の login
   gh pr view <PR> --json assignees --jq '[.assignees[].login]'   # 自分の login が入っていればよい
   ```

3. 入っていなければ付けて、2 で確かめ直す。入らないのは、`--assignee` を付け忘れた・`gh api`
   (`POST /repos/OWNER/REPO/pulls` は assignee を受けない) や別の道具で作った・`gh pr create` が既存の PR を
   返した (`a pull request for branch … already exists`。既存の PR には `--assignee` も効かない) とき

   ```sh
   gh pr edit <PR> --add-assignee @me
   ```

4. PR を報告するときに、自分 (login) を Assignees に付けたことを添える

gh pr create が assignee を指定せずに PR を作ると、hook (`pr-assignee-nudge.sh`) が 3 をするよう知らせてくる。

## 失敗したとき

| 出たもの | 起きたこと | すること |
| --- | --- | --- |
| PR の URL のあとに `pull request update failed: …` (終了コード 1) | PR は出来ている。assignee などを付ける段で落ちた | 作り直さない。2 で確かめ、入っていなければ 3 の `gh pr edit` を打つ |
| PR の URL が出ずに `could not assign user: …` | PR は出来ていない。actor の API が無い host (古い GHES など) では、gh が PR を作る前に assignee を引く | `--assignee` を外して作り、付けられなかったことをエラーの文とともに伝える |
| `gh pr edit` が権限で落ちた・付けても Assignees に入らない | その repo で assignee を付ける権限が無い (他人の repo に fork から出す PR など) | 下の「認証」 |

## 認証

通常の gh の認証 (`gh auth login` の OAuth トークン) で足りる。PR に assignee を付けられるのは、その repo で
triage 以上の権限を持つ人なので、自分の repo・書き込める repo なら付く。

付けられないとき、別の認証に切り替えて回り込まない (`gh auth switch`・`gh auth refresh`・`GH_TOKEN` を外す・
別のトークンを使う、のどれもしない)。PR は出来たこと・assignee は付いていないこと・エラーの文をユーザーに伝える。

## 対象外

- 前からある PR にまとめて assignee を付ける・issue に付ける (頼まれたときだけ)
