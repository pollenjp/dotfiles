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
# ~/.claude への symlink にし、ログインのファイルだけを実体で持たせる。
#
# ~/.claude の側は中身を書き換えない。触るのは次だけ:
#   - リンクが切れないよう、無ければ projects/ と settings.json ({}) を作る
#   - enabledPlugins のうち ~/.claude にまだ入っていない plugin を入れる (下記)
#   - 薄い dir で marketplace を足すと、Claude Code がリンク越しに共有の settings.json の
#     extraKnownMarketplaces へ 1 項目書く (既にある項目も、渡した元から組み直した値になる)
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
#   ├── skills/        実体。~/.claude/skills の中の symlink と、実体でも pjp-* のものを同名のリンクで写す
#   ├── agents/        実体。~/.claude/agents の中身を写す (synced を除く。~/.claude/agents が在れば)
#   ├── commands/      同上
#   ├── plugins/       実体。settings.json の enabledPlugins のうち未導入のものを入れる
#   └── .credentials.json, .claude.json, …   実体。/login と起動のときに Claude Code が作る
#
# リンクを張る場所の状態ごとの扱い:
#
#   無い            張る
#   正しいリンク    そのまま
#   別の先のリンク  張り直して知らせる
#   実体            触らずに警告する (bootstrap より先に claude-<名前> を起動して
#                   Claude Code が作った、など。nix/README.md の手順で片付けてから流し直す)
#
# 張る場所が実はリンク先そのもの (薄い dir か skills/ などが ~/.claude へのリンク、
# ~/.claude が薄い dir へのリンク) なら、自分自身を指すリンクで ~/.claude を壊さないよう、
# そのアカウント・その種類は丸ごと飛ばして警告する。
#
# skills/ などに写したリンクのうち ~/.claude 側から消えたものは消す。~/.claude/<種類>/ を
# 指していないリンク (自分で張ったもの) と実体 (Claude Code が置く synced/ など) は触らない。
#
# plugin は、enabledPlugins のうちその dir に入っていないものについて、marketplace を足してから
# `claude plugin install` する。薄い dir に加えて ~/.claude 自身も揃える (薄い dir で入れた
# plugin も共有の enabledPlugins に載るため)。marketplace の元は settings.json の
# extraKnownMarketplaces、無ければ ~/.claude/plugins/known_marketplaces.json から引く。
# 入れ終わった版は上げない (bootstrap-claude-plugins.sh と同じく「先端は取らない」)。
# settings.json が ~/.claude へのリンクでない薄い dir には入れない (その dir の実ファイルに
# 書かれて設定が分かれていくため)。
#
# ## 写すもの / 共有しないもの (Claude Code 2.1.281 で確認)
#
#   settings.json  user の settings.json は readlink を 1 回だけ辿ってその先へ書かれる。
#                  1 段のリンクなら書き込みは ~/.claude/settings.json へ届く
#   plugins/       共有しない。installed_plugins.json が導入先を絶対パスで持ち、別の
#                  config dir から symlink 越しに使うと cache に unknown 版のコピーができる
#   skills/        丸ごとは共有しない。synced/ にアカウントごとの配信 skill が入り、古い版は
#                  pdf/ などを直下に実体で置く。Nix と claude-skills が置くものは symlink、
#                  自作の試作は pjp-* (命名規約) なので、その 2 つだけを写す
#   agents/ など   Claude Code が中身を置かない (synced は念のため除く) ので、全部写す
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
migrate_doc="nix/README.md「Claude Code のアカウントを分ける」の「既に ~/.claude-<名前> があるとき」"

# 1 段のリンクで ~/.claude の実体を見せるもの
shared_links=(CLAUDE.md settings.json projects)
# 実体の dir を作り、中身をリンクで写すもの
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

# marketplace の clone で認証のプロンプトを出させない (bootstrap-claude-skills.sh と同じ)。
# 鍵が無ければ待たずに失敗させ、警告して先へ進む。
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

# 物理パス (symlink を解決した dir)。dir が無ければ空。
phys_dir() {
  (cd "$1" 2>/dev/null && pwd -P) || true
}

# $1 と $2 が symlink を解決すると同じ場所を指すか (親 dir を解決して比べる)。
same_place() {
  local a b
  a=$(phys_dir "$(dirname "$1")")
  b=$(phys_dir "$(dirname "$2")")
  [[ -n ${a} && -n ${b} && ${a}/$(basename "$1") == "${b}/$(basename "$2")" ]]
}

# $1 に $2 を指す symlink を張る。
ensure_link() {
  local link=$1 target=$2 current
  if same_place "${link}" "${target}"; then
    # 張ると ~/.claude の側を自分自身へのリンクで上書きしてしまう
    warn "リンク先と同じ場所なので触りません: ${link}"
    return 0
  fi
  if [[ -L ${link} ]]; then
    current=$(readlink "${link}")
    [[ ${current} == "${target}" ]] && return 0
    ln -sfn "${target}" "${link}"
    echo "   張り直した: ${link} -> ${target} (元: ${current})"
    changed=1
  elif [[ -e ${link} ]]; then
    warn "実体があるので触りません: ${link}"
    echo "   片付け方は ${migrate_doc}。済んだらこの手順を流し直してください。" >&2
  else
    ln -s "${target}" "${link}"
    echo "   張った: ${link} -> ${target}"
    changed=1
  fi
}

# ~/.claude/<種類>/ の中の $2 を薄い dir へ写すか。
mirrorable() {
  local kind=$1 path=$2 name=${2##*/}
  case ${name} in
    synced | manifest.json) return 1 ;;
  esac
  [[ ${kind} != skills ]] && return 0
  # skills は Claude Code も実体を置くので、symlink (Nix・claude-skills) と
  # 命名規約どおりの自作 (pjp-*) だけにする
  [[ -L ${path} || ${name} == pjp-* ]]
}

# ~/.claude/<種類>/ の中身を $1/<種類>/ へ同名のリンクで写し、消えたものを掃除する。
mirror_kind() {
  local dir=$1 kind=$2
  local src="${base}/${kind}" dst="${dir}/${kind}"
  local entry name

  if [[ -L ${dst} ]]; then
    warn "${dst} が symlink なので触りません (実体の dir にしてから流し直してください)"
    return 0
  fi

  if [[ -d ${src} ]]; then
    mkdir -p "${dst}"
    for entry in "${src}"/*; do
      mirrorable "${kind}" "${entry}" || continue
      name=${entry##*/}
      ensure_link "${dst}/${name}" "${src}/${name}"
    done
  fi

  [[ -d ${dst} ]] || return 0
  for entry in "${dst}"/*; do
    [[ -L ${entry} ]] || continue
    name=${entry##*/}
    # 写したリンクだけが対象。自分で張った別の先へのリンクは触らない
    [[ $(readlink "${entry}") == "${src}/${name}" ]] || continue
    if [[ -e ${src}/${name} || -L ${src}/${name} ]] && mirrorable "${kind}" "${src}/${name}"; then
      continue
    fi
    rm "${entry}"
    echo "   消した: ${entry} (~/.claude 側から消えた)"
    changed=1
  done
}

# $1 の config dir で claude を呼ぶ。~/.claude のときは CLAUDE_CONFIG_DIR を付けない
# (~/.claude を指定すると .claude.json の置き場所まで変わる)。
run_claude() {
  local dir=$1
  shift
  if [[ ${dir} == "${base}" ]]; then
    env -u CLAUDE_CONFIG_DIR "${claude}" "$@"
  else
    CLAUDE_CONFIG_DIR="${dir}" "${claude}" "$@"
  fi
}

# marketplace の元を `claude plugin marketplace add` に渡す形で出す。分からなければ何も出さない。
marketplace_arg() {
  local name=$1 src=""
  src=$(jq -c --arg n "${name}" \
    '.extraKnownMarketplaces | objects | .[$n] | objects | .source | objects' \
    "${base}/settings.json" 2>/dev/null || true)
  if [[ -z ${src} && -f ${base}/plugins/known_marketplaces.json ]]; then
    src=$(jq -c --arg n "${name}" '.[$n] | objects | .source | objects' \
      "${base}/plugins/known_marketplaces.json" 2>/dev/null || true)
  fi
  [[ -n ${src} ]] || return 0
  jq -r '
    if .source == "github" then .repo
    elif .source == "git" or .source == "url" then .url
    elif .source == "directory" or .source == "file" then .path
    else null end // empty
  ' <<<"${src}" 2>/dev/null || true
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
  done < <(jq -r '.enabledPlugins | objects | to_entries[] | select(.value == true) | .key' \
    "${base}/settings.json" 2>/dev/null || true)

  [[ -L ${dir}/settings.json ]] && was_link=1

  for p in ${wanted[@]+"${wanted[@]}"}; do
    if [[ -f ${installed} ]] && jq -e --arg p "${p}" '.plugins[$p] != null' "${installed}" &>/dev/null; then
      continue
    fi
    if [[ -z ${claude} ]]; then
      warn "claude が見つからないので plugin を入れられません: ${dir}"
      echo "   先に ./nix/scripts/bootstrap-mise.sh を実行してから、この手順を流し直してください。" >&2
      return 0
    fi

    mkt=${p##*@}
    if ! { [[ -f ${known} ]] && jq -e --arg m "${mkt}" 'has($m)' "${known}" &>/dev/null; }; then
      arg=$(marketplace_arg "${mkt}")
      if [[ -z ${arg} ]]; then
        warn "marketplace ${mkt} の元が分からないので飛ばします: ${p} (${dir})"
        continue
      fi
      # clone は SSH (git@github.com:) で行われるので、GitHub の鍵が無いと失敗する
      if ! run_claude "${dir}" plugin marketplace add "${arg}"; then
        warn "marketplace ${mkt} (${arg}) を足せなかったので飛ばします: ${p} (${dir})"
        continue
      fi
    fi

    if run_claude "${dir}" plugin install "${p}" -y; then
      echo "   入れた: ${p}"
      changed=1
    else
      warn "plugin を入れられませんでした: ${p} (${dir})"
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

settings_ok=1
if ! jq -e . "${base}/settings.json" &>/dev/null; then
  warn "${base}/settings.json が JSON として壊れているので、plugin は入れません"
  settings_ok=0
fi

if [[ ${settings_ok} -eq 1 ]]; then
  echo "==> ${base} (plugin だけ揃える)"
  changed=0
  sync_plugins "${base}"
  [[ ${changed} -eq 1 ]] || echo "   変更なし"
fi

base_phys=$(phys_dir "${base}")

for name in ${accounts[@]+"${accounts[@]}"}; do
  # dir 名に使うので、パスを壊す文字は受け付けない
  if [[ ! ${name} =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    warn "アカウント名に使えない文字が入っているので飛ばします: ${name} (英小文字・数字・- と _)"
    continue
  fi

  dir="${HOME}/.claude-${name}"
  echo "==> ${dir}"

  # ~/.claude と同じ場所だと、リンクで ~/.claude 自身を壊してしまう
  if [[ -L ${dir} ]]; then
    warn "${dir} が symlink なので飛ばします (実体の dir にしてから流し直してください)"
    continue
  fi
  if [[ -d ${dir} && $(phys_dir "${dir}") == "${base_phys}" ]]; then
    warn "${dir} は ~/.claude と同じ場所なので飛ばします (~/.claude が ${dir} へのリンクになっている)"
    continue
  fi

  changed=0
  mkdir -p "${dir}"

  for f in "${shared_links[@]}"; do
    ensure_link "${dir}/${f}" "${base}/${f}"
  done
  for kind in "${mirrored_kinds[@]}"; do
    mirror_kind "${dir}" "${kind}"
  done

  if [[ ${settings_ok} -eq 1 ]]; then
    if [[ -L ${dir}/settings.json && $(readlink "${dir}/settings.json") == "${base}/settings.json" ]]; then
      sync_plugins "${dir}"
    else
      warn "${dir}/settings.json が ~/.claude へのリンクでないので、plugin は入れません"
    fi
  fi

  [[ ${changed} -eq 1 ]] || echo "   変更なし"
done

echo
if [[ ${warned} -eq 1 ]]; then
  echo "!! の行を確認してください。" >&2
fi
echo "claude-<名前> で起動し、初回は /login でそのアカウントにログインします。"
echo "確認: ls -l ~/.claude-<名前>  /  各セッションの /status"
