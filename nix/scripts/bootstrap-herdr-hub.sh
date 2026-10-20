#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr の集約ハブ ~/h を、claude-skills の skill pjp-herdr-hub の hub-init.sh で作る (作り済みなら雛形との差だけ直す)。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 60
#
# ^ setup.sh が読む実行順。bootstrap-claude-skills.sh (既定の 50) が ~/.claude/skills へ張った skill の script を
#   打つので、その後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# ~/h は、herdr で子の Claude を回す集約 (指揮役) の会話の受け口 (ハブ)。コードを持たない git repo (remote なし) で、
# 決まりのファイル (CLAUDE.md・.claude/settings.json・.gitignore) の雛形と、それを写す hub-init.sh は private な
# claude-skills の pjp-herdr-hub にある。新しいマシンで hub-init.sh を打ち忘れないよう、setup から打つ。
# hub-init.sh は打ち直しても雛形との差だけを直すので、claude-skills の雛形が新しくなったときも --update で ~/h に入る。
#
# ## 何をするか
#
# ~/.claude/skills/pjp-herdr-hub/scripts/hub-init.sh を引数なしで (既定の ~/h に) 打つ。何を書くか・どこで止まるかは
# hub-init.sh の先頭のコメント (git init・決まりのファイルを写して commit・git config pjp.devtracker.repo)。
#
# ## 止まらない
#
# setup.sh は手順が 1 つ失敗すると残りを走らせないので、ここでは exit 1 しない。
#
#   pjp-herdr-hub が張られていない          claude-skills を取れないマシンでは、これが正常 (取れないことは
#                                           bootstrap-claude-skills.sh が警告する)。1 行出して通す。ただし
#                                           claude-skills の clone がある (bootstrap-claude-skills.sh が控えた
#                                           場所) か、リンクが切れているなら、clone が古いか skill の名前が
#                                           変わった・消えたので、警告して通す
#   pjp-herdr-hub はあるが hub-init.sh が無い  skill の中で名前か場所が変わった。警告して通す
#   hub-init.sh が 0 以外で終わった          ~/h が別の repo の中・雛形の外のものがある (何も書かずに止まる)、
#                                           git の commit に失敗した、など。出力ごと警告して通す
#
# ## なぜ Nix (home.activation) でやらないのか
#
# hub-init.sh は private な claude-skills の作業クローンにあり、Nix からは見えない (bootstrap-claude-skills.sh の
# 「なぜ Nix (flake input) で管理しないのか」)。~/h は Nix が置くファイルではなく、git の commit も伴う。

set -eu -o pipefail

skill_dir="${HOME}/.claude/skills/pjp-herdr-hub"
hub_init="${skill_dir}/scripts/hub-init.sh"
# bootstrap-claude-skills.sh が、最後にリンクを張った claude-skills の clone の場所を控えるファイル
skills_state="${HOME}/.local/state/dotfiles/claude-skills-dir"

usage() {
  cat <<'EOS'
herdr の集約ハブ ~/h を、claude-skills の skill pjp-herdr-hub の hub-init.sh で作る (作り済みなら雛形との差だけ直す)。

使い方:
  bootstrap-herdr-hub.sh              ~/.claude/skills/pjp-herdr-hub/scripts/hub-init.sh を打つ
  bootstrap-herdr-hub.sh -h, --help   これ

pjp-herdr-hub が張られていない (claude-skills を取れない) マシンでは何もしない。
hub-init.sh が止まっても警告を出して正常終了する (setup の後ろの手順を止めない)。
差を見るだけなら hub-init.sh --check を直に打つ。
EOS
}

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

# claude-skills の clone (bootstrap-claude-skills.sh が控えた場所が git の clone なら、その場所)。無ければ何も出さない
skills_clone() {
  local dir=""
  if [[ -r ${skills_state} ]]; then
    IFS= read -r dir <"${skills_state}" || true
  fi
  dir=${dir%/}
  if [[ -n ${dir} && -d ${dir}/.git ]]; then
    printf '%s\n' "${dir}"
  fi
}

# 引数は --help だけ。--dry-run などを渡されて、書かないつもりで書いてしまわないよう、ほかは断る
if [[ $# -gt 0 ]]; then
  case $1 in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: 知らないオプション: %s  (--help)\n' "$1" >&2
      exit 2
      ;;
  esac
fi

echo "==> herdr の集約ハブ (~/h)"

if [[ ! -e ${skill_dir} ]]; then
  # claude-skills を使っているマシン (clone があるか、リンクが残っている) で無いのは、clone が古いか、skill の名前が
  # 変わった・消えたとき。黙って飛ばすと ~/h が作られなくなったことに気付けないので警告する
  if [[ -L ${skill_dir} || -n $(skills_clone) ]]; then
    warn "claude-skills を使っているマシンなのに、skill pjp-herdr-hub が ~/.claude/skills に無い (かリンクが切れている) ので、集約ハブ ~/h は作りません。" \
      "clone が古い・まだ張っていないなら、bootstrap-claude-skills の警告を見て流し直す: ~/dotfiles/setup --steps bootstrap-claude-skills,bootstrap-herdr-hub" \
      "claude-skills の側で skill の名前が変わった・消えたなら、nix/scripts/bootstrap-herdr-hub.sh を合わせて直してください。"
    exit 0
  fi
  echo "pjp-herdr-hub の skill が ~/.claude/skills に無いので飛ばします (claude-skills を取れないマシンでは、これで問題ありません)。"
  exit 0
fi

if [[ ! -f ${hub_init} ]]; then
  warn "pjp-herdr-hub の skill はあるのに、hub-init.sh がありません: ${hub_init}" \
    "claude-skills の側で名前か場所が変わったなら、nix/scripts/bootstrap-herdr-hub.sh を合わせて直してください。"
  exit 0
fi

# 実行の bit に頼らず、この script と同じ bash で打つ。出力は、止まったときに警告の続きの行へ入れるので取っておく
echo "+ ${hub_init}"
rc=0
captured=$("${BASH}" "${hub_init}" 2>&1 </dev/null) || rc=$?
if ((rc == 0)); then
  if [[ -n ${captured} ]]; then
    printf '%s\n' "${captured}"
  fi
  exit 0
fi
warn "集約ハブ ~/h を作る・新しくすることができませんでした (hub-init.sh の終了コード ${rc}):" \
  ${captured:+"${captured}"} \
  "直したら、この手順だけ流し直す: ~/dotfiles/setup --steps bootstrap-herdr-hub"
exit 0
