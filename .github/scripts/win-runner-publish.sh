#!/usr/bin/env bash
# Windows の runner の exe を、key (win/runner の git の tree の hash) ごとの GitHub の Release に置く。.github/workflows/win-runner-release.yml の
# 公開の job (--publish) と、PR の dry-run (--dry-run) が流す (win/README.md の「runner の exe (Release)」。dotfiles-private の
# docs/adr/117_win_runner_exe_release_*)。
#
#   win-runner-publish.sh --dry-run|--publish --key <40 字> --commit <40 字> --dist <dir>
#   win-runner-publish.sh --state --key <40 字>
#
# 環境変数: GH_TOKEN (--publish は contents: write。--dry-run は読むだけでよい)・GH_REPO (owner/repo)
#
# --publish:
#   1. tag win-runner-<key の頭 12 字> の Release があり draft でなければ、作らない。公開してある exe が公開してある .sha256 と合うかだけを見る
#      (合わなければ 1)。今回の build とはバイトで比べない (exe に作った commit を埋め、MSVC の link は PE の頭に時刻を書き、image の CRT も
#      変わるので、同じ key でも build は再現しない)。draft のまま残ったもの (前の job が途中で止まった) は消して作り直す
#   2. 無ければ、<commit> を親にして tree を同じにした Release 用の commit を git の API で作り、その commit に tag を付けて Release を作る
#      (prerelease。asset は <dist> の dotfiles-win.exe と dotfiles-win.exe.sha256)。tag を main の外の commit に付けるのは、clone の
#      git fetch に tag を拾わせないため
#   3. win-runner- の Release のうち、30 日より古いものを、新しい方から 20 本を残して消す (tag も)
# --dry-run: 何も書かず、すること (作る・作らない・消す) を出す
# --state: Release の様子 (none・draft・published) だけを 1 行で出す (公開の job が attestation を作るかを決める)
#
# 終了コード: 0 = 済んだ・1 = 公開してある exe が .sha256 と合わない・gh が落ちた・2 = 引数の誤り
set -eu -o pipefail

keep_newest=20
max_age_days=30

usage() {
  echo "使い方: $0 --dry-run|--publish --key <40 字> --commit <40 字> --dist <dir> / $0 --state --key <40 字>" >&2
  exit 2
}

mode=
key=
commit=
dist=
while (($# > 0)); do
  case $1 in
    --dry-run | --publish | --state) mode=${1#--} ;;
    --key)
      key=${2:-}
      shift
      ;;
    --commit)
      commit=${2:-}
      shift
      ;;
    --dist)
      dist=${2:-}
      shift
      ;;
    *) usage ;;
  esac
  shift
done
[[ -n ${mode} && ${key} =~ ^[0-9a-f]{40}$ ]] || usage
[[ ${mode} == state || (${commit} =~ ^[0-9a-f]{40}$ && -n ${dist}) ]] || usage
[[ -n ${GH_REPO:-} ]] || {
  echo "環境変数 GH_REPO (owner/repo) がありません" >&2
  exit 2
}

short=${key:0:12}
tag=win-runner-${short}
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# Release の様子: none (無い)・draft・published。読めなければ 1 で返す
release_state() {
  local err=${work}/view.err
  local draft
  if draft=$(gh release view "${tag}" --json isDraft --jq '.isDraft' 2>"${err}" </dev/null); then
    if [[ ${draft} == true ]]; then echo draft; else echo published; fi
    return 0
  fi
  if grep -qi 'release not found' "${err}"; then
    echo none
    return 0
  fi
  cat "${err}" >&2
  return 1
}

# 公開してある exe が、公開してある .sha256 と合うか (合わなければ 1)
verify_published() {
  local dir=${work}/published
  mkdir -p "${dir}"
  gh release download "${tag}" --pattern 'dotfiles-win.exe' --pattern 'dotfiles-win.exe.sha256' --dir "${dir}" </dev/null || return 1
  (cd "${dir}" && sha256sum --check --strict dotfiles-win.exe.sha256) || return 1
}

# 消す Release の tag (30 日より古く、新しい方から 20 本に入らないもの)
stale_tags() {
  local cutoff
  local listed
  local i=0
  local created name
  cutoff=$(date -u -d "${max_age_days} days ago" +%Y-%m-%dT%H:%M:%SZ) || return 1
  listed=$(gh release list --limit 1000 --json tagName,createdAt \
    --jq '.[] | select(.tagName | startswith("win-runner-")) | [.createdAt, .tagName] | @tsv' </dev/null) || return 1
  while IFS=$'\t' read -r created name; do
    [[ -n ${name} ]] || continue
    i=$((i + 1))
    if ((i > keep_newest)) && [[ ${created} < ${cutoff} ]]; then
      printf '%s\n' "${name}"
    fi
  done < <(printf '%s\n' "${listed}" | sort -r)
}

notes() {
  cat <<EOF
Windows の runner (win/runner) の exe。key (win/runner の git の tree の hash) は ${key}、この key を初めて作った commit は ${commit}。

dotfiles の PowerShell の dotfiles 関数 (win/powershell/Invoke-DotfilesRunner.ps1) が、clone の HEAD の win/runner に合う key の exe を落とし、dotfiles-win.exe.sha256 と、exe が version で名乗る key を確かめてから使う (win/README.md の「runner の exe (Release)」)。

来歴 (どの workflow がどの commit から作ったか) の確かめ方: gh attestation verify dotfiles-win.exe -R ${GH_REPO}
EOF
}

state=$(release_state)
if [[ ${mode} == state ]]; then
  echo "${state}"
  exit 0
fi
echo "Release ${tag}: ${state}"

case ${mode}:${state} in
  dry-run:published) echo "作らない (同じ key の Release がある。公開してある exe と .sha256 が合うかだけを見る)" ;;
  dry-run:draft) echo "draft を消して作り直す: ${tag}" ;;
  dry-run:none) echo "作る: ${tag} (${commit} を親にした Release 用の commit に tag を付ける。asset は ${dist} の dotfiles-win.exe と dotfiles-win.exe.sha256)" ;;
  publish:published)
    if ! verify_published; then
      echo "::error::公開してある ${tag} の dotfiles-win.exe が、公開してある dotfiles-win.exe.sha256 と合わない (Release が壊れているか、差し替えられている)"
      exit 1
    fi
    echo "作らない (同じ key の Release があり、公開してある exe は .sha256 と合う)"
    ;;
  publish:draft | publish:none)
    if [[ ${state} == draft ]]; then
      echo "draft を消して作り直す: ${tag}"
      gh release delete "${tag}" --yes </dev/null
    fi
    for f in dotfiles-win.exe dotfiles-win.exe.sha256; do
      [[ -f ${dist}/${f} ]] || {
        echo "::error::${dist}/${f} がありません"
        exit 1
      }
    done
    (cd "${dist}" && sha256sum --check --strict dotfiles-win.exe.sha256)
    tree=$(gh api "repos/${GH_REPO}/git/commits/${commit}" --jq '.tree.sha' </dev/null)
    release_commit=$(gh api --method POST "repos/${GH_REPO}/git/commits" \
      -f message="win-runner ${short} (${commit:0:12} から作った runner の exe の Release の印)" \
      -f tree="${tree}" -f "parents[]=${commit}" --jq '.sha' </dev/null)
    notes >"${work}/notes.md"
    gh release create "${tag}" "${dist}/dotfiles-win.exe" "${dist}/dotfiles-win.exe.sha256" \
      --target "${release_commit}" --prerelease --title "win-runner ${short}" --notes-file "${work}/notes.md" </dev/null
    echo "作った: ${tag} (tag は ${release_commit})"
    ;;
esac

# 代入で受ける (落ちたら set -e で止まる。< <(…) で受けると、落ちても先へ進む)
stale_list=$(stale_tags)
if [[ -z ${stale_list} ]]; then
  echo "消す Release は無い (${max_age_days} 日より古く、新しい方から ${keep_newest} 本に入らないもの)"
  exit 0
fi
mapfile -t stale <<<"${stale_list}"
for t in "${stale[@]}"; do
  if [[ ${mode} == dry-run ]]; then
    echo "消す: ${t}"
  else
    gh release delete "${t}" --cleanup-tag --yes </dev/null
    echo "消した: ${t}"
  fi
done
