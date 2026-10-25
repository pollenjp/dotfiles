#!/usr/bin/env bash
# shellcheck shell=bash
#
# dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh\config.d へコピーし、config を置く (冪等。更新時も毎回走る)。
#
# order: 91
#
# ^ setup.sh が読む実行順。コピー元を取る bootstrap-dotfiles-private.sh (order: 50) より後に
#   走ればよい。衝突や確かめの失敗で exit 1 すると setup はここで止まる (後ろの 95〜99 と
#   exe-exec-trace は、直して流し直すまで走らない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# 1Password を使う WSL のマシンでは、WSL の ssh は Windows の ssh.exe を呼ぶラッパーで
# (ADR 004)、ssh.exe は Windows 側の %USERPROFILE%\.ssh\config を読む。そこにも WSL と同じ形
# (config は Include の 1 行とこのマシンを名乗る SetEnv、接続先は config.d) を作る
# (dotfiles-private の docs/adr/016_ssh_config_from_dotfiles_private_*。SetEnv は dotfiles-private の docs/adr/025_*)。
# 優先順位も WSL と同じく、config.d のファイル名の順になる。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く)。bootstrap-windows-files.sh
#   と同じく、無ければ飛ばし、enable が false なら何もしない
# - dotfiles-private の ssh/ 直下の *.ssh_config (通常のファイルだけ)。場所の決め方は
#   bootstrap-dotfiles-private.sh と同じ。無い・空なら、何も書かず消さずに警告して exit 0
# - ~/.local/state/dotfiles/windows-ssh-config.deployed.json (前回置いた中身の sha256)。
#   {"version":1,"files":{"<.ssh からの相対パス>":"<sha256>"}} の形
#
# ## 何をするか
#
# config と config.d/<名前>.ssh_config の 1 つずつを、置き先の中身と記録で判定する:
#
#   置き先が無い                            コピーする
#   置き先が正本と同じ中身                  何もしない (記録が無ければ記録だけする)
#   置き先が記録と同じ中身 (正本とは違う)   正本が更新された。上書きする
#   config が旧経路の Include の 1 行だけ  置き換える (ADR 013 で消した旧経路からの移行)
#   それ以外                                衝突。diff を出して触らない (--force なら退避して上書き)
#
# 衝突のメッセージは、記録があれば「Windows 側で変わった」、無ければ「この script が置く前から
# Windows 側にあった」(手で書いた config など) と分けて出す。
#
# 記録にあって正本から消えたファイルは、置き先が記録と同じなら消す。違えば衝突 (--force なら
# 退避して消す)。記録に無いファイル (my-cloud などが書いたもの) には触らない。
# 退避は <名前>.dotfiles-bak-<日時>、一時ファイルは <名前>.dotfiles-tmp.XXXXXX で、どちらも
# *.ssh_config で終わらないので Include されない。
#
# 書いたあとに ssh.exe -v -G nonexistent.invalid を流して、読んだファイルを確かめる (TKT-147)。
# Bad owner or permissions が出た・設定の誤りなどで読み終えられない (exit 255 など)・置いたファイルが
# 読まれない・旧 clone の ssh_config を読んだ、のどれかなら、衝突と同じく ⚠ の枠で出して exit 1。
# ssh.exe を呼べない (interop が外れているなど)・応答しない (時間切れ。SIGTERM を無視されたら
# KILL する) ときは、手で打つコマンドを出して exit 0。

set -eu -o pipefail

usage() {
  cat <<'EOS'
dotfiles-private の ssh/*.ssh_config を Windows の %USERPROFILE%\.ssh へコピーし、config を置く。

使い方:
  bootstrap-windows-ssh-config.sh            配る (書いたあとに ssh.exe で読ませて確かめる)
  bootstrap-windows-ssh-config.sh --dry-run  判定だけ出して何も書かない (確かめも流さない)
  bootstrap-windows-ssh-config.sh --force    衝突も、元を <名前>.dotfiles-bak-<日時> に退避して上書き・削除する
EOS
}

force=0
dry_run=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
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
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-ssh-config.deployed.json"
legacy_line='Include ~/dotfiles/ssh_config'
# 確かめで ssh.exe を待つ秒数 (テストで縮める)
check_timeout=${BOOTSTRAP_SSH_CHECK_TIMEOUT:-30}

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

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

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

# Windows の config の中身。WSL の Nix 管理の ~/.ssh/config (home/modules/ssh.nix の
# programs.ssh.includes と settings."*") と同じ Include の 1 行と、Include の後ろの Host * の SetEnv に、
# 持ち主を示すコメントを添える。SetEnv は ssh 先の herdr の固定名が同じマシンからの接続を見分けるのに使う
# (ADR 025。Windows の ssh.exe は OpenSSH_for_Windows 10.0p2 で、%u@%L を展開する)。
config_body() {
  cat <<'EOF'
# dotfiles の nix/scripts/bootstrap-windows-ssh-config.sh が置く (手で直すと次の setup で衝突になる)。
# マシン固有の Host は config.d\ に <名前>.ssh_config として置く。
# config.d はファイル名の順に読み、同じキーは先に読んだ値が効く。
Include config.d/*.ssh_config

# ssh 先の herdr が「同じマシンから来た接続」を見分けるのに、このマシンを名乗る (dotfiles の ADR 025)。
# 受け取る側の sshd に AcceptEnv PJP_SSH_CLIENT が要る。ssh は最初に当たった SetEnv の行だけを使うので、
# config.d の Host に SetEnv を書いたら、そこにも PJP_SSH_CLIENT=%u@%L を足す。
Host *
  SetEnv PJP_SSH_CLIENT=%u@%L
EOF
}

# ssh.exe で確かめられなかったときに、同じことを手で確かめるコマンド (warn の続きの行にする)
manual_check() {
  echo "Windows の PowerShell で次を打つと、読んだファイルを確かめられます:"
  echo "  ssh -v -G nonexistent.invalid 2>&1 | Select-String 'Reading configuration'"
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${state_file} ]]; then
  warn "配り先の設定がありません: ${state_file}" \
    "dotfiles.wsl.windowsFiles を持つ世代へ先に home-manager switch してください。" \
    "この手順は飛ばします。"
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
if ! command -v sha256sum &>/dev/null; then
  echo "sha256sum が見つかりません (coreutils)。置き先の中身を比べられないので配れません。" >&2
  exit 1
fi

src_dir="$(private_dir)/ssh"
win_ssh="${windows_home}/.ssh"

srcs=()
if [[ -d ${src_dir} ]]; then
  for src in "${src_dir}"/*.ssh_config; do
    if [[ -f ${src} && ! -L ${src} ]]; then
      srcs+=("${src}")
    fi
  done
fi
if ((${#srcs[@]} == 0)); then
  warn "Windows の ssh の設定を配りません: 正本の *.ssh_config がありません (${src_dir})。" \
    "dotfiles-private を取れていないか、ssh/ が空です。Windows 側のファイルはそのまま残します。" \
    "取るには: ${script_dir}/bootstrap-dotfiles-private.sh"
  exit 0
fi

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object" and (.files | type == "object")' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (files を持つ JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます" >&2
    echo "   (中身を確かめて、dotfiles-private へ取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{"version":1,"files":{}}'
fi

work=$(mktemp -d)
tmp_file=""
trap 'rm -rf "${work}"; if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT
config_body >"${work}/config"

# 計画: .ssh からの相対パスと、そのコピー元
plan_rel=(config)
plan_src=("${work}/config")
for src in "${srcs[@]}"; do
  plan_rel+=("config.d/$(basename "${src}")")
  plan_src+=("${src}")
done

sha() {
  sha256sum <"$1" | cut -d' ' -f1
}
recorded() {
  jq -r --arg k "$1" '.files[$k] // ""' <<<"${records}"
}
remember() {
  records=$(jq -c --arg k "$1" --arg v "$2" '.files[$k] = $v' <<<"${records}")
}
forget() {
  records=$(jq -c --arg k "$1" 'del(.files[$k])' <<<"${records}")
}
in_plan() {
  local p
  for p in "${plan_rel[@]}"; do
    if [[ ${p} == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# 置き先と同じディレクトリの一時ファイルに書いてから mv する。$1 = コピー元、$2 = 置き先。
place() {
  mkdir -p "$(dirname -- "$2")"
  tmp_file=$(mktemp "$2.dotfiles-tmp.XXXXXX")
  cp -- "$1" "${tmp_file}"
  mv -f -- "${tmp_file}" "$2"
  tmp_file=""
}

# --force で上書き・削除する前に、元を <名前>.dotfiles-bak-<日時> に残す
backup() {
  local bak
  bak="$1.dotfiles-bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$1" "${bak}"
  log+=("  退避した: ${bak}")
}

# config が旧経路の Include の 1 行だけか。BOM・CR・行の前後の空白・空行は無視する。
is_legacy_config() {
  local body
  body=$(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -- "$1" | grep -v '^$' || true)
  [[ ${body} == "${legacy_line}" ]]
}

log=()
conflicts=()
changed=0
pre=""
if ((dry_run)); then
  pre="[dry-run] "
fi

for i in "${!plan_rel[@]}"; do
  rel=${plan_rel[i]}
  src=${plan_src[i]}
  dst="${win_ssh}/${rel}"
  want=$(sha "${src}")
  rec=$(recorded "${rel}")

  if [[ -d ${dst} ]]; then
    warn "置き先がディレクトリです: ${dst}"
    conflicts+=("${rel} (ディレクトリ)")
    continue
  fi

  if [[ ! -e ${dst} ]]; then
    action=copy
  else
    have=$(sha "${dst}")
    if [[ ${have} == "${want}" ]]; then
      action=same
    elif [[ -n ${rec} && ${have} == "${rec}" ]]; then
      action=update
    elif [[ ${rel} == config ]] && is_legacy_config "${dst}"; then
      action=legacy
    elif ((force)); then
      action=force
    else
      action=conflict
    fi
  fi

  case ${action} in
    same)
      if [[ ${rec} != "${want}" ]] && ((! dry_run)); then
        remember "${rel}" "${want}"
      fi
      ;;
    conflict)
      conflicts+=("${rel}")
      {
        if [[ -n ${rec} ]]; then
          echo "!! 衝突: ${dst} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
        else
          echo "!! 衝突: ${dst} は、置いた記録が無く、正本と中身が違います (この script が置く前から Windows 側にあった。手で書いたものなど)。"
        fi
        diff -u --label "${rel} (Windows 側)" --label "${rel} (dotfiles)" -- "${dst}" "${src}" || true
      } >&2
      ;;
    copy | update | legacy | force)
      case ${action} in
        copy) label="コピー" ;;
        update) label="上書き (正本が更新された)" ;;
        legacy) label="置き換え (旧経路の Include ~/dotfiles/ssh_config)" ;;
        force) label="上書き (--force)" ;;
      esac
      if ((! dry_run)); then
        if [[ ${action} == force ]]; then
          backup "${dst}"
        fi
        place "${src}" "${dst}"
        remember "${rel}" "${want}"
      fi
      log+=("  ${pre}${rel}: ${label}")
      changed=$((changed + 1))
      ;;
  esac
done

# 記録にあって、正本から消えたファイル
while IFS= read -r rel; do
  if [[ -z ${rel} ]] || in_plan "${rel}"; then
    continue
  fi
  dst="${win_ssh}/${rel}"
  rec=$(recorded "${rel}")
  if [[ ! -e ${dst} ]]; then
    if ((! dry_run)); then
      forget "${rel}"
    fi
    continue
  fi
  have=$(sha "${dst}")
  if [[ ${have} != "${rec}" ]] && ((! force)); then
    conflicts+=("${rel} (正本から消えた)")
    echo "!! 衝突: ${dst} は正本から消えましたが、Windows 側で変わっているので消していません。" >&2
    continue
  fi
  if ((! dry_run)); then
    if [[ ${have} != "${rec}" ]]; then
      backup "${dst}"
    fi
    rm -f -- "${dst}"
    forget "${rel}"
  fi
  log+=("  ${pre}${rel}: 削除 (正本から消えた)")
  changed=$((changed + 1))
done < <(jq -r '.files | keys[]' <<<"${records}")

# 記録を書く (変わったときだけ。--dry-run では書かない)
if ((! dry_run)); then
  new_records=$(jq -S '.version = 1' <<<"${records}")
  old_records=""
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  fi
  if [[ ${new_records} != "${old_records}" ]]; then
    mkdir -p "${state_dir}"
    tmp_file=$(mktemp "${record_file}.XXXXXX")
    printf '%s\n' "${new_records}" >"${tmp_file}"
    mv -f -- "${tmp_file}" "${record_file}"
    tmp_file=""
  fi
fi

# 書いたあとの確かめ (TKT-147): ssh.exe に読ませて、読んだファイルを見る
check_failed=()
checked=0
if ((! dry_run)); then
  expect=()
  for rel in "${plan_rel[@]}"; do
    if [[ -f ${win_ssh}/${rel} ]]; then
      expect+=("${rel}")
    fi
  done
  if ! command -v ssh.exe &>/dev/null; then
    warn "ssh.exe が見つからないので、Windows の ssh が読むファイルを確かめていません。" "$(manual_check)"
  else
    rc=0
    # -k: SIGTERM を無視されても、少し待って KILL する (setup を止めない)
    out=$(timeout -k 5 "${check_timeout}" ssh.exe -v -G nonexistent.invalid </dev/null 2>&1 >/dev/null) || rc=$?
    out=$(printf '%s\n' "${out}" | tr -d '\r')
    if grep -q 'Bad owner or permissions' <<<"${out}"; then
      check_failed+=("ssh.exe がアクセス権を理由に設定を読みませんでした (どの接続先でも exit 255 になります):")
      while IFS= read -r line; do
        check_failed+=("  ${line}")
      done < <(grep -E 'Bad (owner|permissions)' <<<"${out}")
      check_failed+=("  .ssh の ACL を見る: icacls.exe '$(wslpath -w "${win_ssh}" 2>/dev/null || printf '%s' "${win_ssh}")'")
    elif ((rc == 124 || rc == 126 || rc == 127 || rc == 137)) || ! grep -q 'Reading configuration data' <<<"${out}"; then
      # 時間切れ (124・KILL の 137) と、起動できない (126・127) は、確かめられなかったものとして扱う。
      # ssh.exe の出力 (あれば先頭の 5 行) と、手で打つコマンドを続きの行にする
      out_head=$(printf '%s\n' "${out}" | head -5)
      warn "ssh.exe で確かめられませんでした (終了コード ${rc}。WSL の interop が落ちているか、ssh.exe が応答しません)。" \
        ${out_head:+"${out_head}"} "$(manual_check)"
    elif ((rc != 0)); then
      # 設定の誤りなどで読み終えられなかった。ssh.exe はどの接続先でも同じように失敗する
      check_failed+=("ssh.exe が設定を読み終えられませんでした (終了コード ${rc}。どの接続先でも同じように失敗します):")
      while IFS= read -r line; do
        check_failed+=("  ${line}")
      done < <(grep -v '^debug' <<<"${out}" | head -5)
    else
      # ssh.exe は C:\\Users\\<名前>/.ssh/config のように出すので、/ 区切りの小文字に揃えて末尾で比べる
      read_paths=$(sed -n 's/^debug1: Reading configuration data //p' <<<"${out}" \
        | sed -e 's#\\#/#g' -e 's#//*#/#g' | tr '[:upper:]' '[:lower:]')
      missing=()
      for rel in "${expect[@]}"; do
        suffix=$(printf '/.ssh/%s' "${rel}" | tr '[:upper:]' '[:lower:]')
        found=0
        while IFS= read -r p; do
          if [[ ${p} == *"${suffix}" ]]; then
            found=1
            break
          fi
        done <<<"${read_paths}"
        if ((! found)); then
          missing+=("${rel}")
        fi
      done
      if ((${#missing[@]} > 0)); then
        check_failed+=("ssh.exe が読まなかったファイルがあります (Include されていない):")
        for rel in "${missing[@]}"; do
          check_failed+=("  ${win_ssh}/${rel}")
        done
      fi
      if grep -q '/dotfiles/ssh_config$' <<<"${read_paths}"; then
        check_failed+=("ssh.exe が旧 clone の ssh_config を読んでいます (config が旧経路の Include のまま)。")
      fi
      checked=1
    fi
  fi
fi

n=$((${#plan_rel[@]} - 1))
if ((changed == 0 && ${#conflicts[@]} == 0 && ${#check_failed[@]} == 0)); then
  if ((checked)); then
    echo "Windows の ssh の設定は揃っています (config と config.d の ${n} 件。ssh.exe が読むことも確かめた)。"
  else
    echo "Windows の ssh の設定は揃っています (config と config.d の ${n} 件)。"
  fi
  exit 0
fi

echo "==> ${pre}Windows の ssh の設定 (${win_ssh})"
if ((${#log[@]} > 0)); then
  printf '%s\n' "${log[@]}"
fi
if ((checked && ${#check_failed[@]} == 0)); then
  echo "  確かめ: ssh.exe が config と config.d の ${n} 件を読んだ (旧 clone の ssh_config は読んでいない)"
fi

if ((${#conflicts[@]} == 0 && ${#check_failed[@]} == 0)); then
  exit 0
fi

rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
{
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  printf '%s⚠️  Windows の ssh の設定に、手で直すことがあります%s\n' "${c_warn}" "${c_reset}"
  if ((${#conflicts[@]} > 0)); then
    printf '%s⚠️  Windows 側で変わっていた (か、置く前からあった) ので、次のファイルには触っていません (diff は上):%s\n' "${c_warn}" "${c_reset}"
    for rel in "${conflicts[@]}"; do
      printf '%s⚠️    %s%s\n' "${c_warn}" "${rel}" "${c_reset}"
    done
    printf '%s⚠️  解き方 (どちらか):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    1. Windows 側の中身を dotfiles-private の ssh/ へ取り込み、commit して push する%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       (config に手で書いた Host は config.d\\<名前>.ssh_config へ移す)%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    2. 上書きする (元は <名前>.dotfiles-bak-<日時> に残る):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-ssh-config.sh --force%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
  fi
  for line in "${check_failed[@]}"; do
    printf '%s⚠️  %s%s\n' "${c_warn}" "${line}" "${c_reset}"
  done
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
} >&2
exit 1
