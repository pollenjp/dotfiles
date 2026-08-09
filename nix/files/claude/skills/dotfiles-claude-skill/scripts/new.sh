#!/usr/bin/env bash
# shellcheck shell=bash
#
# ~/.claude/ 配下の skill / agent / command の雛形を **dotfiles 側に** 作る。
#
# 使い方:
#   new.sh skill   <名前>    ~/dotfiles/nix/files/claude/skills/<名前>/SKILL.md
#   new.sh agent   <名前>    ~/dotfiles/nix/files/claude/agents/<名前>.md
#   new.sh command <名前>    ~/dotfiles/nix/files/claude/commands/<名前>.md
#
# オプション:
#   --apply              作成後に nix/scripts/setup.sh --update まで実行する
#   --dotfiles <パス>    dotfiles の場所 (既定: $DOTFILES_DIR または ~/dotfiles)
#
# ## なぜ ~/.claude/ に直接作らないのか
#
# ~/.claude/{skills,agents,commands} の中身は Nix (home-manager) 管理で、
# /nix/store への symlink として配置されている。store は read-only なので、
# あとから dotfiles へ移す手間が増えるだけでなく、root で編集すると
# 黙って store を壊す。最初からリポジトリ側に作る。
#
# ## git add まで面倒を見る理由
#
# flake は git 管理下の **追跡済み** ファイルしか見ない。新規ディレクトリを
# untracked のままにすると home-manager switch がそれを認識せず、
# エラーも出ないまま「配置されない」だけになる。最も嵌まりやすいので
# このスクリプトが必ず git add する。

set -eu -o pipefail

kind=""
name=""
apply=0
dotfiles=""

usage() {
  cat <<'EOS'
~/.claude/ 配下の skill / agent / command の雛形を dotfiles 側に作る。

使い方:
  new.sh skill   <名前>    ~/dotfiles/nix/files/claude/skills/<名前>/SKILL.md
  new.sh agent   <名前>    ~/dotfiles/nix/files/claude/agents/<名前>.md
  new.sh command <名前>    ~/dotfiles/nix/files/claude/commands/<名前>.md

オプション:
  --apply              作成後に nix/scripts/setup.sh --update まで実行する
  --dotfiles <パス>    dotfiles の場所 (既定: $DOTFILES_DIR または ~/dotfiles)
  -h, --help           これ
EOS
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --apply) apply=1 ;;
    --dotfiles)
      shift
      [[ $# -gt 0 ]] || die "--dotfiles にパスを渡してください"
      dotfiles=$1
      ;;
    --dotfiles=*) dotfiles=${1#*=} ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "知らないオプション: $1" ;;
    *)
      if [[ -z ${kind} ]]; then
        kind=$1
      elif [[ -z ${name} ]]; then
        name=$1
      else
        die "引数が多すぎます: $1"
      fi
      ;;
  esac
  shift
done

[[ -n ${kind} && -n ${name} ]] || {
  usage
  exit 1
}

case ${kind} in
  skill | agent | command) ;;
  *) die "kind は skill / agent / command のいずれか: ${kind}" ;;
esac

# 名前はディレクトリ名にも frontmatter の name にもなる。
# Claude Code が扱う識別子なので小文字とハイフンだけに絞る。
if [[ ! ${name} =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  die "名前は小文字・数字・ハイフンのみ (先頭は英数字): ${name}"
fi

dotfiles=${dotfiles:-${DOTFILES_DIR:-${HOME}/dotfiles}}
claude_dir="${dotfiles}/nix/files/claude"
[[ -d ${claude_dir} ]] || die "${claude_dir} がありません。--dotfiles でパスを指定してください。"

case ${kind} in
  skill)
    target="${claude_dir}/skills/${name}/SKILL.md"
    installed="${HOME}/.claude/skills/${name}"
    ;;
  agent)
    target="${claude_dir}/agents/${name}.md"
    installed="${HOME}/.claude/agents/${name}.md"
    ;;
  command)
    target="${claude_dir}/commands/${name}.md"
    installed="${HOME}/.claude/commands/${name}.md"
    ;;
esac

[[ ! -e ${target} ]] || die "既にあります: ${target}"

# ~/.claude/ 側に同名があるなら Claude Code 管理のもの (Anthropic 配信の skill など)。
# dotfiles 由来なら上の存在チェックで先に弾かれているのでここには来ない。
# 同名が並ぶとどちらが使われるか不定になるため作らせない。
if [[ -e ${installed} ]]; then
  die "$(
    printf '%s は既にあります (Claude Code 管理)。\n' "${installed}"
    printf '       同名だとどちらが使われるか不定になります。別の名前にしてください。'
  )"
fi

mkdir -p "$(dirname "${target}")"

case ${kind} in
  skill)
    cat >"${target}" <<EOS
---
name: ${name}
description: どういう時に使うかを具体的に書く。「何をするか」ではなく起動条件を書く。ここを読んで Claude が起動を判断する
---

# ${name}

本文。手順や規約をここに書く。
EOS
    ;;
  agent)
    cat >"${target}" <<EOS
---
name: ${name}
description: いつ起動すべきかを書く。Claude はここを読んで委譲を判断する
# tools: Read, Grep, Glob      # 省略すると全ツール
# model: sonnet                # 省略すると親から継承
---

システムプロンプトをここに書く。
EOS
    ;;
  command)
    cat >"${target}" <<EOS
---
description: /help や補完に出る 1 行説明
# argument-hint: <path>
---

プロンプト本文。\$ARGUMENTS で引数を受け取れる。
EOS
    ;;
esac

printf '作成しました: %s\n' "${target}"

# flake は untracked を見ないので必ず追跡させる
if git -C "${dotfiles}" rev-parse --is-inside-work-tree &>/dev/null; then
  git -C "${dotfiles}" add "${target}"
  printf 'git add しました (flake は untracked ファイルを見ないため)\n'
else
  printf '!! %s は git リポジトリではありません。git add は飛ばしました。\n' "${dotfiles}" >&2
fi

printf '\n次にすること:\n'
printf '  1. %s を編集する\n' "${target}"
printf '  2. 適用する\n'
printf '       %s/nix/scripts/setup.sh --update\n' "${dotfiles}"
printf '  3. 確認する\n'
printf '       ls -l %s\n' "${installed}"
printf '     store への symlink になっていれば成功。新しいセッションから使える。\n'

if [[ ${apply} == 1 ]]; then
  printf '\n==> 適用 (--apply)\n'
  "${dotfiles}/nix/scripts/setup.sh" --update
fi
