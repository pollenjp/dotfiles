#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-google-ime.sh の振る舞いを、使い捨ての HOME と
# 偽の tasklist.exe / taskkill.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-google-ime.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-google-ime-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・git・coreutils・findutils・diffutils・grep・sed と、PATH の pjp-google-ime、
# protobuf の入った python3 (辞書のファイルを組む。記述子は PJP_GOOGLE_IME_DESCRIPTORS で受け取る)。
#
# ## 確かめること
#
#   - 配らないマシン・Google 日本語入力が入っていないマシンは飛ばす (exit 0)
#   - interop (tasklist.exe) が使えなければ置かずに exit 0。設定画面が開いていれば exit 1
#   - 壊れたテキストは何も置かずに exit 1 (行番号を出す)
#   - 4 通りの判定 (置く・同じ・repo 側が進んだ・衝突)、画面で保存しただけ (時刻だけ違う) は「同じ」
#   - 置いたときだけ taskkill.exe /F で変換サーバーを落とす。動いていない (128) のは成功扱い
#   - 落とせなかったら印を残し、次の回が置くものが無くても落とし直す (--dry-run は印に触らない)
#   - 退避は新しい方から 10 回分。--force / --dry-run / --import / --check
#   - --import と --dry-run は一緒に使えない。--import は commit していない変更があると止まる
#   - 辞書のテキストが無ければ辞書は飛ばす (Windows 側の辞書を消さない)
#   - 単語登録の形の辞書 (comment の無い語) も取り込め、取り込んだ後は「同じ」
#   - 辞書の衝突は語を出さず、辞書ごとの行の数だけを出す (--show-words で diff)
#   - 入っているがまだ使っていない (置き先が無い) ときは、一度使ってから流し直すよう出す (exit 0)
#   - --import は、同じディレクトリの Install-GoogleJapaneseInput.ps1 の変更では止まらない
#   - --import は 3 つのテキストのどれの変更 (削除・staged・未追跡も) でも止まり、止めたときの一覧には止める理由のファイルだけを出す
#   - 「まだ使っていない」の案内は stderr に出す (stdout は空)。exe が無く、Program Files にディレクトリだけ残っているなら入っていない扱い
#
# ## 偽の repo と dotfiles-private
#
# どちらも git の checkout にする (--import が commit していない変更を確かめるため)。git は
# 使い捨ての設定で動かし、偽の HOME より上の repo を拾わない (GIT_CEILING_DIRECTORIES)。
#
# ## 本物の Windows のコマンドを見せない
#
# WSL では PATH に本物の tasklist.exe と taskkill.exe がある。見えると本物の変換サーバーを
# 落としうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-herdr.test.sh
# と同じ作り)。偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。
#
# script は、偽の repo (<HOME>/repo/nix/scripts/) に写してから流す。script は自分の場所から
# repo の win/google-japanese-input/ を探すため。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-google-ime.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-google-ime-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CEILING_DIRECTORIES="${work}"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

txtpb='session_keymap: CUSTOM
punctuation_method: TOUTEN_KUTEN
'
keymap=$'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\n'
keymap2=$'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\nComposition\tF13\tIMEOff\n'
dict=$'てすと\tテスト\t名詞\t\n'

# 要るコマンドだけを並べた PATH (tasklist.exe と taskkill.exe は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail mkdir mktemp mv rm cp dirname basename chmod date sort find diff cmp comm wc timeout git python3 pjp-google-ime; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Google 日本語入力が入っている (ディレクトリがある) 状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。repo は <HOME>/repo、dotfiles-private は <HOME>/private。
new_home() {
  local h="${work}/$1" d
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win" "${h}/repo/nix/scripts" \
    "${h}/repo/win/google-japanese-input" "${h}/private/google-japanese-input/dictionaries"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/LocalLow/Google/Google Japanese Input"
  fi
  cp "${script}" "${h}/repo/nix/scripts/bootstrap-windows-google-ime.sh"
  printf '%s' "${txtpb}" >"${h}/repo/win/google-japanese-input/config.txtpb"
  printf '%s' "${keymap}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
  printf '%s' "${dict}" >"${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"
  # 偽の repo と dotfiles-private は、最初の中身を commit した git の checkout にする
  for d in "${h}/repo" "${h}/private"; do
    git -C "${d}" init --quiet -b main
    git -C "${d}" add -A
    git -C "${d}" commit --quiet -m init
  done
  # 偽の tasklist.exe。FAKE_TOOL_RUNNING があれば設定画面が開いている行を、無ければ (日本語の) 見つからない行を出す
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/tasklist-calls"
if [[ -n ${FAKE_TOOL_RUNNING-} ]]; then
  printf '"GoogleIMEJaTool.exe","4242","Console","3","25,000 K"\r\n'
else
  printf '情報: 指定された条件に一致するタスクは実行されていません。\r\n'
fi
exit "${FAKE_TASKLIST_RC:-0}"
EOF
  } >"${h}/bin/tasklist.exe"
  # 偽の taskkill.exe。引数を記録し、FAKE_TASKKILL_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/taskkill-calls"
exit "${FAKE_TASKKILL_RC:-0}"
EOF
  } >"${h}/bin/taskkill.exe"
  chmod +x "${h}/bin/tasklist.exe" "${h}/bin/taskkill.exe"
  echo "${h}"
}

# $1: HOME、$2: 1 なら tasklist.exe / taskkill.exe を PATH に置かない、残り: script の引数
run() {
  local h=$1 nointerop=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nointerop} == 1 ]]; then
    path="${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" DOTFILES_PRIVATE_DIR="${h}/private" \
    "${BASH}" "${h}/repo/nix/scripts/bootstrap-windows-google-ime.sh" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
ime() { echo "$1/win/AppData/LocalLow/Google/Google Japanese Input"; }
killed() { [[ -s $1/taskkill-calls ]]; }
nkills() { grep -c '' "$1/taskkill-calls" 2>/dev/null || echo 0; }
digest() { pjp-google-ime digest --kind "$1" "$2"; }

# 偽の repo のテキストから組み立てたものを、Windows 側に「画面で作った」ものとして置く。$1: HOME、$2: keymap
put_windows() {
  local d="${work}/gui-$$-${RANDOM}"
  mkdir -p "${d}/conf"
  printf '%s' "${txtpb}" >"${d}/conf/config.txtpb"
  printf '%s' "$2" >"${d}/conf/keymap.tsv"
  pjp-google-ime build --config-dir "${d}/conf" --out "${d}/out" >/dev/null
  cp "${d}/out/config1.db" "$(ime "$1")/config1.db"
}

# Windows 側の辞書を、TSV から組み立てたものにする (画面で語を足した・消したことに見立てる)。
# $1: HOME、残り: 「辞書の名前=TSV の中身」
put_windows_dictionaries() {
  local h=$1 d="${work}/gui-$$-${RANDOM}" kv
  shift
  mkdir -p "${d}/conf" "${d}/dicts"
  printf '%s' "${txtpb}" >"${d}/conf/config.txtpb"
  printf '%s' "${keymap}" >"${d}/conf/keymap.tsv"
  for kv in "$@"; do
    printf '%s' "${kv#*=}" >"${d}/dicts/${kv%%=*}.tsv"
  done
  pjp-google-ime build --config-dir "${d}/conf" --dictionary-dir "${d}/dicts" --out "${d}/out" >/dev/null
  cp "${d}/out/user_dictionary.db" "$(ime "${h}")/user_dictionary.db"
}

# protobuf で Windows 側の辞書を組む (pjp-google-ime build では作れない形)。辞書は「テスト辞書」1 つで、
# 表で編集した語 (コメントが空でも comment を入れる) の「てすと」を持つ。$1: HOME、$2 は足すもの:
#   wordreg  単語登録ダイアログで足した語 (comment を入れない。Mozc の WordRegisterDialog::SaveEntry)
#   version  TSV に出ない項目 (UserDictionaryStorage の version)
put_windows_proto_dictionary() {
  python3 -I - "$(ime "$1")/user_dictionary.db" "$2" <<'EOF'
import os
import sys

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

with open(os.environ["PJP_GOOGLE_IME_DESCRIPTORS"], "rb") as f:
    fds = descriptor_pb2.FileDescriptorSet.FromString(f.read())
pool = descriptor_pool.DescriptorPool()
for f in fds.file:
    pool.Add(f)
storage = message_factory.GetMessageClass(pool.FindMessageTypeByName("mozc.user_dictionary.UserDictionaryStorage"))()
d = storage.dictionaries.add()
d.id = 11262860659733797146  # 画面で作った辞書のような乱数の id
d.name = "テスト辞書"
e = d.entries.add()
e.key, e.value, e.comment, e.pos = "てすと", "テスト", "", 1  # 1 = 名詞
if sys.argv[2] == "wordreg":
    e = d.entries.add()
    e.key, e.value, e.pos = "かくうのよみ", "架空の単語", 1
else:
    storage.version = 1
with open(sys.argv[1], "wb") as out:
    out.write(storage.SerializeToString(deterministic=True))
EOF
}

pending_of() { echo "$1/.local/state/dotfiles/google-japanese-input/restart-pending"; }
tsv_of() { echo "$1/private/google-japanese-input/dictionaries/$2.tsv"; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-google-ime.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! killed "${h}" && outerr "${h}" | grep -q '飛ばします' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "windows-files.json が無ければ飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '配りません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "enable = false なら飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Google 日本語入力が入っていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '入っていません' && [[ ! -e ${h}/tasklist-calls ]]; then
  ok "Google 日本語入力が入っていなければ飛ばす"
else
  ng "入っていない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. interop が無い (tasklist.exe が見つからない): 置かずに exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '置きません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "interop が無ければ置かずに exit 0"
else
  ng "interop が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. tasklist.exe が失敗する: 置かずに exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_TASKLIST_RC=126 run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '置きません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "tasklist.exe が失敗したら置かずに exit 0"
else
  ng "tasklist.exe が失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 設定画面が開いている: exit 1、何も置かない
h=$(new_home t6 "${state_on}" 1)
FAKE_TOOL_RUNNING=1 run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'GoogleIMEJaTool.exe' && [[ ! -e $(ime "${h}")/config1.db ]] && ! killed "${h}"; then
  ok "設定画面が開いていれば exit 1 で何も置かない"
else
  ng "設定画面が開いている" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. 壊れたテキスト: exit 1、行番号を出し、何も置かない
h=$(new_home t7 "${state_on}" 1)
printf '%s' "${keymap}"$'Composition\tF13\n' >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'keymap.tsv:4:' && [[ ! -e $(ime "${h}")/config1.db ]] && ! killed "${h}"; then
  ok "壊れたテキストは行番号を出して exit 1 (何も置かない)"
else
  ng "壊れたテキスト" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. 初めて置く: 2 つとも置き、記録し、taskkill.exe /F で 1 回だけ落とす
h=$(new_home t8 "${state_on}" 1)
run "${h}" 0
rec="${h}/.local/state/dotfiles/google-japanese-input/deployed.json"
if [[ $(rc "${h}") == 0 && -f "$(ime "${h}")/config1.db" && -f "$(ime "${h}")/user_dictionary.db" && $(nkills "${h}") == 1 ]] \
  && grep -qF '/F /IM GoogleIMEJaConverter.exe' "${h}/taskkill-calls" \
  && [[ $(jq -r '."config1.db"' "${rec}") == "$(digest config "$(ime "${h}")/config1.db")" ]]; then
  ok "初めては 2 つとも置いて記録し、変換サーバーを 1 回落とす"
else
  ng "初めて置く" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 9. 2 回目: 同じなので何もしない (落とさない)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 ]] && outerr "${h}" | grep -q '同じです'; then
  ok "2 回目は同じなので何もせず、落とさない"
else
  ng "2 回目" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 10. 画面で OK を押しただけ (general_config だけが入った): 同じ扱い
printf '\x0a\x02\x18\x01' >>"$(ime "${h}")/config1.db"
before=$(cat "$(ime "${h}")/config1.db" | od -An -tx1 | tr -d ' \n')
run "${h}" 0
after=$(cat "$(ime "${h}")/config1.db" | od -An -tx1 | tr -d ' \n')
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 && ${before} == "${after}" ]] && outerr "${h}" | grep -q '同じです: .*config1.db'; then
  ok "時刻だけが違う (画面で保存しただけ) なら同じ扱いで、Windows 側のファイルに触らない"
else
  ng "時刻だけ違う" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 11. repo 側が進んだ: 退避してから上書きし、落とす
printf '%s' "${keymap2}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
backups=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -name config1.db | grep -c '')
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 2 && ${backups} == 1 ]] && outerr "${h}" | grep -q 'repo 側が進んだ' \
  && pjp-google-ime decode --kind config "$(ime "${h}")/config1.db" --out "${h}/dec" && grep -q '^Composition' "${h}/dec/keymap.tsv"; then
  ok "repo 側が進んだら退避して上書きし、変換サーバーを落とす"
else
  ng "repo 側が進んだ" "rc=$(rc "${h}") kills=$(nkills "${h}") backups=${backups} $(outerr "${h}")"
fi

# 12. 画面で変えた (記録とも組み立てたものとも違う): 衝突。diff を出して exit 1、触らない
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
before=$(digest config "$(ime "${h}")/config1.db")
run "${h}" 0
if [[ $(rc "${h}") == 1 && $(digest config "$(ime "${h}")/config1.db") == "${before}" && $(nkills "${h}") == 2 ]] \
  && outerr "${h}" | grep -q '衝突' && outerr "${h}" | grep -q '^--- Windows 側/keymap.tsv' \
  && outerr "${h}" | grep -q '^+Precomposition' && outerr "${h}" | grep -qF -- '--import' && outerr "${h}" | grep -qF -- '--force'; then
  ok "画面で変えていたら衝突として diff (- が Windows 側) と解き方を出し、触らずに exit 1"
else
  ng "衝突" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 13. --dry-run: 判定だけ (書かない・落とさない・tasklist.exe も呼ばない)
rm -f "${h}/tasklist-calls"
run "${h}" 0 --dry-run
if [[ $(rc "${h}") == 1 && $(digest config "$(ime "${h}")/config1.db") == "${before}" && $(nkills "${h}") == 2 && ! -e ${h}/tasklist-calls ]]; then
  ok "--dry-run は判定だけで、書かず、落とさず、衝突なら exit 1"
else
  ng "--dry-run" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 14. --import: Windows 側をテキストへ取り込み、記録を合わせる。次は同じ
# (11 で進めた repo 側を先に commit する。commit していない変更があると --import は止まる)
git -C "${h}/repo" commit --quiet -am 'repo 側を進めた'
run "${h}" 0 --import
imported_rc=$(rc "${h}")
run "${h}" 0
if [[ ${imported_rc} == 0 && $(rc "${h}") == 0 && $(nkills "${h}") == 2 ]] \
  && ! grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" && outerr "${h}" | grep -q '同じです: .*config1.db'; then
  ok "--import は Windows 側をテキストへ取り込み、次の実行は同じになる"
else
  ng "--import" "import_rc=${imported_rc} rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. --force: 衝突でも置き直す
h=$(new_home t15 "${state_on}" 1)
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 ]] && outerr "${h}" | grep -q '上書き (--force)' \
  && pjp-google-ime decode --kind config "$(ime "${h}")/config1.db" --out "${h}/dec" && grep -q '^Precomposition' "${h}/dec/keymap.tsv"; then
  ok "--force は衝突でも repo の中身で置き直す"
else
  ng "--force" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 16. 読めない (壊れた) Windows 側のファイル: 衝突として扱い、traceback を出さない
h=$(new_home t16 "${state_on}" 1)
printf '\xff\xff\xff' >"$(ime "${h}")/config1.db"
run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '衝突' && ! outerr "${h}" | grep -q 'Traceback'; then
  ok "読めない Windows 側のファイルは衝突として扱う (traceback を出さない)"
else
  ng "読めないファイル" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. 辞書のテキストが無い: 設定だけ置き、Windows 側の辞書は残す
h=$(new_home t17 "${state_on}" 1)
rm -rf "${h}/private/google-japanese-input"
printf 'windows-dictionary' >"$(ime "${h}")/user_dictionary.db"
run "${h}" 0
if [[ $(rc "${h}") == 0 && -f "$(ime "${h}")/config1.db" && $(cat "$(ime "${h}")/user_dictionary.db") == windows-dictionary ]] \
  && outerr "${h}" | grep -q '辞書は飛ばします'; then
  ok "辞書のテキストが無ければ辞書は飛ばし、Windows 側の辞書を残す"
else
  ng "辞書のテキストが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 18. 退避は新しい方から 10 回分だけ残す
h=$(new_home t18 "${state_on}" 1)
run "${h}" 0
for i in $(seq 1 11); do
  mkdir -p "${h}/.local/state/dotfiles/google-japanese-input/backup/20000101T0000$(printf '%02d' "${i}")Z-1"
done
printf '%s' "${keymap2}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
n=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -mindepth 1 -maxdepth 1 -type d | grep -c '')
oldest=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
if [[ $(rc "${h}") == 0 && ${n} == 10 && ${oldest} == *20000101T000003Z-1 ]]; then
  ok "退避は新しい方から 10 回分だけ残す"
else
  ng "退避の間引き" "rc=$(rc "${h}") n=${n} oldest=${oldest} $(outerr "${h}")"
fi

# 19. 変換サーバーが動いていない (taskkill.exe が 128): 成功扱い
h=$(new_home t19 "${state_on}" 1)
FAKE_TASKKILL_RC=128 run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '動いていませんでした'; then
  ok "変換サーバーが動いていなければ (128) 成功扱い"
else
  ng "128" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20. taskkill.exe がほかの理由で失敗: exit 1 で、手で終了する方法を出す
h=$(new_home t20 "${state_on}" 1)
FAKE_TASKKILL_RC=1 run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'タスクマネージャー'; then
  ok "変換サーバーを落とせなければ exit 1 で、手で終了する方法を出す"
else
  ng "taskkill 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 21. --check: state も Windows も無くても、テキストだけ確かめる
h=$(new_home t21 "" 0)
run "${h}" 1 --check
check_ok=$(rc "${h}")
printf '%s' $'status\tkey\tcommand\nDirect input\tF13\tIMEOn\n' >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 1 --check
if [[ ${check_ok} == 0 && $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'keymap.tsv:2:'; then
  ok "--check は state も Windows も無しでテキストを確かめる"
else
  ng "--check" "ok_rc=${check_ok} rc=$(rc "${h}") $(outerr "${h}")"
fi

# 22. --import と --dry-run を一緒に付けると exit 2。何も書かない (repo のテキスト・辞書・記録・変換サーバーに触らない)
h=$(new_home t22 "${state_on}" 1)
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
cp "${h}/repo/win/google-japanese-input/keymap.tsv" "${h}/keymap.before"
before=$(digest config "$(ime "${h}")/config1.db")
run "${h}" 0 --import --dry-run
if [[ $(rc "${h}") == 2 ]] && outerr "${h}" | grep -q '一緒に使えません' \
  && cmp -s "${h}/keymap.before" "${h}/repo/win/google-japanese-input/keymap.tsv" \
  && [[ -f ${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv ]] \
  && [[ ! -e ${h}/.local/state/dotfiles/google-japanese-input/deployed.json ]] \
  && ! killed "${h}" && [[ $(digest config "$(ime "${h}")/config1.db") == "${before}" ]]; then
  ok "--import と --dry-run を一緒に付けると exit 2 で、何も書かない"
else
  ng "--import と --dry-run" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 23. 知らない引数: exit 2
h=$(new_home t23 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! killed "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 24. 単語登録の形の辞書 (comment の無い語) が Windows 側にある: 衝突になり、--import が通り、
#     次の実行は 2 つとも「同じです」。取り込んだ語の 4 列目 (コメント) は空
h=$(new_home t24 "${state_on}" 1)
if [[ -z ${PJP_GOOGLE_IME_DESCRIPTORS:-} ]]; then
  ng "単語登録の形の辞書" "PJP_GOOGLE_IME_DESCRIPTORS が無い (flake の check から流す)"
else
  put_windows "${h}" "${keymap}"
  put_windows_proto_dictionary "${h}" wordreg
  run "${h}" 0
  conflict_rc=$(rc "${h}")
  run "${h}" 0 --import
  import_rc=$(rc "${h}")
  import_log=$(outerr "${h}")
  run "${h}" 0
  if [[ ${conflict_rc} == 1 && ${import_rc} == 0 && $(rc "${h}") == 0 && $(outerr "${h}" | grep -c '^同じです: ') == 2 ]] \
    && grep -qxF $'かくうのよみ\t架空の単語\t名詞\t' "$(tsv_of "${h}" テスト辞書)" && ! killed "${h}"; then
    ok "単語登録の形の辞書 (comment の無い語) も --import で取り込め、次の実行は 2 つとも同じになる"
  else
    ng "単語登録の形の辞書" "conflict_rc=${conflict_rc} import_rc=${import_rc} rc=$(rc "${h}") ${import_log} $(outerr "${h}")"
  fi
fi

# 25. 変換サーバーを落とせなかった: 印を残して exit 1。次の回は 2 つとも「同じです」でも落とし直して
#     印を消し、その次の回は落とさない
h=$(new_home t25 "${state_on}" 1)
FAKE_TASKKILL_RC=1 run "${h}" 0
r1="rc=$(rc "${h}") kills=$(nkills "${h}") pending=$([[ -e $(pending_of "${h}") ]] && echo yes || echo no)"
log1=$(outerr "${h}")
run "${h}" 0
r2="rc=$(rc "${h}") kills=$(nkills "${h}") same=$(outerr "${h}" | grep -c '^同じです: ') pending=$([[ -e $(pending_of "${h}") ]] && echo yes || echo no)"
log2=$(outerr "${h}")
run "${h}" 0
r3="rc=$(rc "${h}") kills=$(nkills "${h}")"
if [[ ${r1} == "rc=1 kills=1 pending=yes" && ${r2} == "rc=0 kills=2 same=2 pending=no" && ${r3} == "rc=0 kills=2" ]] \
  && grep -q '次の setup でも落とし直します' <<<"${log1}" && grep -q '前回は変換サーバーを落とせなかったので、落とし直します' <<<"${log2}"; then
  ok "変換サーバーを落とせなければ印を残し、次の回は置くものが無くても落とし直して印を消す"
else
  ng "落とし直しの印" "1: ${r1} / 2: ${r2} / 3: ${r3}"$'\n'"${log1}"$'\n'"${log2}"
fi

# 26. 印がある回の --dry-run・interop が使えない回・--import は、印に触らず落とさない。
#     印がある回の衝突には、古い設定が書き戻されたものかもしれないと添える
h=$(new_home t26 "${state_on}" 1)
FAKE_TASKKILL_RC=1 run "${h}" 0
run "${h}" 0 --dry-run
dry="rc=$(rc "${h}") kills=$(nkills "${h}")"
dry_log=$(outerr "${h}")
FAKE_TASKLIST_RC=126 run "${h}" 0
nointerop="rc=$(rc "${h}") kills=$(nkills "${h}")"
run "${h}" 0 --import
imported="rc=$(rc "${h}") kills=$(nkills "${h}")"
if [[ ${dry} == "rc=0 kills=1" && ${nointerop} == "rc=0 kills=1" && ${imported} == "rc=0 kills=1" && -e $(pending_of "${h}") ]] \
  && grep -qF '[dry-run] 変換サーバーを落とし直します (前回落とせなかった)' <<<"${dry_log}"; then
  ok "印がある回の --dry-run・interop が使えない回・--import は、印を残して落とさない"
else
  ng "印と --dry-run" "dry: ${dry} / interop: ${nointerop} / import: ${imported}"$'\n'"${dry_log}"
fi
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
run "${h}" 0 --dry-run
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '前回は変換サーバーを落とせていません。この差は、古い設定が書き戻されたものかもしれません'; then
  ok "印がある回の衝突には、古い設定の書き戻しかもしれないと添える"
else
  ng "印がある回の衝突" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 27. --import は、repo 側に commit していない変更 (未追跡のファイルも) があると、何も書かずに exit 1。
#     git の checkout か確かめられないときも止まる。記録も変えない
h=$(new_home t27 "${state_on}" 1)
run "${h}" 0
rec="${h}/.local/state/dotfiles/google-japanese-input/deployed.json"
cp "${rec}" "${h}/rec.before"
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
printf 'Composition\tF14\tIMEOff\n' >>"${h}/repo/win/google-japanese-input/keymap.tsv"
cp "${h}/repo/win/google-japanese-input/keymap.tsv" "${h}/keymap.before"
run "${h}" 0 --import
if [[ $(rc "${h}") == 1 ]] && cmp -s "${h}/keymap.before" "${h}/repo/win/google-japanese-input/keymap.tsv" && cmp -s "${h}/rec.before" "${rec}" \
  && outerr "${h}" | grep -q 'google-japanese-input に commit していない変更があります' && outerr "${h}" | grep -q 'M keymap.tsv'; then
  ok "--import は repo に commit していない変更があると、何も書かずに exit 1 (変わったファイルを出す)"
else
  ng "--import と未コミットの変更" "rc=$(rc "${h}") $(outerr "${h}")"
fi
git -C "${h}/repo" checkout --quiet -- win/google-japanese-input/keymap.tsv
printf 'あ\t亜\t名詞\t\n' >"$(tsv_of "${h}" 新しい辞書)"
# 未追跡を見せない設定でも見えること (script は --untracked-files=normal で見る)
git -C "${h}/private" config status.showUntrackedFiles no
run "${h}" 0 --import
if [[ $(rc "${h}") == 1 && -f $(tsv_of "${h}" 新しい辞書) ]] && cmp -s "${h}/rec.before" "${rec}" \
  && grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" \
  && outerr "${h}" | grep -q 'dictionaries に commit していない変更があります'; then
  ok "--import は dotfiles-private に未追跡の TSV があると、未追跡を見せない設定でも何も書かずに exit 1"
else
  ng "--import と未追跡の TSV" "rc=$(rc "${h}") $(outerr "${h}")"
fi
rm -f "$(tsv_of "${h}" 新しい辞書)"
rm -rf "${h}/private/.git"
run "${h}" 0 --import
if [[ $(rc "${h}") == 1 && -f $(tsv_of "${h}" テスト辞書) ]] && cmp -s "${h}/rec.before" "${rec}" \
  && grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" && outerr "${h}" | grep -q '確かめられません'; then
  ok "--import は git の checkout か確かめられなければ、何も書かずに exit 1"
else
  ng "--import と checkout でない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 28. 辞書の衝突: 語は stdout にも stderr にも出さず、辞書ごとの行の数だけを出す。--show-words なら diff を出す
h=$(new_home t28 "${state_on}" 1)
w_secret=$'ひみつのよみ\t秘密の単語\t名詞\t\n'
w_one=$'いちのよみ\t一の単語\t名詞\t\n'
w_two=$'にのよみ\t二の単語\t名詞\t\n'
w_out=$'そとのよみ\t外の単語\t名詞\t\nそとのよみに\t外の単語に\t名詞\t\n'
w_in=$'うちのよみ\t内の単語\t名詞\t\n'
printf '%s' "${w_in}" >"$(tsv_of "${h}" 手元の辞書)"
printf '%s' "${w_one}${w_two}" >"$(tsv_of "${h}" 並びの辞書)"
put_windows "${h}" "${keymap}"
put_windows_dictionaries "${h}" "テスト辞書=${dict}${w_secret}" "並びの辞書=${w_two}${w_one}" "窓の辞書=${w_out}"
run "${h}" 0
leaked=""
for w in てすと ひみつのよみ 秘密の単語 いちのよみ 一の単語 にのよみ 二の単語 そとのよみ 外の単語 うちのよみ 内の単語; do
  if outerr "${h}" | grep -qF "${w}"; then
    leaked+=" ${w}"
  fi
done
if [[ $(rc "${h}") == 1 && -z ${leaked} ]] \
  && outerr "${h}" | grep -qF '辞書「テスト辞書」: Windows 側にだけある行 1・repo 側にだけある行 0' \
  && outerr "${h}" | grep -qF '辞書「並びの辞書」: 行は同じで、並びだけが違う' \
  && outerr "${h}" | grep -qF '辞書「手元の辞書」: repo 側にだけある (1 語)' \
  && outerr "${h}" | grep -qF '辞書「窓の辞書」: Windows 側にだけある (2 語)' \
  && outerr "${h}" | grep -qF -- '--dry-run --show-words'; then
  ok "辞書の衝突は語を出さず、辞書ごとの行の数と --show-words の案内だけを出す"
else
  ng "辞書の衝突の件数" "rc=$(rc "${h}") leaked=${leaked:-(なし)} $(outerr "${h}")"
fi
run "${h}" 0 --dry-run --show-words
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '^-ひみつのよみ' && ! killed "${h}"; then
  ok "--show-words を付けると、辞書の衝突でも語の diff を出す"
else
  ng "--show-words" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 29. 辞書の TSV に出ない項目だけが違う: 件数の行は無く、どの辞書も TSV は同じと出す
h=$(new_home t29 "${state_on}" 1)
if [[ -z ${PJP_GOOGLE_IME_DESCRIPTORS:-} ]]; then
  ng "TSV に出ない項目だけが違う" "PJP_GOOGLE_IME_DESCRIPTORS が無い (flake の check から流す)"
else
  put_windows "${h}" "${keymap}"
  put_windows_proto_dictionary "${h}" version
  run "${h}" 0
  if [[ $(rc "${h}") == 1 ]] && ! outerr "${h}" | grep -q '辞書「' \
    && outerr "${h}" | grep -qF 'どの辞書も TSV に出る中身は同じです (TSV に出ない項目だけが違う)'; then
    ok "辞書の TSV に出ない項目だけが違うときは、どの辞書も TSV は同じと出す"
  else
    ng "TSV に出ない項目だけが違う" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
fi

# 30. config.txtpb が無い: --check は確かめるテキストが無いので exit 1。普段の回は飛ばして exit 0
h=$(new_home t30 "" 0)
rm "${h}/repo/win/google-japanese-input/config.txtpb"
run "${h}" 1 --check
check_rc=$(rc "${h}")
check_log=$(outerr "${h}")
run "${h}" 1
if [[ ${check_rc} == 1 && $(rc "${h}") == 0 ]] && grep -q 'config.txtpb' <<<"${check_log}" && outerr "${h}" | grep -q '飛ばします'; then
  ok "--check は config.txtpb が無ければ exit 1 (普段の回は飛ばして exit 0)"
else
  ng "--check と config.txtpb が無い" "check_rc=${check_rc} rc=$(rc "${h}") ${check_log} $(outerr "${h}")"
fi

# 31〜32. Google 日本語入力は入っているが、まだ使っていない (置き先が無い): 一度使ってから流し直すよう出して exit 0。
#     Program Files は 64 ビットと x86 のどちらにあってもよい。windowsHome は本物と同じく <ドライブ>/Users/<名前> の形にする
for t in "t31:Program Files (x86)" "t32:Program Files"; do
  h=$(new_home "${t%%:*}" "" 0)
  mkdir -p "${h}/c/Users/u" "${h}/c/${t#*:}/Google/Google Japanese Input"
  printf 'exe' >"${h}/c/${t#*:}/Google/Google Japanese Input/GoogleIMEJaConverter.exe"
  printf '{"enable":true,"version":1,"windowsHome":"%s"}\n' "${h}/c/Users/u" >"${h}/.local/state/dotfiles/windows-files.json"
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e ${h}/tasklist-calls && ! -e "${h}/c/Users/u/AppData/LocalLow/Google/Google Japanese Input" ]] \
    && outerr "${h}" | grep -q 'まだ使われていません' && outerr "${h}" | grep -q '一度何か打ってから' \
    && ! outerr "${h}" | grep -q '入っていません'; then
    ok "入っているがまだ使っていなければ (${t#*:})、一度使ってから流し直すよう出して exit 0 (置き先は作らない)"
  else
    ng "入っているが使っていない (${t#*:})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 33. --import は、同じディレクトリの Install-GoogleJapaneseInput.ps1 に commit していない変更 (版を上げる途中) があっても止まらない
h=$(new_home t33 "${state_on}" 1)
printf '# Install-GoogleJapaneseInput.ps1\n' >"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
git -C "${h}/repo" add -A
git -C "${h}/repo" commit --quiet -m 'Install-GoogleJapaneseInput.ps1 を足した'
run "${h}" 0
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
printf "    [string]\$Version = '3.35.0.0',\n" >>"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
run "${h}" 0 --import
if [[ $(rc "${h}") == 0 ]] && ! grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" \
  && grep -qF '3.35.0.0' "${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1" \
  && outerr "${h}" | grep -q '取り込みました'; then
  ok "--import は Install-GoogleJapaneseInput.ps1 に commit していない変更があっても止まらず、テキストだけを取り込む"
else
  ng "--import と Install-GoogleJapaneseInput.ps1" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 34. --import は config.txtpb・romaji.tsv の commit していない変更でも止まる (keymap.tsv は 27 が見ている)
h=$(new_home x1 "${state_on}" 1)
printf 'a\tb\n' >"${h}/repo/win/google-japanese-input/romaji.tsv"
git -C "${h}/repo" add -A
git -C "${h}/repo" commit --quiet -m 'romaji.tsv を足した'
run "${h}" 0
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
x1_ok=1
for mut in txtpb romaji_modified romaji_deleted romaji_untracked_showno keymap_staged; do
  git -C "${h}/repo" reset --quiet --hard
  git -C "${h}/repo" clean --quiet -fd
  git -C "${h}/repo" config --unset status.showUntrackedFiles 2>/dev/null || true
  case ${mut} in
    txtpb) printf 'punctuation_method: KUTEN_TOUTEN\n' >>"${h}/repo/win/google-japanese-input/config.txtpb" ;;
    romaji_modified) printf 'c\td\n' >>"${h}/repo/win/google-japanese-input/romaji.tsv" ;;
    romaji_deleted) rm "${h}/repo/win/google-japanese-input/romaji.tsv" ;;
    romaji_untracked_showno)
      git -C "${h}/repo" rm --quiet --cached win/google-japanese-input/romaji.tsv
      git -C "${h}/repo" commit --quiet -m 'romaji.tsv を外した'
      git -C "${h}/repo" config status.showUntrackedFiles no
      printf 'e\tf\n' >"${h}/repo/win/google-japanese-input/romaji.tsv"
      ;;
    keymap_staged)
      printf 'Composition\tF14\tIMEOff\n' >>"${h}/repo/win/google-japanese-input/keymap.tsv"
      git -C "${h}/repo" add win/google-japanese-input/keymap.tsv
      ;;
  esac
  run "${h}" 0 --import
  if [[ $(rc "${h}") != 1 ]] || ! outerr "${h}" | grep -q 'google-japanese-input に commit していない変更があります'; then
    x1_ok=0
    echo "       x1 ${mut}: rc=$(rc "${h}") $(outerr "${h}")"
  fi
done
if ((x1_ok)); then
  ok "--import は config.txtpb・romaji.tsv (変更・削除・未追跡)・staged の keymap.tsv でも止まる"
else
  ng "--import と 3 つのテキスト"
fi

# 35. --short の一覧は、止める理由のファイルだけ (Install-GoogleJapaneseInput.ps1 の変更は出さない)
h=$(new_home x2 "${state_on}" 1)
printf '# Install-GoogleJapaneseInput.ps1\n' >"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
git -C "${h}/repo" add -A
git -C "${h}/repo" commit --quiet -m 'ps1'
printf 'more\n' >>"${h}/repo/win/google-japanese-input/Install-GoogleJapaneseInput.ps1"
printf 'Composition\tF14\tIMEOff\n' >>"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0 --import
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'M keymap.tsv' && ! outerr "${h}" | grep -q 'Install-GoogleJapaneseInput'; then
  ok "止めたときの一覧は keymap.tsv だけで、Install-GoogleJapaneseInput.ps1 は出ない"
else
  ng "--short の一覧" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 36. 案内は stderr に出る (stdout は空)
h=$(new_home x3 "" 0)
mkdir -p "${h}/c/Users/u" "${h}/c/Program Files/Google/Google Japanese Input"
printf 'exe' >"${h}/c/Program Files/Google/Google Japanese Input/GoogleIMEJaConverter.exe"
printf '{"enable":true,"version":1,"windowsHome":"%s"}\n' "${h}/c/Users/u" >"${h}/.local/state/dotfiles/windows-files.json"
run "${h}" 0
if [[ $(rc "${h}") == 0 && ! -s ${h}/out ]] && grep -q 'まだ使われていません' "${h}/err"; then
  ok "「まだ使われていません」は stderr に出て、stdout は空"
else
  ng "案内の出し先" "rc=$(rc "${h}") out=$(cat "${h}/out") err=$(cat "${h}/err")"
fi

# 37. Program Files に Google/Google Japanese Input のディレクトリだけがあって exe が無い (アンインストールの残り): 入っていない扱い
h=$(new_home x4 "" 0)
mkdir -p "${h}/c/Users/u" "${h}/c/Program Files/Google/Google Japanese Input" "${h}/c/Program Files (x86)/Google/Google Japanese Input"
printf '{"enable":true,"version":1,"windowsHome":"%s"}\n' "${h}/c/Users/u" >"${h}/.local/state/dotfiles/windows-files.json"
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '入っていません' && ! outerr "${h}" | grep -q 'まだ使われていません'; then
  ok "本物と同じ並び (<ドライブ>/Users/<名前>) で exe が無ければ、入っていない扱い"
else
  ng "exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
