#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code のセッションにだけ渡す git の設定を ~/.claude/settings.json の env へ登録する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# ## 何のために
#
# 1. commit を無署名にする (いつも)。
#    このマシンの git は 1Password の op-ssh-sign で署名する設定
#    (git.nix の signing / commit.gpgSign)。署名のたびにホスト側 Windows の
#    1Password が承認ダイアログを出すので、Claude に commit させるとそこで止まる。
#    Claude のセッションからの commit だけ署名を外す。
# 2. GitHub との通信を gh の資格情報 (HTTPS) にする (dotfiles.claude.gitViaGh.enable、既定 true)。
#    ssh は WSL の ssh.exe (1Password の agent) を通るので、interop が外れると
#    Exec format error で落ち、通っても承認ダイアログで止まる。gh は HTTPS の API なので
#    どちらにも依らない。false のマシンは今までどおり ssh を通る。
#
# ## なぜ env なのか
#
# git は GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> で渡した
# config を **config ファイルより優先**する。これを settings.json の env に置くと、
#
#   - Claude のセッション (Bash tool) にだけ効く。自分の手元のターミナルからの
#     commit は今どおり 1Password で署名され、push も今どおり ssh を通る
#   - git commit 直打ちでも --amend でも rebase --continue でも git tag でも効く。
#     「--no-gpg-sign を付ける」という指示と違い、忘れる余地が無い
#   - skill が打つ素の `git push -u origin …` も HTTPS になる。origin 名のまま通るので
#     origin/<branch> も普段どおり進む
#
# 他の案を採らなかった理由 (無署名):
#
#   CLAUDE.md に指示を書く    soft な指示なので忘れうる。常時トークンも食う
#   repo local の gpgsign     自分の commit も無署名になる。repo ごとに要る
#   includeIf gitdir:         worktree の外で Claude が commit すると効かず、
#                             逆に worktree で自分が commit すると無署名になる
#   PreToolUse で deny        効くが bash 文字列の解析 (複合コマンド・クォート)
#                             が要る。env で足りる
#
# 他の案を採らなかった理由 (HTTPS):
#
#   CLAUDE.md に指示を書く    soft な指示なので忘れうる。URL を直に指定する push は
#                             origin/<branch> を進めない
#   global の git config      自分の push も 1Password の ssh を通らなくなる
#   pushInsteadOf (push だけ) fetch / pull は ssh.exe を通るまま
#
# Claude Code 自身も条件によって同じ仕組みで credential.interactive=false を注入するが、
# **既存の GIT_CONFIG_COUNT を読んでその先に足す**実装なので競合しない
# (このマシンの Bash tool の env には出ていない。本体に処理があることは確認済み)。
#
# credential helper を空値で消す組 (`credential.helper=`) は入れない。Claude Code が
# 空文字の env を渡さなかった場合、GIT_CONFIG_VALUE_<n> が欠けて git が
# 「unable to parse command-line config」で全部落ちるため。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/claude-env.json (nix/home/modules/claude.nix):
#
#   {"managed": [<キー>, ...], "gitConfig": [{"k": <キー>, "v": <値>}, ...]}
#
# 無ければ、この形を置く世代へまだ switch していないということなので、
# 警告して exit 0 する (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#
# ## 何をするか
#
# ~/.claude/settings.json の .env の GIT_CONFIG_* を書き直す。他のキーは保持する。
#
#   - managed (と gitConfig) のキーを持つ既存の組は外す。gitViaGh.enable を false に
#     したとき HTTPS の組が消えるのはこのため
#   - それ以外の組は順序を保って残し、その後ろに gitConfig を足す
#   - 番号は 0 から振り直す (番号に穴があると git はその手前までしか読まない)
#
# 冪等 (既に同じなら何もしない)。gitConfig が gh を credential helper に使うなら、
# 次のときに警告する。env は書く (option が正で、止めると setup の残りが走らないため)。
#
#   - gh が無い / gh にログインしていない (setup.sh の最後のまとめにも出る)
#   - git の設定ファイルに別の credential helper がある (gh より先に呼ばれ、
#     gh の token がそちらにも保存される)
#
# ## 注意
#
#   - GitHub の branch protection "Require signed commits" が有効な repo では、
#     Claude が作った commit は push で弾かれる
#   - Claude が rebase / amend した既存 commit の署名も落ちる
#   - gh の token に workflow scope が無いと、.github/workflows/ を変える push を
#     GitHub が拒否する (gh auth refresh -h github.com -s workflow で足す)
#
# ## なぜ Nix でやらないのか
#
# env の定義は settings.json にしか書けない。そして settings.json は Claude Code
# 自身が書き換える (権限の「常に許可」を選んだときなど) ため、store 上の read-only
# ファイルにできない。bootstrap-claude-hook.sh とまったく同じ切り分け。
# 望む値だけは Nix が決める (bootstrap-claude-skill-overrides.sh と同じ形)。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
generated="${HOME}/.local/state/dotfiles/claude-env.json"

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${generated} ]]; then
  echo "!! 生成ファイルがありません: ${generated}" >&2
  echo "   dotfiles.claude.gitViaGh.enable を持つ世代へ先に home-manager switch してください。" >&2
  echo "   この手順は飛ばします。" >&2
  exit 0
fi

if ! jq -e '
  (.managed | type == "array") and all(.managed[]; type == "string")
  and (.gitConfig | type == "array")
  and all(.gitConfig[]; (.k | type == "string") and (.v | type == "string"))
' "${generated}" >/dev/null 2>&1; then
  echo "${generated} の形が違います ({\"managed\": [...], \"gitConfig\": [{\"k\": ..., \"v\": ...}, ...]})。" >&2
  exit 1
fi

# gh を credential helper に使うのに gh が無い・未ログインなら、push で資格情報を取れない。
# 登録済みでも毎回見る (後から logout していることがあるため)。
uses_gh=0
if jq -e 'any(.gitConfig[]; .v | startswith("!gh "))' "${generated}" >/dev/null; then
  uses_gh=1
  if ! command -v gh &>/dev/null; then
    echo "!! gh が見つかりません。Claude の git は gh の資格情報で GitHub へ HTTPS で通します。" >&2
    echo "   gh は packages.nix が入れます。home-manager switch の後に gh auth login するか、" >&2
    echo "   このマシンの flake で dotfiles.claude.gitViaGh.enable = false にしてください。" >&2
  elif ! gh auth token --hostname github.com &>/dev/null; then
    echo "!! gh にログインしていません。Claude の git は gh の資格情報で GitHub へ HTTPS で通します。" >&2
    echo "   gh auth login を実行するか、このマシンの flake で dotfiles.claude.gitViaGh.enable = false にしてください。" >&2
  fi

  # git の設定ファイル (system / global) にある credential helper は、env で足す gh より
  # 先に呼ばれる。そちらが古い資格情報を返せば gh は使われず、gh で認証が通れば git は
  # 全 helper に store を流すので、gh の token がそちらにも保存される (store なら平文の
  # ~/.git-credentials)。無い前提で空値のリセットを入れていないので、あれば知らせる。
  # env (command scope) は Claude のセッションの中から流したときの自分の組なので見ない。
  # gh auth setup-git が書く形 (空のリセットと gh 自身) も害が無いので見ない。
  others=$(git config --show-scope --get-regexp '^credential\..*helper$' 2>/dev/null \
    | awk -F'\t' '$1 != "command"' \
    | grep -vE '^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*$|gh auth git-credential' || true)
  if [[ -n ${others} ]]; then
    echo "!! git の設定ファイルに credential helper があります。Claude の git では gh より先に呼ばれ、" >&2
    echo "   gh で認証が通ると gh の token がそちらにも保存されます (store なら平文の ~/.git-credentials):" >&2
    # scope と key の間の tab を空白にして字下げする。sed の \t は macOS の BSD sed では
    # tab にならないので tr で替える。
    tr '\t' ' ' <<<"${others}" | sed 's/^/     /' >&2
    echo "   外すか、このマシンの flake で dotfiles.claude.gitViaGh.enable = false にしてください。" >&2
  fi
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

tmp=$(mktemp "${settings}.XXXXXX")
# jq が落ちたときに settings.json の隣へ中間ファイルを残さない。
trap 'rm -f "${tmp}"' EXIT

# .env の GIT_CONFIG_* を生成ファイルの gitConfig で置き換える。
#   - managed と gitConfig のキーを持つ既存の組は落とす (値が違っても gitConfig が勝つ)
#   - 無関係な組は順序を保って残す
#   - 残したものと gitConfig を連結し、0 から番号を振り直す
#     (番号に穴があると git はその手前までしか読まないため、通し番号にする)
jq --slurpfile gen "${generated}" '
  $gen[0] as $g
  | ($g.managed + [$g.gitConfig[].k]) as $ours
  | (.env // {}) as $env
  | (($env.GIT_CONFIG_COUNT // "0") | tonumber) as $n
  | [ range(0; $n)
      | tostring as $i
      | { k: $env["GIT_CONFIG_KEY_" + $i], v: $env["GIT_CONFIG_VALUE_" + $i] }
      | select(.k != null) ] as $existing
  | [ $existing[] | .k as $k | select(($ours | index($k)) == null) ] as $kept
  | ($kept + $g.gitConfig) as $all
  | .env = (
      ($env | with_entries(select(.key | test("^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$") | not)))
      + { GIT_CONFIG_COUNT: ($all | length | tostring) }
      + ([ $all | to_entries[]
           | { ("GIT_CONFIG_KEY_" + (.key | tostring)): .value.k,
               ("GIT_CONFIG_VALUE_" + (.key | tostring)): .value.v } ] | add // {})
    )
' "${settings}" >"${tmp}"

if [[ $(jq -S . "${settings}") == "$(jq -S . "${tmp}")" ]]; then
  echo "登録済みです: ${settings} の .env"
  exit 0
fi

mv "${tmp}" "${settings}"

if [[ ${uses_gh} -eq 1 ]]; then
  echo "登録しました: commit / tag を無署名にし、GitHub へは gh の資格情報 (HTTPS) で通す env"
else
  echo "登録しました: commit / tag を無署名にする env (GitHub へは ssh のまま)"
fi
echo
echo "--- ${settings} の env ---"
jq '.env' "${settings}"
echo
echo "確認:  Claude に git config --get commit.gpgsign (false) と"
echo "       git remote get-url --push origin (gitViaGh なら https) を実行させる"
echo "実行中のセッションにも入る。入らなければ Claude Code を再起動する。"
echo
echo '注意: "Require signed commits" が有効な repo では、Claude の commit は push で弾かれます。'
if [[ ${uses_gh} -eq 1 ]]; then
  echo '注意: gh の token に workflow scope が無いと、.github/workflows/ を変える push は弾かれます'
  echo '      (gh auth refresh -h github.com -s workflow で足す)。'
fi
