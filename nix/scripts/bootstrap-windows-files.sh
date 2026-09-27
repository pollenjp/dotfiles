#!/usr/bin/env bash
# shellcheck shell=bash
#
# repo 直下の win/ にある Windows 側のアプリの設定を、/mnt/c へコピーして配る。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 90
#
# ^ setup.sh が読む実行順。Windows 側で変わっていた (衝突した) ら exit 1 するので、
#   ほかの bootstrap を止めないよう最後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows 側のアプリ (Orca など) の設定を dotfiles で管理する
# (docs/adr/010_win_files_from_wsl_*)。WSL から /mnt/c 越しに書くので、
# Windows 側に clone は要らない。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く。
#   nix/home/modules/windows-files.nix)。中身は配り先と on / off:
#
#     {"enable":true,"version":1,"windowsHome":"/mnt/c/Users/<名前>"}
#
#   無ければ、この option を持つ世代へまだ switch していないということなので、
#   警告して exit 0 する (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#   enable が false なら、このマシンは対象外なので exit 0。
#
# - この script がいる checkout の win/manifest.toml。nix/lib/windows-files.nix に
#   nix-instantiate で通して、置き先を解決した計画 (JSON) にする。home-manager の評価
#   からは win/ が見えない (ローカル flake は本体を path:<repo>/nix で読む) ので、
#   ここで読む。配るのは working tree の中身で、commit していない変更も配られる。
#
# ## 何をするか
#
# 計画の 1 件ごとに、置き先の中身と「前回ここへ置いた中身の sha256」の記録
# (~/.local/state/dotfiles/windows-files.deployed.json) を比べて決める:
#
#   置き先が無い                           コピーする
#   置き先が計画と同じ中身                 何もしない (記録が無ければ記録だけする)
#   置き先が記録と同じ中身 (計画とは違う)  repo 側が更新された。上書きする
#   それ以外                               Windows 側で変わった (衝突)。diff を出して触らない
#
# 衝突が 1 件でもあれば、全部を処理し終えてから exit 1 する。解き方 (Windows 側の
# 変更を win/ へ取り込む / --force で上書きする) はメッセージに出す。
#
# 書き込みは置き先と同じディレクトリの一時ファイルから mv する (途中で落ちても壊れた
# ファイルを残さない)。置き先を書き換えたら manifest の hint を出す (Orca のように、
# ファイルを監視せず読み直しを手で頼むアプリのため)。manifest から消したファイルは
# Windows 側から消さない (アプリが持つファイルなので)。
#
# ## なぜ Nix でやらないのか
#
# 置き先のファイルは Windows 側のアプリが自分で書き換える (Orca は設定画面から保存する)。
# store への read-only な symlink は置けず、symlink にしても Orca の保存 (tmp に書いて
# rename) で実ファイルに置き換わる。switch が /mnt/c を書く (home.activation) と衝突を
# 上書きするしかなくなる。Claude Code の settings.json と同じ切り分け (ADR 007 / 010)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
repo 直下の win/ にある Windows 側のアプリの設定を、/mnt/c へコピーして配る。

使い方:
  bootstrap-windows-files.sh            配る
  bootstrap-windows-files.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-files.sh --force    衝突 (Windows 側で変わっていた) も上書きする
  bootstrap-windows-files.sh --check    win/manifest.toml の検証だけ (state も jq も要らない)
EOS
}

force=0
dry_run=0
check_only=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --check) check_only=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
win_dir="${repo_dir}/win"
lib_file="${repo_dir}/nix/lib/windows-files.nix"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-files.deployed.json"

if ! command -v nix-instantiate &>/dev/null; then
  echo "nix-instantiate が見つかりません (Nix が入っていないか、PATH に無い)。" >&2
  exit 1
fi

# win/manifest.toml を、置き先を解決した計画 (JSON) にする。$1 = windowsHome。
# 誤りがあれば nix-instantiate が stderr に理由を出して失敗する。
make_plan() {
  nix-instantiate --eval --strict --json "${lib_file}" \
    --argstr winDir "${win_dir}" \
    --argstr windowsHome "$1"
}

if ((check_only)); then
  if ! plan=$(make_plan /mnt/c/Users/CHECK); then
    echo "!! win/manifest.toml に誤りがあります (上のエラーを見てください)。" >&2
    exit 1
  fi
  # jq を使わずに数える (CI で devShell 無しに動かすため)。
  n=0
  rest=${plan}
  while [[ ${rest} == *'"dst":'* ]]; do
    n=$((n + 1))
    rest=${rest#*'"dst":'}
  done
  echo "win/manifest.toml: OK (${n} 件)"
  exit 0
fi

for cmd in jq sha256sum; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "${cmd} が見つかりません。先に home-manager switch を実行してください。" >&2
    exit 1
  fi
done

if [[ ! -r ${state_file} ]]; then
  echo "!! 配り先の設定がありません: ${state_file}" >&2
  echo "   dotfiles.wsl.windowsFiles を持つ世代へ先に home-manager switch してください。" >&2
  echo "   この手順は飛ばします。" >&2
  exit 0
fi

if ! jq -e 'type == "object"' "${state_file}" >/dev/null 2>&1; then
  echo "${state_file} が JSON の object ではありません。" >&2
  exit 1
fi

if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi

windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  echo "  /mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。" >&2
  exit 1
fi

if ! plan=$(make_plan "${windows_home}"); then
  echo "!! win/manifest.toml を計画にできませんでした (上のエラーを見てください)。" >&2
  exit 1
fi

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object"' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます" >&2
    echo "   (中身を確かめて、取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{}'
fi

if [[ $(jq '.files | length' <<<"${plan}") == 0 ]]; then
  echo "配るファイルはありません (win/manifest.toml に [[files]] が無い)。"
  exit 0
fi

tmp_file=""
trap 'if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT

sha() {
  sha256sum <"$1" | cut -d' ' -f1
}

# 置き先と同じディレクトリに一時ファイルを作ってから mv する (途中で落ちても
# 壊れたファイルを残さない)。$1 = コピー元、$2 = 置き先。
place() {
  mkdir -p "$(dirname -- "$2")"
  tmp_file=$(mktemp "$2.dotfiles-tmp.XXXXXX")
  cp -- "$1" "${tmp_file}"
  chmod 644 "${tmp_file}"
  mv -f -- "${tmp_file}" "$2"
  tmp_file=""
}

# 前回置いた中身として記録する。$1 = 置き先、$2 = sha256。
remember() {
  records=$(jq -c --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"${records}")
}

copied=0
updated=0
unchanged=0
conflicts=0
errors=0
hints=()

while IFS= read -r entry; do
  src=$(jq -r '.src' <<<"${entry}")
  dst=$(jq -r '.dst' <<<"${entry}")
  repo_path=$(jq -r '.repoPath' <<<"${entry}")
  hint=$(jq -r '.hint // ""' <<<"${entry}")
  want=$(sha "${src}")
  recorded=$(jq -r --arg k "${dst}" '.[$k] // ""' <<<"${records}")

  if [[ -d ${dst} ]]; then
    echo "!! 置き先がディレクトリです: ${dst}" >&2
    errors=$((errors + 1))
    continue
  fi

  if [[ ! -e ${dst} ]]; then
    action=copy
  else
    have=$(sha "${dst}")
    if [[ ${have} == "${want}" ]]; then
      action=same
    elif [[ -n ${recorded} && ${have} == "${recorded}" ]]; then
      action=update
    elif ((force)); then
      action=force
    else
      action=conflict
    fi
  fi

  case ${action} in
    same)
      unchanged=$((unchanged + 1))
      echo "同じです: ${dst}"
      if [[ ${recorded} != "${want}" ]] && ((! dry_run)); then
        remember "${dst}" "${want}"
      fi
      ;;
    conflict)
      conflicts=$((conflicts + 1))
      {
        echo "!! 衝突: ${dst} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
        diff -u --label "${dst} (Windows 側)" --label "${repo_path} (repo)" -- "${dst}" "${src}" || true
        echo "   Windows 側の変更を残すなら: cp '${dst}' '${repo_dir}/${repo_path}'"
        echo "   repo 側で上書きするなら:   ${script_dir}/bootstrap-windows-files.sh --force"
      } >&2
      ;;
    copy | update | force)
      case ${action} in
        copy) label="コピー" ;;
        update) label="上書き (repo 側が更新された)" ;;
        force) label="上書き (--force)" ;;
      esac
      if ((dry_run)); then
        echo "[dry-run] ${label}: ${dst}"
      else
        place "${src}" "${dst}"
        remember "${dst}" "${want}"
        echo "${label}: ${dst}"
        if [[ -n ${hint} ]]; then
          hints+=("${dst}: ${hint}")
        fi
      fi
      if [[ ${action} == copy ]]; then
        copied=$((copied + 1))
      else
        updated=$((updated + 1))
      fi
      ;;
  esac
done < <(jq -c '.files[]' <<<"${plan}")

# 記録を書く (変わったときだけ。--dry-run では書かない)。
if ((! dry_run)); then
  new_records=$(jq -S . <<<"${records}")
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  else
    old_records=$(jq -S . <<<'{}')
  fi
  if [[ ${new_records} != "${old_records}" ]]; then
    mkdir -p "${state_dir}"
    tmp_file=$(mktemp "${record_file}.XXXXXX")
    printf '%s\n' "${new_records}" >"${tmp_file}"
    mv -f -- "${tmp_file}" "${record_file}"
    tmp_file=""
  fi
fi

if ((${#hints[@]} > 0)); then
  echo
  echo "置いたファイルを、アプリに読み直させてください:"
  printf '  %s\n' "${hints[@]}"
fi

summary="コピー ${copied} / 上書き ${updated} / 同じ ${unchanged} / 衝突 ${conflicts}"
if ((errors > 0)); then
  summary+=" / エラー ${errors}"
fi
if ((dry_run)); then
  summary="[dry-run] ${summary}"
fi
echo
echo "${summary}"

if ((conflicts > 0 || errors > 0)); then
  exit 1
fi
