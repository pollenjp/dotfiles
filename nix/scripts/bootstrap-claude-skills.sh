#!/usr/bin/env bash
# shellcheck shell=bash
#
# private な skill 置き場 (pollenjp/claude-skills) を取得して ~/.claude/ へ繋ぐ。
#
# ## 何をするか
#
#   1. claude-skills を ghq root 配下へ clone する (既にあれば ff-only で pull)
#   2. skills/ agents/ commands/ の中身を 1 つずつ ~/.claude/<種類>/ へ symlink する
#   3. リポジトリから消えたものの symlink を掃除する
#
# 冪等。skill を足したあとや、別マシンでの変更を取り込むときに何度でも実行してよい。
#
# ## claude-skills へアクセスできないマシンでも止まらない
#
# dotfiles は **public** なので、claude-skills を取れないマシン (SSH 鍵がまだ無い、
# メンバーではない、オフライン) でも setup を通したい。そこで **取得に失敗しても
# エラーにしない**。警告を出して exit 0 する。
#
#   - clone できない -> private skill 無しで続行 (リンクは張らないし消さない)
#   - pull できない   -> 手元のクローンの内容でリンクを張り直す
#
# setup.sh は手順が 1 つ失敗すると残りを走らせないので、ここで exit 1 すると
# 後続の bootstrap-* まで巻き込んで落ちる。それを避けるため。
# 取得できたかどうかは最後のログの !! を見る。
#
# ## なぜ Nix (flake input) で管理しないのか
#
# claude-skills は **private** で、dotfiles は **public**。flake input にすると:
#
#   - public な flake.lock に private repo の URL と rev が載る
#   - GitHub Actions の `nix flake check` が fetch できずに落ちる
#     (deploy key か PAT をリポジトリに足さないと直らない)
#
# それに skill は試行錯誤しながら書くもので、store 管理だと 1 文字直すたびに
# commit -> push -> flake update -> home-manager switch が要る。
# 作業クローンへ symlink すれば編集がそのまま反映される。
#
# 引き換えに rev の pin は無くなるが、pin したければクローン側で
# `git checkout <tag>` すればよい。
#
# ## なぜ home.activation でやらないのか
#
# clone / pull はネットワークアクセスを伴う。home-manager switch は hermetic に
# 保ちたいので分けている (bootstrap-mise.sh と同じ理由)。
#
# ## Nix 管理のものと衝突しない理由
#
# ~/.claude/<種類>/ は Claude Code 自身も Nix も書き込むディレクトリだが、
# どちらも **中身を 1 つずつ** 置く方式なので、ここで張る symlink は兄弟として
# 並ぶだけで衝突しない。
#
#   ~/.claude/skills/
#   ├── manifest.json      <- Claude Code 管理 (実ファイル)
#   ├── pdf/ docx/ ...     <- Anthropic 配信 (実ディレクトリ)
#   ├── <公開してよいもの> -> /nix/store/...                     (nix/files/claude/skills/)
#   └── <private>          -> ~/ghq/.../claude-skills/skills/... (このスクリプト)
#
# 同名の実体や別の symlink が既にある場合は **上書きせず警告して飛ばす**。
#
# ## 自分が張ったリンクの見分け方
#
# 台帳は持たない。「リンク先が作業クローンの中か」だけで判定する
# (nix-managed-guard.sh が /nix/store を指すかで判定しているのと同じ考え方)。
# クローン先を引っ越した場合に備えて、最後に使ったパスだけ
# ~/.local/state/dotfiles/claude-skills-dir に控えている。

set -eu -o pipefail

# 鍵が無い / known_hosts に github.com が無いマシンでは、git や ssh が対話プロンプトを
# 出して入力を待つ。setup.sh ごと固まるより即座に失敗した方がよいので封じる
# (ssh-agent に載っている鍵は BatchMode でもそのまま使える)。
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

repo_url="git@github.com:pollenjp/claude-skills.git"
repo_path="github.com/pollenjp/claude-skills"
kinds=(skills agents commands)

claude_dir="${HOME}/.claude"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/claude-skills-dir"

dir_arg=""
do_pull=1
dry_run=0
status_only=0

# クローンが手元に無い (= リンクの張りようが無い) 状態。最後に警告を出して exit 0 する。
unreachable=0
# クローンはあるが更新できなかった状態。手元の内容でリンクは張る。
stale=0

usage() {
  cat <<'EOS'
private な skill 置き場 (pollenjp/claude-skills) を取得して ~/.claude/ へ繋ぐ。

使い方:
  bootstrap-claude-skills.sh              取得 (or 更新) してリンクを張り直す
  bootstrap-claude-skills.sh --no-pull    pull せず、リンクだけ張り直す
  bootstrap-claude-skills.sh --status     いま何がリンクされているかを見る
  bootstrap-claude-skills.sh --dir <path> クローン先を指定する
  bootstrap-claude-skills.sh --dry-run    実行せず、走るコマンドを表示するだけ
  bootstrap-claude-skills.sh -h, --help   これ

クローン先の決まり方 (上から順に):
  1. --dir
  2. $CLAUDE_SKILLS_DIR
  3. $(ghq root)/github.com/pollenjp/claude-skills
  4. ~/ghq/github.com/pollenjp/claude-skills

claude-skills は private なので、アクセスできないマシンでは取得に失敗する。
その場合はエラーにせず、警告を出して正常終了する (~/.claude/ には触らない)。
EOS
}

note() {
  printf '  %s\n' "$*"
}

warn() {
  printf '!! %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# 実行するコマンドを見せてから実行する。--dry-run では見せるだけ。
run() {
  printf '+ %s\n' "$*"
  if [[ ${dry_run} == 1 ]]; then
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --no-pull) do_pull=0 ;;
    --status) status_only=1 ;;
    --dry-run) dry_run=1 ;;
    --dir)
      shift
      [[ $# -gt 0 ]] || die "--dir にパスを渡してください"
      dir_arg=$1
      ;;
    --dir=*) dir_arg=${1#*=} ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "知らないオプション: $1  (--help)" ;;
  esac
  shift
done

# git が無いと取得も掃除もできないが、これも「取得できない」の一種として扱う
# (die にすると setup.sh の後続が落ちる)。
have_git=1
command -v git &>/dev/null || have_git=0

########################
# クローン先を決める   #
########################

resolve_dir() {
  local root
  if [[ -n ${dir_arg} ]]; then
    printf '%s' "${dir_arg}"
    return 0
  fi
  if [[ -n ${CLAUDE_SKILLS_DIR:-} ]]; then
    printf '%s' "${CLAUDE_SKILLS_DIR}"
    return 0
  fi
  # ghq は packages.nix に入っているが、switch 前だとまだ無いこともある。
  # その場合は ghq の既定値と同じ ~/ghq へ落とす。
  if root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/%s' "${root}" "${repo_path}"
    return 0
  fi
  printf '%s/ghq/%s' "${HOME}" "${repo_path}"
}

dir=$(resolve_dir)
dir=${dir%/}

prev_dir=""
if [[ -r ${state_file} ]]; then
  prev_dir=$(head -n 1 "${state_file}")
  prev_dir=${prev_dir%/}
fi

# このスクリプトが張った symlink かどうか。
# 引っ越し直後は古いクローンを指すリンクが残っているので、それも自分のものとして扱う。
is_ours() {
  local target=$1
  if [[ ${target} == "${dir}/"* ]]; then
    return 0
  fi
  if [[ -n ${prev_dir} && ${prev_dir} != "${dir}" && ${target} == "${prev_dir}/"* ]]; then
    return 0
  fi
  return 1
}

##########
# 取得   #
##########

ensure_clone() {
  if [[ -d ${dir}/.git ]]; then
    if [[ ${do_pull} == 0 ]]; then
      note "pull は飛ばします (--no-pull)"
      return 0
    fi
    # 作業中の変更を巻き込まないよう、綺麗なときだけ pull する。
    if [[ -n $(git -C "${dir}" status --porcelain) ]]; then
      warn "未コミットの変更があるので pull を飛ばします: ${dir}"
      return 0
    fi
    if ! git -C "${dir}" rev-parse --abbrev-ref '@{upstream}' &>/dev/null; then
      warn "upstream が無いブランチなので pull を飛ばします: ${dir}"
      return 0
    fi
    # 取れなくても手元のクローンは使えるので、警告だけ残して続ける。
    if ! run git -C "${dir}" pull --ff-only; then
      warn "pull に失敗しました。手元のクローンのまま続けます: ${dir}"
      note "鍵もネットワークも問題ないなら、履歴が分岐しています。手で解決してください。"
      stale=1
    fi
    return 0
  fi

  if [[ -e ${dir} ]]; then
    warn "${dir} は git リポジトリではありません。取得を飛ばします。"
    note "退けてから再実行してください。"
    unreachable=1
    return 0
  fi

  run mkdir -p "$(dirname "${dir}")"
  if ! run git clone "${repo_url}" "${dir}"; then
    warn "clone に失敗しました: ${repo_url}"
    note "private リポジトリなので SSH 鍵が要ります。次で疎通を確認してください:"
    note "  ssh -T git@github.com"
    unreachable=1
  fi
  return 0
}

##########
# リンク #
##########

linked=0
skipped=0
removed=0

link_kind() {
  local kind=$1
  local src_dir="${dir}/${kind}"
  local dest_dir="${claude_dir}/${kind}"
  local src name dest target real

  if [[ ! -d ${src_dir} ]]; then
    return 0
  fi

  for src in "${src_dir}"/*; do
    # 中身が無いときは glob が展開されずに残る
    [[ -e ${src} ]] || continue
    name=$(basename "${src}")
    # claude.nix と同じ除外。ディレクトリを git 管理下に残すためのものなので配置しない。
    if [[ ${name} == "README.md" ]]; then
      continue
    fi
    dest="${dest_dir}/${name}"

    if [[ -L ${dest} ]]; then
      target=$(readlink "${dest}")
      if [[ ${target} == "${src}" ]]; then
        continue
      fi
      if is_ours "${target}"; then
        # クローン先を引っ越した後など。張り替える。
        run ln -sfn "${src}" "${dest}"
        linked=$((linked + 1))
        continue
      fi
      real=$(readlink -f "${dest}" 2>/dev/null || true)
      if [[ ${real} == /nix/store/* ]]; then
        warn "${kind}/${name}: Nix 管理のものと名前が衝突しています。飛ばします。"
        note "nix/files/claude/${kind}/${name} と、どちらか一方へ寄せてください。"
      else
        warn "${kind}/${name}: 別の symlink が既にあります (-> ${target})。飛ばします。"
      fi
      skipped=$((skipped + 1))
      continue
    fi

    if [[ -e ${dest} ]]; then
      warn "${kind}/${name}: 実体が既にあります。飛ばします。"
      note "Anthropic 配信のものか、直接置いた試作と同名の可能性があります。"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ ! -d ${dest_dir} ]]; then
      run mkdir -p "${dest_dir}"
    fi
    run ln -s "${src}" "${dest}"
    linked=$((linked + 1))
  done
}

# リポジトリから消えたもの、引っ越し前のクローンを指したままのものを外す。
# 判定はリンク先だけで行うので、Claude Code 管理のものや Nix 管理のものには触れない。
prune_kind() {
  local kind=$1
  local dest_dir="${claude_dir}/${kind}"
  local dest target

  if [[ ! -d ${dest_dir} ]]; then
    return 0
  fi

  for dest in "${dest_dir}"/*; do
    if [[ ! -L ${dest} ]]; then
      continue
    fi
    target=$(readlink "${dest}")
    if ! is_ours "${target}"; then
      continue
    fi
    if [[ ${target} == "${dir}/"* && -e ${target} ]]; then
      continue
    fi
    run rm -f "${dest}"
    removed=$((removed + 1))
  done
}

##########
# 状態   #
##########

show_status() {
  local kind dest_dir dest target found

  printf '==> クローン\n'
  note "${dir}"
  if [[ -d ${dir}/.git ]]; then
    note "$(git -C "${dir}" log -1 --format='%h %s' 2>/dev/null || echo '(コミットなし)')"
  else
    note "(未取得)"
  fi

  for kind in "${kinds[@]}"; do
    printf '==> ~/.claude/%s\n' "${kind}"
    dest_dir="${claude_dir}/${kind}"
    found=0
    if [[ -d ${dest_dir} ]]; then
      for dest in "${dest_dir}"/*; do
        if [[ ! -L ${dest} ]]; then
          continue
        fi
        target=$(readlink "${dest}")
        if ! is_ours "${target}"; then
          continue
        fi
        found=1
        if [[ -e ${target} ]]; then
          note "$(basename "${dest}")"
        else
          note "$(basename "${dest}")  (リンク切れ)"
        fi
      done
    fi
    if [[ ${found} == 0 ]]; then
      note "(このスクリプトが張ったものは無し)"
    fi
  done
}

##########
# main   #
##########

if [[ ${status_only} == 1 ]]; then
  show_status
  exit 0
fi

echo "==> クローン (${dir})"
if [[ ${have_git} == 0 ]]; then
  warn "git が見つかりません。取得を飛ばします。"
  note "先に home-manager switch を実行してください。"
  unreachable=1
else
  ensure_clone
fi

# クローンが無いまま prune すると、別マシンで張ったリンクを消しに行ってしまう。
# 取得できていないときは ~/.claude/ には一切触らない。
if [[ ${unreachable} == 0 ]]; then
  echo "==> ~/.claude/ へリンク"
  for kind in "${kinds[@]}"; do
    link_kind "${kind}"
    prune_kind "${kind}"
  done
  note "追加/更新 ${linked} / 削除 ${removed} / 飛ばした ${skipped}"

  if [[ ${dry_run} == 0 ]]; then
    mkdir -p "${state_dir}"
    printf '%s\n' "${dir}" >"${state_file}"
  fi
fi

echo
if [[ ${unreachable} == 1 ]]; then
  warn "claude-skills を取得できていません。private な skill 無しで続けます。"
  note "公開している skill / agent / command は Nix が配置するので、そちらは使えます。"
  note "このリポジトリを使わないマシンなら、これで問題ありません。"
  note "鍵やネットワークを整えたら、この手順だけ実行し直せばよい:"
  note "  $0"
  exit 0
fi

echo "完了しました。Claude Code を再起動すると読み込まれます。"
note "いま繋がっているもの: $0 --status"
if [[ ${stale} == 1 ]]; then
  echo
  warn "claude-skills を更新できていません (上の !! を参照)。手元のクローンのままです。"
fi
if [[ ${skipped} -gt 0 ]]; then
  echo
  warn "飛ばしたものがあります (上の !! を参照)。名前の衝突を解消してから再実行してください。"
fi
