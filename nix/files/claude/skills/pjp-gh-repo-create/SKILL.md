---
name: pjp-gh-repo-create
description: GitHub に新しい repo を作るときに読む。gh repo create (gh repo new) を打つとき、gh api で repo を
  作るとき (POST /user/repos・/orgs/ORG/repos・テンプレートの generate)、テンプレートから作るとき、
  「GitHub に上げて」「リモートを作って push して」「新しい repo を作って」と頼まれたときに使う。
  scaffold・公開・CI の用意のような大きな作業の途中の一手として repo を作るときも、作る前に読む
---

# pjp-gh-repo-create

GitHub に repo を作ったら、続けて下の表の設定を on にする。ユーザーの既定なので、打つ前に確認を取らない。

## 設定

| 画面での名前 (Settings → General → Pull Requests) | API のフィールド | `gh repo edit` のフラグ |
| --- | --- | --- |
| Always suggest updating pull request branches | `allow_update_branch` | `--allow-update-branch` |
| Automatically delete head branches | `delete_branch_on_merge` | `--delete-branch-on-merge` |

項目を増やすときは、この表と下の 2 つのコマンドに足す。

## 手順

`gh repo create` にはこのフラグが無いので、作ってから `gh repo edit` で入れる (2 段になる)。
`gh api` やテンプレートから作ったときも同じ (作成の API も `allow_update_branch` を受けない)。

1. repo を作ったら、続けて入れる (`gh repo create NAME` のように OWNER を省いたら、OWNER は自分のアカウント)

   ```sh
   gh repo edit OWNER/REPO --allow-update-branch --delete-branch-on-merge
   ```

2. 読み直して、両方 `true` なのを確かめる

   ```sh
   gh api repos/OWNER/REPO --jq '{allow_update_branch, delete_branch_on_merge}'
   # {"allow_update_branch":true,"delete_branch_on_merge":true}
   ```

3. repo を作ったと報告するときに、この 2 つを on にしたことを添える

## 認証

通常の gh の認証 (`gh auth login` の OAuth トークン。`repo` スコープ) で足りる。設定を変える
`PATCH /repos/{owner}/{repo}` は repo の admin 権限が要り、自分のアカウントの下に作った repo なら admin を持つ。

`gh repo edit` が権限で落ちたら (HTTP 403。admin でない org の repo・`GH_TOKEN` の fine-grained PAT に
Administration の write が無い)、別の認証に切り替えて回り込まない (`gh auth refresh`・`gh auth switch`・
`GH_TOKEN` を外す・別のトークンを使う、のどれもしない)。repo は作れたこと・2 つの設定は入っていないこと・
エラーの文をユーザーに伝える。読み直しで `null` が出るのも権限が足りない印 (書き込みの権限が無いと、
この 2 つは返らない)。
