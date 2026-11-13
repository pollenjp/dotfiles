#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code のフックを ~/.claude/settings.json へ登録する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# ## なぜ Nix でやらないのか
#
# フックの定義は settings.json にしか書けない (プラグインを除く)。
# そして settings.json は Claude Code 自身が書き換える
# (権限の「常に許可」を選んだときなど) ため、store 上の read-only ファイルに
# できない。スクリプト本体だけを Nix が配置し、登録はここで行う。
#
# ## 何を登録するか
#
#   PreToolUse   Edit|Write|NotebookEdit|Bash   nix-managed-guard.sh
#                Nix 管理パスを編集しようとしたら止めて、正しい手順を返す
#   PostToolUse  Bash (if "Bash(gh pr create *)")  video-offer-nudge.sh
#   PostToolUse  Write                           video-offer-nudge.sh
#                設計の書き出しと PR の作成を Claude に知らせる (解説動画の短尺を作り始める)
#   PostToolUse  Skill                           run-through-nudge.sh
#                superpowers の 4 つの skill を読んだ直後に、確認を挟まずに PR まで
#                走り切るよう念を押す (ADR 019)
#   PreToolUse   Bash                            ssh-agent-notice.sh
#   PostToolUse  Bash                            ssh-agent-notice.sh
#   PostToolUseFailure  Bash                     ssh-agent-notice.sh
#                SSH agent (1Password) を使うコマンドを打つ前に知らせ、断られたら打ち直さずに
#                選択肢の問いを出させる (ADR 029)。0 以外で終わった Bash は PostToolUseFailure に
#                だけ来るので、Post は 2 つとも登録する
#   PreToolUse   Bash                            xref-guard.sh
#                public な repo へ、ほかの repo への参照を書く git push・gh pr create などを止め、
#                どこか・どう直すかを返す (ADR 033)
#   PreToolUse   Write|Edit|MultiEdit|NotebookEdit  docs-guard.sh
#                public な dotfiles の docs/ に書こうとしたら止め、設計の文書の置き場
#                (dotfiles-private の docs/) を返す (ADR 035)
#   PostToolUse         Bash (if "Bash(gh pr create *)")  pr-assignee-nudge.sh
#   PostToolUseFailure  Bash (if "Bash(gh pr create *)")  pr-assignee-nudge.sh
#                gh pr create が assignee を指定せずに PR を作ったら、gh の認証ユーザーを Assignees に
#                付けて確かめるよう念を押す (ADR 039)。gh pr create の後ろにつないだコマンドが落ちると
#                PostToolUseFailure にだけ来るので、2 つとも登録する
#   PreToolUse          Bash                     op-reason-guard.sh
#   PostToolUse         Bash                     op-reason-guard.sh
#   PostToolUseFailure  Bash                     op-reason-guard.sh
#                WSL の op (理由が必須の 1Password CLI の wrapper) を守る。op.exe の直打ちを止め、op の承認が
#                拒否・時間切れになったら打ち直さずに選択肢の問いを出させる。op の wrapper が無いマシンでは黙る
#   PreToolUse          Bash                     gist-guard.sh
#   PreToolUse          mcp__.*[Gg]ist.*         gist-guard.sh
#                gist やペースト共有のサービスへ上げるコマンドと、gist を作る・書き換える MCP の tool を、
#                いつも止める (ADR 047)。MCP の tool 名は mcp__<server>__<tool> なので、gist を名前に含む
#                tool だけで hook が走るよう matcher を絞る (大文字の Gist も拾う)
#   PreToolUse          Bash                     install-iac-guard.sh
#                venv・project の外 (system・user の環境) へ入れる install と、terraform・tofu・terragrunt で実物
#                (資源か state) を変える操作を止め、代わりの手を返す (IaC の分は dotfiles.claude.iacGuard.enable で外せる)
#   PreToolUse          Bash                     lang-nudge.sh
#                project を作り始めるコマンドと依存を足すコマンドで、読む skill (pack lang の pjp-<言語>・
#                pjp-dep-release-age) を 1 文で知らせる (止めない)
#   Stop         (matcher なし・async)             footer-links-archive.sh
#                会話に出たリンク (footer のバッジと同じ規則で拾う PR・チケット・cc-page) を、cc-pages の会話の
#                トップページに全部残す (footer は 5 個まで)。Stop は matcher を使わないので付けない。turn の終わりを
#                遅らせないよう async で走らせる (Claude を止める答えは返さない hook)
#
# 既存の設定は保持する。同じ event・matcher・if・command の組が既にあれば足さない (matcher の無い組は
# matcher が空と見る)。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
hooks_dir="${HOME}/.claude/hooks"
guard="${hooks_dir}/nix-managed-guard.sh"
nudge="${hooks_dir}/video-offer-nudge.sh"
run_through="${hooks_dir}/run-through-nudge.sh"
ssh_notice="${hooks_dir}/ssh-agent-notice.sh"
xref_guard="${hooks_dir}/xref-guard.sh"
docs_guard="${hooks_dir}/docs-guard.sh"
assignee_nudge="${hooks_dir}/pr-assignee-nudge.sh"
op_guard="${hooks_dir}/op-reason-guard.sh"
gist_guard="${hooks_dir}/gist-guard.sh"
links_archive="${hooks_dir}/footer-links-archive.sh"
iac_guard="${hooks_dir}/install-iac-guard.sh"
lang_nudge="${hooks_dir}/lang-nudge.sh"

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

for hook in "${guard}" "${nudge}" "${run_through}" "${ssh_notice}" "${xref_guard}" "${docs_guard}" "${assignee_nudge}" "${op_guard}" "${gist_guard}" "${links_archive}" "${iac_guard}" "${lang_nudge}"; do
  if [[ ! -x ${hook} ]]; then
    echo "フックが配置されていません: ${hook}" >&2
    echo "先に home-manager switch を実行してください。" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

changed=0

# register <event> <matcher (空なら付けない)> <if (空なら付けない)> <command> [async]
#   5 つ目に async を渡すと、hook を async: true (裏で走らせ、turn を待たせない) で足す
register() {
  local event=$1 matcher=$2 cond=$3 cmd=$4 async=${5:-} tmp
  if jq -e --arg ev "${event}" --arg m "${matcher}" --arg cond "${cond}" --arg c "${cmd}" '
      [.hooks[$ev] // [] | .[] | select((.matcher // "") == $m) | .hooks // [] | .[]
        | select(.command == $c and ((.["if"] // "") == $cond))]
      | length > 0
    ' "${settings}" >/dev/null; then
    echo "登録済みです: ${event}${matcher:+ ${matcher}}${cond:+ (${cond})} -> ${cmd}"
    return 0
  fi
  tmp=$(mktemp "${settings}.XXXXXX")
  jq --arg ev "${event}" --arg m "${matcher}" --arg cond "${cond}" --arg c "${cmd}" --arg async "${async}" '
    .hooks //= {}
    | .hooks[$ev] //= []
    | .hooks[$ev] += [
        (if $m == "" then {} else {matcher: $m} end)
        + {hooks: [{type: "command", command: $c}
            + (if $cond == "" then {} else {"if": $cond} end)
            + (if $async == "" then {} else {async: true} end)]}
      ]
  ' "${settings}" >"${tmp}"
  mv "${tmp}" "${settings}"
  echo "登録しました: ${event}${matcher:+ ${matcher}}${cond:+ (${cond})}${async:+ [async]} -> ${cmd}"
  changed=1
}

register PreToolUse "Edit|Write|NotebookEdit|Bash" "" "${guard}"
register PostToolUse "Bash" "Bash(gh pr create *)" "${nudge}"
register PostToolUse "Write" "" "${nudge}"
register PostToolUse "Skill" "" "${run_through}"
register PreToolUse "Bash" "" "${ssh_notice}"
register PostToolUse "Bash" "" "${ssh_notice}"
register PostToolUseFailure "Bash" "" "${ssh_notice}"
register PreToolUse "Bash" "" "${xref_guard}"
register PreToolUse "Write|Edit|MultiEdit|NotebookEdit" "" "${docs_guard}"
register PostToolUse "Bash" "Bash(gh pr create *)" "${assignee_nudge}"
register PostToolUseFailure "Bash" "Bash(gh pr create *)" "${assignee_nudge}"
register PreToolUse "Bash" "" "${op_guard}"
register PostToolUse "Bash" "" "${op_guard}"
register PostToolUseFailure "Bash" "" "${op_guard}"
register PreToolUse "Bash" "" "${gist_guard}"
register PreToolUse "mcp__.*[Gg]ist.*" "" "${gist_guard}"
register Stop "" "" "${links_archive}" async
register PreToolUse "Bash" "" "${iac_guard}"
register PreToolUse "Bash" "" "${lang_nudge}"

if [[ ${changed} == 1 ]]; then
  echo
  echo "--- ${settings} の hooks ---"
  jq '.hooks' "${settings}"
  echo
  echo "Claude Code を再起動すると有効になります。"
fi
