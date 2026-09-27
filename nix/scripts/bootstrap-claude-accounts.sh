#!/usr/bin/env bash
# shellcheck shell=bash
#
# claude-personal / claude-work が使う ~/.claude-<名前>/ を、ログインだけを持つ薄い dir として用意する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 60
#
# ^ setup.sh が読む実行順。bootstrap-claude-skills.sh (既定の 50) が ~/.claude/skills へ
#   張ったリンクを写すので、その後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Claude Code のログインを個人と会社のアカウントで分けたい。分けたいのはログインだけで、
# CLAUDE.md・skill・フック・設定・履歴と memory はどちらで起動しても同じものを使う
# (docs/adr/009_claude_account_config_dirs_*)。
#
# CLAUDE_CONFIG_DIR を付けると Claude Code はそれらを全部その dir から読むので、dir の中身を
# ~/.claude への symlink にし、ログインのファイルだけを実体で持たせる。~/.claude と
# 素の `claude` には何もしない。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/claude-accounts.json
# (nix/home/modules/claude.nix)。中身はアカウント名の配列:
#
#   ["personal","work"]
#
# 同じ一覧から claude.nix が claude-<名前> コマンドを作るので、一覧はそこにしか書かない。
# 無ければ、この一覧を含む世代へまだ switch していないということなので、警告して exit 0 する
# (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#
# ## 何をするか (アカウントごと)
#
#   ~/.claude-<名前>/
#   ├── CLAUDE.md      -> ~/.claude/CLAUDE.md      1 段の symlink
#   ├── settings.json  -> ~/.claude/settings.json  1 段の symlink
#   ├── projects       -> ~/.claude/projects       1 段の symlink (履歴と auto memory)
#   ├── skills/        実体。~/.claude/skills の中の symlink だけを同名のリンクで写す
#   ├── agents/        同上 (~/.claude/agents が在れば)
#   ├── commands/      同上 (~/.claude/commands が在れば)
#   ├── plugins/       実体。settings.json の enabledPlugins のうち未導入のものを入れる
#   └── .credentials.json, .claude.json, …   実体。/login と起動のときに Claude Code が作る
#
# リンクを張る場所の状態ごとの扱い:
#
#   無い            張る
#   正しいリンク    そのまま
#   別の先のリンク  張り直して知らせる
#   実体            触らずに警告する (bootstrap より先に claude-<名前> を起動して
#                   Claude Code が作った、など。中身を片付けてから流し直す)
#
# skills/ などに写したリンクのうち ~/.claude 側から消えたものは消す。~/.claude/<種類>/ を
# 指していないリンク (自分で張ったもの) と実体 (Claude Code が置く synced/ など) は触らない。
#
# plugin は、enabledPlugins のうちその dir に入っていないものについて、marketplace を足してから
# `claude plugin install` する。marketplace の元は settings.json の extraKnownMarketplaces、
# 無ければ ~/.claude/plugins/known_marketplaces.json から引く。入れ終わった版は上げない
# (bootstrap-claude-plugins.sh と同じく「先端は取らない」)。
#
# ## 共有するもの / しないもの (Claude Code 2.1.281 で確認)
#
#   settings.json  user の settings.json は readlink を 1 回だけ辿ってその先へ書かれる。
#                  1 段のリンクなら書き込みは ~/.claude/settings.json へ届く
#   plugins/       共有しない。installed_plugins.json が導入先を絶対パスで持ち、別の
#                  config dir から symlink 越しに使うと cache に unknown 版のコピーができる
#   skills/        丸ごとは共有しない。synced/ にアカウントごとの配信 skill が入り、古い版は
#                  pdf/ などを直下に実体で置く。Nix と claude-skills が置くものは必ず
#                  symlink なので、symlink かどうかで線を引く
#   ログイン       .credentials.json / .claude.json は共有しない
#   hooks/ など    置かない。settings.json が ~/.claude/… の絶対パスで登録している
#
# ## なぜ Nix でやらないのか
#
# home.file (mkOutOfStoreSymlink) で張ると /nix/store を経由する 2 段のリンクになり、
# Claude Code は readlink を 1 回しか辿らないので、settings.json への書き込みが store の側で
# 止まる。plugin の導入も Claude Code の CLI でしかできない。Claude Code が書き換えるものは
# bootstrap が扱う、という bootstrap-claude-*.sh と同じ切り分け。
#
# macOS の /bin/bash (3.2) でも動くように書く (mapfile を使わない、空配列は ${a[@]+…} で受ける)。

set -eu -o pipefail
shopt -s nullglob

base="${HOME}/.claude"
generated="${HOME}/.local/state/dotfiles/claude-accounts.json"

# 1 段のリンクで ~/.claude の実体を見せるもの
shared_links=(CLAUDE.md settings.json projects)
# 実体の dir を作り、中の symlink だけを写すもの
mirrored_kinds=(skills agents commands)

warned=0
changed=0

warn() {
  echo "!! $*" >&2
  warned=1
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${generated} ]]; then
  warn "生成ファイルがありません: ${generated}"
  echo "   claude-personal / claude-work を持つ世代へ先に home-manager switch してください。" >&2
  echo "   この手順は飛ばします。" >&2
  exit 0
fi

if ! jq -e 'type == "array" and all(.[]; type == "string")' "${generated}" >/dev/null 2>&1; then
  echo "${generated} がアカウント名の配列 (JSON の文字列の配列) ではありません。" >&2
  exit 1
fi

accounts=()
while IFS= read -r a; do
  accounts+=("${a}")
done < <(jq -r '.[]' "${generated}")

# claude の探し方は bootstrap-claude-plugins.sh と同じ。
# mise は `mise activate` 方式なので、同じ setup.sh の実行内で入った直後は PATH に無い。
claude=""
if command -v claude &>/dev/null; then
  claude=$(command -v claude)
elif command -v mise &>/dev/null; then
  claude=$(mise which claude 2>/dev/null || true)
fi

# $1 に $2 を指す symlink を張る。
ensure_link() {
  local link=$1 target=$2 current
  if [[ -L ${link} ]]; then
    current=$(readlink "${link}")
    [[ ${current} == "${target}" ]] && return 0
    ln -sfn "${target}" "${link}"
    echo "   張り直した: ${link} -> ${target} (元: ${current})"
    changed=1
  elif [[ -e ${link} ]]; then
    warn "実体があるので触りません: ${link}"
    echo "   中身を片付けて (必要なら ~/.claude 側へ移して) から、この手順を流し直してください。" >&2
  else
    ln -s "${target}" "${link}"
    echo "   張った: ${link} -> ${target}"
    changed=1
  fi
}

# ~/.claude/<種類>/ の中の symlink を $1/<種類>/ へ同名のリンクで写し、消えたものを掃除する。
mirror_kind() {
  local dir=$1 kind=$2
  local src="${base}/${kind}" dst="${dir}/${kind}"
  local entry name
  [[ -d ${src} ]] || return 0
  mkdir -p "${dst}"

  for entry in "${src}"/*; do
    [[ -L ${entry} ]] || continue
    name=${entry##*/}
    ensure_link "${dst}/${name}" "${src}/${name}"
  done

  for entry in "${dst}"/*; do
    [[ -L ${entry} ]] || continue
    name=${entry##*/}
    # 写したリンクだけが対象。自分で張った別の先へのリンクは触らない
    [[ $(readlink "${entry}") == "${src}/${name}" ]] || continue
    [[ -L ${src}/${name} ]] && continue
    rm "${entry}"
    echo "   消した: ${entry} (~/.claude 側から消えた)"
    changed=1
  done
}

# marketplace の元を `claude plugin marketplace add` に渡す形で出す。分からなければ何も出さない。
marketplace_arg() {
  local name=$1 src=""
  src=$(jq -c --arg n "${name}" '.extraKnownMarketplaces[$n].source // empty' "${base}/settings.json")
  if [[ -z ${src} && -f ${base}/plugins/known_marketplaces.json ]]; then
    src=$(jq -c --arg n "${name}" '.[$n].source // empty' "${base}/plugins/known_marketplaces.json")
  fi
  [[ -n ${src} ]] || return 0
  jq -r '
    if .source == "github" then .repo
    elif .source == "git" or .source == "url" then .url
    elif .source == "directory" or .source == "file" then .path
    else null end // empty
  ' <<<"${src}"
}

# settings.json の enabledPlugins のうち、$1 の plugins/ に入っていないものを入れる。
sync_plugins() {
  local dir=$1
  local installed="${dir}/plugins/installed_plugins.json"
  local known="${dir}/plugins/known_marketplaces.json"
  local p mkt arg was_link=0
  local wanted=()

  while IFS= read -r p; do
    wanted+=("${p}")
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "${base}/settings.json")

  [[ -L ${dir}/settings.json ]] && was_link=1

  for p in ${wanted[@]+"${wanted[@]}"}; do
    if [[ -f ${installed} ]] && jq -e --arg p "${p}" '.plugins[$p] != null' "${installed}" >/dev/null; then
      continue
    fi
    if [[ -z ${claude} ]]; then
      warn "claude が見つからないので plugin を入れられません: ${dir}"
      echo "   先に ./nix/scripts/bootstrap-mise.sh を実行してから、この手順を流し直してください。" >&2
      return 0
    fi

    mkt=${p##*@}
    if ! { [[ -f ${known} ]] && jq -e --arg m "${mkt}" 'has($m)' "${known}" >/dev/null; }; then
      arg=$(marketplace_arg "${mkt}")
      if [[ -z ${arg} ]]; then
        warn "marketplace ${mkt} の元が分からないので飛ばします: ${p}"
        continue
      fi
      # clone は SSH (git@github.com:) で行われるので、GitHub の鍵が無いと失敗する
      if ! CLAUDE_CONFIG_DIR="${dir}" "${claude}" plugin marketplace add "${arg}"; then
        warn "marketplace ${mkt} (${arg}) を足せなかったので飛ばします: ${p}"
        continue
      fi
    fi

    if CLAUDE_CONFIG_DIR="${dir}" "${claude}" plugin install "${p}" -y; then
      echo "   入れた: ${p}"
      changed=1
    else
      warn "plugin を入れられませんでした: ${p}"
    fi
  done

  # plugin install は settings.json (enabledPlugins) を書く。リンク越しに届かず実ファイルに
  # 置き換わると、その dir だけ設定が分かれてしまうので知らせる。
  if [[ ${was_link} -eq 1 && ! -L ${dir}/settings.json ]]; then
    warn "${dir}/settings.json がリンクから実ファイルに置き換わりました"
    echo "   中身を ~/.claude/settings.json と見比べてから消し、この手順を流し直してください。" >&2
  fi
}

# リンクが切れないよう、~/.claude 側のリンク先を用意する (CLAUDE.md は Nix が置く)。
mkdir -p "${base}/projects"
[[ -e ${base}/settings.json ]] || echo '{}' >"${base}/settings.json"

for name in ${accounts[@]+"${accounts[@]}"}; do
  # dir 名に使うので、パスを壊す文字は受け付けない
  if [[ ! ${name} =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    warn "アカウント名に使えない文字が入っているので飛ばします: ${name} (英小文字・数字・- と _)"
    continue
  fi

  dir="${HOME}/.claude-${name}"
  echo "==> ${dir}"
  changed=0
  mkdir -p "${dir}"

  for f in "${shared_links[@]}"; do
    ensure_link "${dir}/${f}" "${base}/${f}"
  done
  for kind in "${mirrored_kinds[@]}"; do
    mirror_kind "${dir}" "${kind}"
  done
  sync_plugins "${dir}"

  [[ ${changed} -eq 1 ]] || echo "   変更なし"
done

echo
if [[ ${warned} -eq 1 ]]; then
  echo "!! の行を確認してください。" >&2
fi
echo "claude-<名前> で起動し、初回は /login でそのアカウントにログインします。"
echo "確認: ls -l ~/.claude-<名前>  /  各セッションの /status"
