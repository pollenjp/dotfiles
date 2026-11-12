#!/usr/bin/env bash
# shellcheck shell=bash
#
# PowerToys の FancyZones へ、win/powertoys/fancyzones/ の持つキー (settings.json)・カスタムレイアウト (uuid ごとに足す)・ディスプレイへのあて方 (解像度で決める) を書く (冪等。更新時も毎回走る)。
#
# order: 92
#
# ^ setup.sh が読む実行順。bootstrap-windows-powertoys.sh (order: 91) が PowerToys を入れた後に走らせる。91 は
#   Keyboard Manager が使えないと早く抜けるので、FancyZones がその影響を受けないよう別の script にしてある。
#   仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# FancyZones の設定のうち、dotfiles で持ちたいもの (「Windows スナップのオーバーライド」のキーと、エディターの「カスタム」に
# 登録したレイアウトと、どのディスプレイにどのレイアウトをあてるかの決まり) を全マシンで揃える (dotfiles-private の
# docs/adr/042_*・046_*・053_*)。
#
# - settings.json は PowerToys が全部のキーを書き、設定画面でも書き換えるので、ファイルごとは配らない。managed.json に
#   持つキーだけを書き、そのキーだけをここで書く。Windows Terminal (bootstrap-windows-terminal.sh) と違い、衝突にしない。
#   値が違えば、手で変えていても dotfiles の値へ戻し、戻したことを 1 行出す。PowerToys は全部のキーを書くので、
#   Terminal の判定のままだと初回に既定の false と衝突するため。記録・--import・退避は持たない。managed.json から消した
#   キーは settings.json からは消さない (最後の値が残り、以後は戻さない)
# - custom-layouts.json は、PC のエディターで作ったレイアウトも入る (PC ごとに違う)。ファイルごと配ると、PC でレイアウトを
#   1 つ作るだけで衝突して setup が止まるので、repo のレイアウトを uuid で突き合わせ、レイアウトごとに足す。PC にだけある
#   レイアウトには触らない
# - applied-layouts.json (モニター × 仮想デスクトップの組ごとに、どのレイアウトをあてるか) は、モニターのシリアルが入り PC ごとに
#   違うので持たない。代わりに、解像度からあてるレイアウトを決める決まり (layout-rules.json) を持ち、テンプレートのままの組を
#   決まりのレイアウトで埋める。あて忘れた組を、エディターを開いてディスプレイの数だけあてて回らずに済ませるため。
#   解像度を確かに知る手段がほかに無いので、この段だけ powershell.exe を呼ぶ (ADR 042・046 は exe を呼ばない作りだった)。
#   呼ぶのは候補の組があるときだけ
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす
# 2. <windowsHome>/AppData/Local/Microsoft/PowerToys/FancyZones/settings.json の、持つキーの値を比べる
#    - 同じなら何もしない (書かない。LastWriteTime も変えない)
#    - 違えば、jq でそのキーだけを書き換える。ほかのキーの値・キーの順・1 行で末尾に改行なしの形は変えない
#    - ファイルが無ければ、持つキーと name・version だけで作る。FancyZones は name が無いとエラーのダイアログを出し、
#      無いキーは今の値のまま読むので、この 3 つで足りる (設定画面は、無いキーを既定値で読む)
#    - 読めない (JSON の object でない) ときは、書かずに警告する。設定画面が書いている途中に当たっても読めるよう、5 回まで読む。
#      書いている途中の空のファイルを読んでも、空で置き換えない・揃っていると言わない
# 3. 同じディレクトリの custom-layouts.json に、win/powertoys/fancyzones/custom-layouts.json のレイアウトを uuid ごとに足す。
#    前に足した中身は ~/.local/state/dotfiles/windows-fancyzones.applied.json に uuid ごとに持つ
#    ({"version":1,"layouts":{"<uuid>":<レイアウト>}})。中身は jq で読んだ値で比べる (キーの順・字下げ・改行・エスケープに
#    左右されない。配列の順は比べる)。レイアウトごとに:
#
#      PC に無く、記録も無い                     末尾に足す
#      PC が repo と同じ                         何もしない (記録が無ければ記録だけする)
#      PC が記録と同じ (前に足したまま)          repo が更新された。同じ位置で書き換える
#      PC が repo とも記録とも違う・記録が無い   PC のエディターで直した (足す前からあった)。書き換えずに警告する
#      PC に無いが、記録がある                   PC で消した (エディターを開いたまま流して閉じても消える)。足し直さずに警告する
#
#    - --force は、警告する 2 つも repo の中身にする (書き換える・足し直す)。--import <名前> は逆に、PC のレイアウトを名前で
#      選んで repo のファイルへ写す (commit は人がする。PC のファイルと記録には書かない)
#    - PC にファイルが無ければ、記録によらず repo のレイアウトだけで作る (エディターはファイルを消さないので、PowerToys の
#      設定を消したときで、PC で消したのではない)
#    - repo から消したレイアウトは PC から消さず、記録からだけ消す (manifest から外したファイルと同じ扱い)
#    - 書く形は PowerToys の形 (字下げ 2・CRLF・末尾に改行なし。エディターが書くバイト列と同じ形)。書き換える前のファイルを
#      ~/.local/state/dotfiles/windows-fancyzones/backup/<UTC の時刻>-<pid>/ へ写す (新しい方から 10 回分を残す)
#    - PC のファイルを読めない (5 回読む)・記録が壊れている・repo のファイルに誤りがあるときは、書かずに警告する
# 4. 同じディレクトリの applied-layouts.json の組 (モニター × 仮想デスクトップ) へ、win/powertoys/fancyzones/layout-rules.json の
#    決まり (今の表示の解像度がちょうど一致した rules の layout、どれにも当たらなければ default。今は 3840x2160 が 4k-43inch、
#    それ以外が 1080p) のレイアウトをあてる。3 の後に置くのは、あてるレイアウトが PC の custom-layouts.json に入っている必要があるから
#    - ファイルが無い・組が無ければ何もしない (FancyZones がまだディスプレイを開いていない)。組は新しく作らない (まだ開いていない
#      仮想デスクトップは、FancyZones が開いたときに前のデスクトップから写す)
#    - 候補 (テンプレートのままの組と、前にこの段があてたままの組。--force なら全部の組) が無ければ、powershell.exe を呼ばずに終わる
#    - powershell.exe で、つながっているディスプレイの DeviceID と今の表示の解像度を、FancyZones と同じ手順で聞く
#      (MonitorUtils.cpp。下の ps_body)。組の monitor が同じで、monitor-instance が同じか、違えば monitor-number が同じディスプレイに
#      合わせる (instance で合う方を先に)。シリアルは見ない・読まない。FancyZones は同じ型のモニターに同じシリアルを入れるので
#      見分けに使えず、シリアルだけが違う古い組も同じレイアウトにしておけば、列挙の順が変わっても揃っている
#    - 組ごとに (目標 = そのディスプレイの解像度から決まりで決めたレイアウト):
#
#        合うディスプレイが無い (つながっていない)・縦向き (高さ > 幅)   触らない (--force でも)
#        目標と同じカスタムレイアウト                                 何もしない (記録が無ければ記録だけする)
#        テンプレートのまま (blank を除く。エディターで選んだものも)    目標にする
#        前にこの段があてたまま (記録と同じ) で、目標が変わった         目標にする (決まりや解像度を変えたとき)
#        手であてたカスタムレイアウト・blank・知らない type             残し、まとめて 1 行知らせる (--force なら目標にする)
#        目標のレイアウトが PC の custom-layouts.json に無い (か canvas でない)  飛ばして警告する
#
#    - あてた中身は ~/.local/state/dotfiles/windows-fancyzones.assigned.json に組ごとに持つ
#      ({"version":1,"assignments":{"<monitor>|<monitor-instance>|<monitor-number>|<virtual-desktop>":"<uuid>"}}。シリアルを入れない
#      ので、シリアルだけが違う組は 1 つのキーにまとまる)。この段が組を目標にしたときと、目標と同じ組で記録が無いときに書き、
#      applied-layouts.json から消えた組のキーは落とす。手であてた組 (記録と違う) と、前にこの段が埋めた組を見分けるため
#    - 書く値は、エディターが canvas のカスタムレイアウトをあてたときと同じ (type custom・show-spacing false・spacing 0・zone-count は
#      PC の custom-layouts.json のそのレイアウトのゾーンの数・sensitivity-radius はその info の値、無ければ 20)。device と組の並びは
#      変えない。書く形 (PowerToys の形)・退避 (3 と同じ場所) も 3 と同じ。& をエスケープするかは合わせない (JSON として同じ)
#    - 変えた組は 1 組 1 行 (モニター ID・解像度・仮想デスクトップ・前 → 後) で出す。シリアルは出さない。手であてた組を残した 1 行は、
#      警告のまとめには載せない (会社の PC で毎回出るため)
#    - --dry-run でも powershell.exe は呼ぶ (書かない)。--import では走らせない
#    - applied-layouts.json を読めない (5 回読む)・記録が壊れている・決まりのファイルに誤りがある・powershell.exe が無い・失敗する・
#      60 秒たっても終わらない・決めた形の JSON を返さないときは、書かずに警告する
# 5. 2〜4 は、隣に書いて mv した後に touch する。FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは気づかない
#    (src/common/SettingsAPI/FileWatcher.cpp。実機で確かめた)。読みかけを見せないよう、その場には書かない。
#    PowerToys は起動し直さない
# 6. 全体の設定 <windowsHome>/AppData/Local/Microsoft/PowerToys/settings.json の enabled.FancyZones が false なら、
#    設定が効かないので警告する。自動でオンにはしない。キーやファイルが無ければオンとして扱う (FancyZones は既定でオン)。
#    読めないときは、確かめられないと警告する
#
# どの場合も exit 0 (後ろの手順を止めない)。引数の誤りだけ exit 2。--check と --import は誤りがあれば exit 1。
# 知らせたことは、setup の最後の「警告のまとめ」にも残す (warn / summary_warn)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
PowerToys の FancyZones へ、win/powertoys/fancyzones/ の持つキー (settings.json) とカスタムレイアウトを書き、
ディスプレイへのレイアウトのあて方を解像度で決める。
持つキーは、設定画面で変えていても dotfiles の値へ戻す。カスタムレイアウトは uuid ごとに足し、PC にだけあるものには触らない。
PC のエディターで直したレイアウトは書き換えずに知らせる。テンプレートのままのディスプレイの組 (モニター × 仮想デスクトップ) には、
解像度の決まり (layout-rules.json。今は 4K に 4k-43inch、それ以外に 1080p) のレイアウトをあてる。手であてたものは残す。
FancyZones はその場で読み直す (PowerToys は起動し直さない)。

使い方:
  bootstrap-windows-fancyzones.sh                   値が違えば書き、無いレイアウトを足し、テンプレートのままの組にレイアウトをあてる
  bootstrap-windows-fancyzones.sh --dry-run         判定だけ出して何も書かない (解像度は powershell.exe で聞く)
  bootstrap-windows-fancyzones.sh --force           PC で直した・消したレイアウトも repo の中身にし、手であてたカスタムレイアウト・
                                                    blank の組も決まりのレイアウトにする (退避する。先に --dry-run --force で見られる)
  bootstrap-windows-fancyzones.sh --import <名前>   PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す
                                                    (繰り返せる。commit は自分で。ディスプレイへのあて方は変えない)
  bootstrap-windows-fancyzones.sh --check           win/powertoys/fancyzones/ の検証だけ (state も PC のファイルも見ない)
EOS
}

dry_run=0
check=0
force=0
import_mode=0
import_names=()
while (($# > 0)); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --check) check=1 ;;
    --force) force=1 ;;
    --import | --import=*)
      if [[ $1 == --import=* ]]; then
        import_name=${1#--import=}
      elif (($# >= 2)); then
        import_name=$2
        shift
      else
        import_name=""
      fi
      if [[ -z ${import_name} ]]; then
        echo "--import には、取り込むレイアウトの名前 (PC のエディターに出る名前) を付けてください。" >&2
        usage >&2
        exit 2
      fi
      import_mode=1
      import_names+=("${import_name}")
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
if ((check && (dry_run || force || import_mode))); then
  echo "--check はほかの引数と一緒に使えません。" >&2
  exit 2
fi
if ((import_mode && (dry_run || force))); then
  echo "--import は --force・--dry-run と一緒に使えません。" >&2
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
managed_rel="win/powertoys/fancyzones/managed.json"
managed_file="${repo_dir}/${managed_rel}"
layouts_rel="win/powertoys/fancyzones/custom-layouts.json"
layouts_file="${repo_dir}/${layouts_rel}"
rules_rel="win/powertoys/fancyzones/layout-rules.json"
rules_file="${repo_dir}/${rules_rel}"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-fancyzones.applied.json"
assigned_file="${state_dir}/windows-fancyzones.assigned.json"
backup_root="${state_dir}/windows-fancyzones/backup"
keep_backups=10
# --dry-run で、カスタムレイアウトの段 (上の 3) が PC の custom-layouts.json に足す・書き換えるレイアウトの uuid。
# あて方の段 (上の 4) は、これらを PC にあるものとして見る
pending_layouts='[]'

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

# --check と --import の誤りを出す (setup の警告のまとめには残さない。引数は warn と同じ)
fail() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
}

# jq で使う関数 (settings.json)。
#   leaf_paths   持つキーのパスを並べる (object を辿った先の、object でない値 1 つが持つキー 1 つ)
#   apply($m)    $m の持つキーだけを書き込む
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
jq_lib='
def leaf_paths:
  if type == "object" then to_entries[] | [.key] + (.value | leaf_paths) else [] end;
def apply($m):
  reduce ($m | leaf_paths) as $p (.; setpath($p; $m | getpath($p)));
'

# jq で使う関数 (custom-layouts.json)。
#   layouts            custom-layouts の配列 (無い・object でなければ空)
#   uuid_index($u)     配列の中で uuid が $u のレイアウトの位置 (無ければ null)
#   layout_problems    repo に置くファイルの誤りを 1 行ずつ出す。uuid は PowerToys の書く形 (大文字の {…}) で、突き合わせは
#                      文字列の一致なので形を揃える。name は --import で引くので重ねない
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
layouts_lib='
def layouts:
  if type == "object" and (.["custom-layouts"] | type) == "array" then .["custom-layouts"] else [] end;
def uuid_index($u):
  first(range(0; length) as $i | select((.[$i] | type) == "object" and .[$i].uuid == $u) | $i) // null;
def name_note:
  if (.name | type) == "string" then "「\(.name)」" else "" end;
def layout_problems:
  if type != "object" then
    "JSON の object ではありません。"
  elif (.["custom-layouts"] | type) != "array" then
    "custom-layouts の配列がありません。"
  else
    (.["custom-layouts"] | to_entries[] | (.key + 1) as $n | .value
      | if type != "object" then
          "\($n) 番目が object ではありません。"
        else
          (if (.uuid | type) == "string" and (.uuid | test("^\\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\}$"))
           then empty
           else "\($n) 番目\(name_note) の uuid が、大文字の {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} の形ではありません: \(.uuid | tojson)" end),
          (if (.name | type) == "string" and .name != "" then empty else "\($n) 番目の name が空か、文字列ではありません。" end),
          (if (.type | type) == "string" then empty else "\($n) 番目\(name_note) に type (文字列) がありません。" end),
          (if (.info | type) == "object" then empty else "\($n) 番目\(name_note) に info (object) がありません。" end)
        end),
    ([.["custom-layouts"][] | objects | .uuid | strings] | group_by(.)[] | select(length > 1) | "uuid が重なっています: \(.[0])"),
    ([.["custom-layouts"][] | objects | .name | strings] | group_by(.)[] | select(length > 1) | "name が重なっています: \(.[0])")
  end;
'

# jq で使う関数 (layout-rules.json)。layouts_lib と一緒に使う。
#   rules_problems($layouts)  決まりのファイルの誤りを 1 行ずつ出す。$layouts は repo の custom-layouts の配列。名前は repo の
#                             レイアウトを指し、canvas のものだけを受ける (あてる値をエディターで確かめたのが canvas だけのため)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
rules_lib='
def rule_name_problem($what; $layouts):
  if type != "string" or . == "" then
    "\($what) が空か、文字列ではありません。"
  else
    . as $n
    | [$layouts[] | objects | select(.name == $n)] as $m
    | if ($m | length) == 0 then "\($what) の「\($n)」というレイアウトが custom-layouts.json にありません。"
      elif $m[0].type != "canvas" then "\($what) の「\($n)」は canvas のレイアウトではありません (あてる値を確かめた canvas のレイアウトだけを指せます)。"
      else empty end
  end;
def rules_problems($layouts):
  if type != "object" then
    "JSON の object ではありません。"
  else
    ((keys - ["rules", "default"]) | select(length > 0) | "rules・default のほかにキーがあります: \(join(", "))"),
    (if (.rules | type) != "array" then
      "rules の配列がありません。"
    else
      (.rules | to_entries[] | (.key + 1) as $n | .value
        | if type != "object" then
            "rules の \($n) 番目が object ではありません。"
          else
            ((keys - ["resolution", "layout"]) | select(length > 0) | "rules の \($n) 番目に resolution・layout のほかのキーがあります: \(join(", "))"),
            (if (.resolution | type) == "string" and (.resolution | test("^[1-9][0-9]*x[1-9][0-9]*$")) then empty
             else "rules の \($n) 番目の resolution が「幅x高さ」(3840x2160 など) の形ではありません: \(.resolution | tojson)" end),
            (.layout | rule_name_problem("rules の \($n) 番目の layout"; $layouts))
          end),
      ([.rules[] | objects | .resolution | strings] | group_by(.)[] | select(length > 1) | "resolution が重なっています: \(.[0])")
    end),
    (.default | rule_name_problem("default"; $layouts))
  end;
'

# managed.json の誤りを 1 行ずつ出す。誤りが無ければ何も出さない
managed_problems() {
  if [[ ! -s ${managed_file} ]]; then
    echo "ファイルが無いか、空です (${managed_file})。"
    return 0
  fi
  jq -r "${jq_lib}"'
    if type != "object" then
      "JSON の object ではありません。"
    else
      ((keys - ["properties"]) | select(length > 0) | "properties のほかにキーがあります: \(join(", "))"),
      (if (.properties | type) != "object" or (.properties | length) == 0 then
        "properties に持つキーがありません。"
      else
        .properties | to_entries[]
        | select((.value | type) != "object" or (.value | keys) != ["value"] or ([.value | .. | select(. == null or . == {})] | length) > 0)
        | "properties.\(.key) の形が {\"value\": 値} ではありません。"
      end)
    end' "${managed_file}" 2>&1 || true
}

# repo の custom-layouts.json の誤りを 1 行ずつ出す。誤りが無ければ何も出さない
layouts_problems() {
  if [[ ! -s ${layouts_file} ]]; then
    echo "ファイルが無いか、空です (${layouts_file})。"
    return 0
  fi
  jq -r "${layouts_lib}"'layout_problems' "${layouts_file}" 2>&1 || true
}

# repo の layout-rules.json の誤りを 1 行ずつ出す。誤りが無ければ何も出さない。名前を引くので、custom-layouts.json に誤りが
# 無いときに呼ぶ
rules_problems() {
  if [[ ! -s ${rules_file} ]]; then
    echo "ファイルが無いか、空です (${rules_file})。"
    return 0
  fi
  jq -r --slurpfile repo "${layouts_file}" "${layouts_lib}${rules_lib}"'rules_problems($repo[0] | layouts)' "${rules_file}" 2>&1 || true
}

# 標準入力の JSON を、PowerToys の書く形 (字下げ 2・CRLF・末尾に改行なし) で出す。読めない・空なら失敗する
to_pt_form() {
  local body
  body=$(jq --indent 2 .) || return 1
  [[ -n ${body} ]] || return 1
  printf '%s' "${body//$'\n'/$'\r\n'}"
}

# ファイルが PowerToys の書く形か
pt_form_ok() {
  local want have
  want=$(to_pt_form <"$1" 2>/dev/null) || return 1
  have=$(
    cat -- "$1"
    printf x
  )
  [[ ${have%x} == "${want}" ]]
}

if ! command -v jq &>/dev/null; then
  if ((check || import_mode)); then
    echo "!! jq が見つかりません。" >&2
    exit 1
  fi
  warn "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if ((check)); then
  failed=0
  problems=$(managed_problems)
  if [[ -n ${problems} ]]; then
    fail "${managed_rel} に誤りがあります:" "${problems}"
    failed=1
  fi
  layout_errors=$(layouts_problems)
  if [[ -n ${layout_errors} ]]; then
    fail "${layouts_rel} に誤りがあります:" "${layout_errors}"
    failed=1
  elif ! pt_form_ok "${layouts_file}"; then
    # --import は PowerToys の書く形で書き直すので、置いてあるファイルも揃えておく (取り込みの差分を中身の変更だけにする)
    fail "${layouts_rel} が、PowerToys の書く形と違います (字下げ 2・CRLF・末尾に改行なし)。--import が書き直したときの差分を、中身の変更だけにするためです。" \
      "エディターの書いたファイルを --import で取り込むか、次で整えてください:" \
      "f=${layouts_rel}; b=\$(jq --indent 2 . \"\$f\") && printf '%s' \"\${b//\$'\\n'/\$'\\r\\n'}\" >\"\$f\""
    failed=1
  fi
  # 決まりはレイアウトの名前で引くので、custom-layouts.json の中身に誤りが無いときだけ確かめる
  if [[ -n ${layout_errors} ]]; then
    fail "${rules_rel} は、${layouts_rel} を直してから確かめます (決まりはレイアウトの名前で引くため)。"
  else
    problems=$(rules_problems)
    if [[ -n ${problems} ]]; then
      fail "${rules_rel} に誤りがあります:" "${problems}"
      failed=1
    fi
  fi
  if ((failed)); then
    exit 1
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  m=$(jq '.["custom-layouts"] | length' "${layouts_file}")
  r=$(jq '.rules | length' "${rules_file}")
  default_layout=$(jq -r '.default' "${rules_file}")
  echo "win/powertoys/fancyzones/: OK (持つキー ${n} 件・カスタムレイアウト ${m} 件・解像度の決まり ${r} 件と既定「${default_layout}」)"
  exit 0
fi

# 配らないマシン・配り先が見えないときは、setup では飛ばす。--import は取り込めないので exit 1
if [[ ! -r ${state_file} ]]; then
  if ((import_mode)); then
    fail "配り先の設定がありません (${state_file})。PC のレイアウトを読めないので、取り込めません。"
    exit 1
  fi
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}" 2>/dev/null) != true ]]; then
  if ((import_mode)); then
    fail "このマシンは Windows 側へ配らないので (dotfiles.wsl.windowsFiles.enable = false)、取り込めません。"
    exit 1
  fi
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}" 2>/dev/null) || windows_home=""
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  if ((import_mode)); then
    fail "Windows 側のホームが見えないので、取り込めません: ${windows_home:-(windowsHome が空)}" \
      "/mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。"
    exit 1
  fi
  warn "Windows 側のホームが見えないので、FancyZones の設定とカスタムレイアウトを書きません: ${windows_home:-(windowsHome が空)}" \
    "/mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。"
  exit 0
fi

fz_dir="${windows_home}/AppData/Local/Microsoft/PowerToys/FancyZones"
settings_json="${fz_dir}/settings.json"
pc_layouts="${fz_dir}/custom-layouts.json"
pc_applied="${fz_dir}/applied-layouts.json"
pc_defaults="${fz_dir}/default-layouts.json"
global_json="${windows_home}/AppData/Local/Microsoft/PowerToys/settings.json"

# 一時ファイルの置き場 (PC のファイルの写し・計画・記録)。終わったら消す。作れなければ失敗する
work_dir=""
trap '[[ -z ${work_dir} ]] || rm -rf -- "${work_dir}"' EXIT
make_work_dir() {
  if [[ -z ${work_dir} ]]; then
    work_dir=$(mktemp -d 2>/dev/null) || work_dir=""
  fi
  [[ -n ${work_dir} ]]
}

# ---- settings.json の持つキー ----

# JSON の object か。設定画面が書いている途中に当たっても読めるよう、5 回まで読む
readable_object() {
  local i
  for ((i = 0; i < 5; i++)); do
    if jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

unreadable() {
  warn "FancyZones の settings.json を読めないので、書きません: ${settings_json}" \
    "中身を確かめて直すか、ファイルを消してから流し直してください (無ければ、持つキーだけで作ります)。"
}

# 書く中身を出す。ファイルが無ければ、持つキーと name・version だけで作る。キーの順と 1 行で末尾に改行なしの形は変えない
# (PowerToys が書く形)。-e は、書いている途中の空のファイルを読んで何も出さなかったときに失敗にするため
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
render_settings() {
  if [[ -e ${settings_json} ]]; then
    jq -ecj --slurpfile m "${managed_file}" "${jq_lib}"'apply($m[0])' "${settings_json}"
  else
    jq -ncj --slurpfile m "${managed_file}" "${jq_lib}"'{properties: {}, name: "FancyZones", version: "1.0"} | apply($m[0])'
  fi
}

# 隣に書いてから置き換える (読みかけを見せない)
write_settings() {
  local tmp="${settings_json}.dotfiles-tmp"
  if render_settings 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${settings_json}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 動いている FancyZones に読み直させる。LastWriteTime の変更しか見ていないので、mv の後に touch する
reload_fancyzones() {
  touch -- "${settings_json}" 2>/dev/null \
    || warn "FancyZones の settings.json に書きましたが、FancyZones に読み直させられませんでした: ${settings_json}" \
      "PowerToys を起動し直すと読みます。"
}

create_settings() {
  if ((dry_run)); then
    echo "[dry-run] FancyZones の settings.json が無いので、持つキーだけで作ります (持つキー ${n} 件): ${settings_json}"
    return 0
  fi
  if ! mkdir -p -- "${fz_dir}" 2>/dev/null || ! write_settings; then
    warn "FancyZones の settings.json を作れませんでした: ${settings_json}" \
      "Windows 側のディレクトリを確かめてから、流し直してください。"
    return 0
  fi
  reload_fancyzones
  echo "FancyZones の settings.json が無いので、持つキーだけで作りました (持つキー ${n} 件): ${settings_json}"
}

update_settings() {
  local changes line
  if ! readable_object "${settings_json}"; then
    unreadable
    return 0
  fi
  # 値が違うキーを 1 行ずつ出す。途中が object でなくても落ちない (書くときに落ちて、書けないと知らせる)。
  # input は、書いている途中の空のファイルでエラーになる (差が無いことにしない)
  # shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
  if ! changes=$(jq -rn --slurpfile m "${managed_file}" "${jq_lib}"'
    input as $s | $m[0] | leaf_paths as $p
    | ($m[0] | getpath($p)) as $want
    | ($s | try getpath($p) catch null) as $cur
    | select($cur != $want)
    | "\($p | join(".")) \(if $cur == null then "(無い)" else ($cur | tojson) end) → \($want | tojson)"
    ' "${settings_json}" 2>/dev/null); then
    unreadable
    return 0
  fi
  if [[ -z ${changes} ]]; then
    echo "FancyZones の設定は揃っています (持つキー ${n} 件)。"
    return 0
  fi
  if ((dry_run)); then
    if render_settings &>/dev/null; then
      while IFS= read -r line; do
        echo "[dry-run] FancyZones の設定を dotfiles の値へ戻します: ${line}"
      done <<<"${changes}"
    else
      echo "[dry-run] FancyZones の settings.json に書けません: ${settings_json}"
      printf '%s\n' "${changes}"
    fi
    return 0
  fi
  if ! write_settings; then
    warn "FancyZones の settings.json に書けないので、dotfiles の値にできませんでした: ${settings_json}" "${changes}"
    return 0
  fi
  reload_fancyzones
  while IFS= read -r line; do
    echo "FancyZones の設定を dotfiles の値へ戻しました: ${line}"
  done <<<"${changes}"
}

sync_settings() {
  local problems
  problems=$(managed_problems)
  if [[ -n ${problems} ]]; then
    warn "${managed_rel} に誤りがあるので、FancyZones の設定を書きません:" "${problems}"
    return 0
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  if [[ -e ${settings_json} ]]; then
    update_settings
  else
    create_settings
  fi
}

# ---- カスタムレイアウト (custom-layouts.json) ----

# PC の custom-layouts.json を作業場所へ写す (読みかけを見せないよう、写しで比べて写しから書く)。custom-layouts が配列の
# JSON の object (custom-layouts が無いのはよい) になるまで、5 回まで写す。エディターが書いている途中に当たっても読めるように
snapshot_pc_layouts() {
  local i
  for ((i = 0; i < 5; i++)); do
    if cp -- "${pc_layouts}" "${work_dir}/pc.json" 2>/dev/null \
      && jq -e 'type == "object" and ((has("custom-layouts") | not) or (.["custom-layouts"] | type) == "array")' \
        "${work_dir}/pc.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# カスタムレイアウトの段の後の PC の custom-layouts.json を作業場所へ写す (横向きの既定の段とあて方の段で、1 回だけ読む。読みかけに
# 当たって 5 回読むのも 1 回だけにする)。無ければ空。読めなければ失敗する
pc_layouts_state=""
read_pc_layouts() {
  if [[ -z ${pc_layouts_state} ]]; then
    if [[ ! -e ${pc_layouts} ]]; then
      printf '%s\n' '{}' >"${work_dir}/pc.json"
      pc_layouts_state=ok
    elif snapshot_pc_layouts; then
      pc_layouts_state=ok
    else
      pc_layouts_state=bad
    fi
  fi
  [[ ${pc_layouts_state} == ok ]]
}

# 記録を作業場所へ写す。無ければ空の記録。壊れていれば失敗する
load_record() {
  if [[ ! -e ${record_file} ]]; then
    printf '%s\n' '{"version":1,"layouts":{}}' >"${work_dir}/rec.json"
    return 0
  fi
  jq -e 'type == "object" and (.layouts | type) == "object"' "${record_file}" >/dev/null 2>&1 || return 1
  cp -- "${record_file}" "${work_dir}/rec.json"
}

# 記録を書く (変わったときだけ。--dry-run では書かない)。repo から消したレイアウトは記録から消し、揃っているものと、
# 書けたときは書いたものを、repo の中身で記録する。$1: 書けたか (true / false)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
save_record() {
  local new old
  if ((dry_run)); then
    return 0
  fi
  new=$(jq -S -n --slurpfile repo "${layouts_file}" --slurpfile rec "${work_dir}/rec.json" --slurpfile plan "${work_dir}/plan.json" \
    --argjson wrote "$1" '
    [$repo[0]["custom-layouts"][].uuid] as $ids
    | ($rec[0].layouts | with_entries(select(.key as $k | any($ids[]; . == $k))))
    | reduce ($plan[0].entries[] | select(.action == "same" or ($wrote and .write))) as $x (.; .[$x.uuid] = $x.want)
    | {version: 1, layouts: .}')
  # 記録が無いのは、空の記録と同じ (足したものが無ければ作らない)
  if [[ -f ${record_file} ]]; then
    old=$(jq -S . "${record_file}" 2>/dev/null) || old=""
  else
    old=$(jq -S -n '{version: 1, layouts: {}}')
  fi
  if [[ ${new} == "${old}" ]]; then
    return 0
  fi
  if ! { mkdir -p -- "${state_dir}" && printf '%s\n' "${new}" >"${record_file}.dotfiles-tmp" && mv -f -- "${record_file}.dotfiles-tmp" "${record_file}"; } 2>/dev/null; then
    rm -f -- "${record_file}.dotfiles-tmp" 2>/dev/null || true
    warn "FancyZones のカスタムレイアウトの記録を書けませんでした: ${record_file}" \
      "次の回は、前に足したレイアウトを見分けられないことがあります (PC で直したものとして知らせます)。"
  fi
}

# 書き換える前の PC のファイル ($1) を退避する。1 回の実行で書き換えるファイル (custom-layouts.json・applied-layouts.json) は
# 同じディレクトリ (backup_dir) に写し、そのディレクトリを作るときに新しい方から ${keep_backups} 回分を残す。ファイルが無ければ何もしない
backup_dir=""
backup_file() {
  local dirs=() i dir
  [[ -e $1 ]] || return 0
  if [[ -z ${backup_dir} ]]; then
    dir="${backup_root}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p -- "${dir}" 2>/dev/null || return 1
    backup_dir=${dir}
    # ディレクトリの名前が時刻で始まるので、名前の順が古い順
    shopt -s nullglob
    dirs=("${backup_root}"/*/)
    shopt -u nullglob
    for ((i = 0; i < ${#dirs[@]} - keep_backups; i++)); do
      rm -rf -- "${dirs[i]}" 2>/dev/null || true
    done
  fi
  cp -p -- "$1" "${backup_dir}/" 2>/dev/null
}

# 書く中身 (PC のファイルの写しに、計画の書くものを当てたもの) を、PowerToys の書く形で出す
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
render_pc_layouts() {
  jq -n --slurpfile pc "${work_dir}/pc.json" --slurpfile plan "${work_dir}/plan.json" "${layouts_lib}"'
    ($pc[0] | if type == "object" then . else {} end) as $doc
    | reduce ($plan[0].entries[] | select(.write)) as $x ($doc | layouts;
        uuid_index($x.uuid) as $i | if $i == null then . + [$x.want] else .[$i] = $x.want end) as $list
    | $doc | .["custom-layouts"] = $list' | to_pt_form
}

# 隣に書いてから置き換える (読みかけを見せない)
write_pc_layouts() {
  local tmp="${pc_layouts}.dotfiles-tmp" body
  if body=$(render_pc_layouts 2>/dev/null) && printf '%s' "${body}" 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${pc_layouts}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 書き換えずに残したもの (PC で直した・足す前からあった・消えた) を警告し、直されたものの違いをその場にだけ出す
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
report_kept() {
  local kept hint i count label
  kept=$(jq -r '.entries[] | select(.action == "edited" or .action == "differs" or .action == "deleted")
    | "\(.name): \(
        if .action == "edited" then "PC のエディターで直されています (前に足した中身と違う)"
        elif .action == "differs" then "dotfiles が足す前から PC にあり、repo と中身が違います"
        else "PC から消えています (前に足したもの。エディターで消したか、エディターを開いたまま流して閉じると消えます)" end)\(
        if .has_cur and (.cur.name != .name) then " (PC での名前は「\(.cur.name | tostring)」)" else "" end)"' "${work_dir}/plan.json")
  [[ -n ${kept} ]] || return 0
  # PC にあるもの (直した・足す前からあった) は取り込める。--import は PC の名前で引く
  jq '[.entries[] | select(.action == "edited" or .action == "differs")]' "${work_dir}/plan.json" >"${work_dir}/kept.json"
  hint=$(jq -r 'map("--import \(.cur.name | tostring | @sh)") | join(" ")' "${work_dir}/kept.json")
  # --force はディスプレイへのあて方の段 (上の 4) にも効くので、そのことと、先に見る口を添える
  warn "FancyZones のカスタムレイアウトのうち、次のものは PC の中身を残しました (書き換えていません。${pc_layouts}):" \
    "${kept}" \
    "repo の中身にするなら (PC のファイルは退避します): ${script_dir}/bootstrap-windows-fancyzones.sh --force" \
    "--force は、手でディスプレイにあてたカスタムレイアウト・blank の組も、解像度の決まりのレイアウトで上書きします。先に --dry-run --force で何が変わるかを見られます。" \
    ${hint:+"PC の中身を repo へ取り込むなら (commit は自分で): ${script_dir}/bootstrap-windows-fancyzones.sh ${hint}"}
  # 直されたものの違い (PC → repo)。長くなるので、警告のまとめには入れない
  command -v diff &>/dev/null || return 0
  count=$(jq 'length' "${work_dir}/kept.json")
  for ((i = 0; i < count; i++)); do
    jq -S --indent 2 --argjson i "${i}" '.[$i].cur' "${work_dir}/kept.json" >"${work_dir}/diff-pc.json"
    jq -S --indent 2 --argjson i "${i}" '.[$i].want' "${work_dir}/kept.json" >"${work_dir}/diff-repo.json"
    label=$(jq -r --argjson i "${i}" '.[$i].name' "${work_dir}/kept.json")
    diff -u --label "${label} (PC)" --label "${label} (repo)" -- "${work_dir}/diff-pc.json" "${work_dir}/diff-repo.json" >&2 || true
  done
}

# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
sync_layouts() {
  local problems fresh=false force_json=false pre="" lines pc_only nwrite nsame
  problems=$(layouts_problems)
  if [[ -n ${problems} ]]; then
    warn "${layouts_rel} に誤りがあるので、FancyZones のカスタムレイアウトを書きません:" "${problems}"
    return 0
  fi
  # repo にレイアウトが無ければ、PC のファイルは読まない (前に足した記録があれば消す)
  if [[ $(jq '.["custom-layouts"] | length' "${layouts_file}") == 0 ]]; then
    if [[ -e ${record_file} ]] && make_work_dir && load_record; then
      printf '%s\n' '{"entries":[]}' >"${work_dir}/plan.json"
      save_record false
    fi
    return 0
  fi
  if ((force)); then
    force_json=true
  fi
  if ! make_work_dir; then
    warn "一時ディレクトリを作れないので、FancyZones のカスタムレイアウトを書きません (TMPDIR=${TMPDIR:-/tmp})。"
    return 0
  fi
  if ! load_record; then
    warn "FancyZones のカスタムレイアウトの記録が壊れているので、カスタムレイアウトを書きません: ${record_file}" \
      "消してから流し直すと、PC にあって repo と中身が違うレイアウトは、PC の中身を残して知らせます (--force か --import で解く)。"
    return 0
  fi
  if [[ -e ${pc_layouts} ]]; then
    if ! snapshot_pc_layouts; then
      warn "FancyZones の custom-layouts.json を読めないので、カスタムレイアウトを書きません: ${pc_layouts}" \
        "中身を確かめて直してから、流し直してください。"
      return 0
    fi
  else
    # 無いのは PowerToys の設定を消したとき (エディターは消さない)。記録によらず repo のレイアウトだけで作る
    fresh=true
    printf '%s\n' '{}' >"${work_dir}/pc.json"
  fi

  # 計画: repo のレイアウトごとの判定 (entries) と、PC にだけあるレイアウトの名前 (pc_only)
  jq -n --slurpfile repo "${layouts_file}" --slurpfile pc "${work_dir}/pc.json" --slurpfile rec "${work_dir}/rec.json" \
    --argjson fresh "${fresh}" --argjson force "${force_json}" "${layouts_lib}"'
    ($repo[0]["custom-layouts"]) as $want
    | ($pc[0] | layouts) as $cur
    | ($rec[0].layouts) as $recs
    | {
        entries: [
          $want[] as $w
          | ($cur | uuid_index($w.uuid)) as $i
          | {
              uuid: $w.uuid,
              name: $w.name,
              want: $w,
              has_cur: ($i != null),
              cur: (if $i == null then null else $cur[$i] end),
              has_rec: ($recs | has($w.uuid)),
              rec: $recs[$w.uuid]
            }
          | .action = (
              if .has_cur and .cur == .want then "same"
              elif .has_cur and .has_rec and .cur == .rec then "update"
              elif (.has_cur | not) and ($fresh or (.has_rec | not)) then "add"
              elif $force then (if .has_cur then "force" else "readd" end)
              elif .has_cur then (if .has_rec then "edited" else "differs" end)
              else "deleted" end)
          | .write = (.action == "add" or .action == "update" or .action == "force" or .action == "readd")
        ],
        pc_only: [$cur[] | objects | select(.uuid as $u | all($want[]; .uuid != $u)) | (.name // "(名前なし)" | tostring)]
      }' >"${work_dir}/plan.json"

  if ((dry_run)); then
    pre="[dry-run] "
  fi
  lines=$(jq -r --arg pre "${pre}" '.entries[] | select(.write)
    | "  \($pre)\(.name): \(
        if .action == "add" then "足す"
        elif .action == "update" then "書き換える (repo が更新された)"
        elif .action == "force" then "書き換える (--force)"
        else "足し直す (--force。PC に無かった)" end)"' "${work_dir}/plan.json")
  pc_only=$(jq -r '.pc_only | join("、")' "${work_dir}/plan.json")
  nwrite=$(jq '[.entries[] | select(.write)] | length' "${work_dir}/plan.json")
  nsame=$(jq '[.entries[] | select(.action == "same")] | length' "${work_dir}/plan.json")
  # --dry-run では書かないので、あて方の段が「足したら PC にある」と見られるよう、足す・書き換えるものを渡す
  if ((dry_run && nwrite > 0)); then
    pending_layouts=$(jq -c '[.entries[] | select(.write) | .uuid]' "${work_dir}/plan.json")
  fi

  if ((nwrite == 0)); then
    save_record false
    if [[ $(jq '[.entries[] | select(.action != "same")] | length' "${work_dir}/plan.json") == 0 ]]; then
      if [[ -n ${pc_only} ]]; then
        echo "FancyZones のカスタムレイアウトは揃っています (dotfiles のもの ${nsame} 件。PC にだけあるもの $(jq '.pc_only | length' "${work_dir}/plan.json") 件には触りません)。"
      else
        echo "FancyZones のカスタムレイアウトは揃っています (dotfiles のもの ${nsame} 件)。"
      fi
    fi
    report_kept
    return 0
  fi

  if ((! dry_run)); then
    if [[ ${fresh} == true ]] && ! mkdir -p -- "${fz_dir}" 2>/dev/null; then
      warn "FancyZones の custom-layouts.json を作れませんでした: ${pc_layouts}" \
        "Windows 側のディレクトリを確かめてから、流し直してください。"
      save_record false
      report_kept
      return 0
    fi
    if ! backup_file "${pc_layouts}"; then
      warn "FancyZones の custom-layouts.json を退避できないので、カスタムレイアウトを書きません: ${backup_root}" "${lines}"
      save_record false
      report_kept
      return 0
    fi
    if ! write_pc_layouts; then
      warn "FancyZones の custom-layouts.json に書けないので、カスタムレイアウトを足せませんでした: ${pc_layouts}" "${lines}"
      save_record false
      report_kept
      return 0
    fi
    touch -- "${pc_layouts}" 2>/dev/null \
      || warn "FancyZones の custom-layouts.json に書きましたが、FancyZones に読み直させられませんでした: ${pc_layouts}" \
        "PowerToys を起動し直すか、エディターを開いて閉じると読みます。"
    save_record true
  fi

  echo "==> ${pre}FancyZones のカスタムレイアウト (${pc_layouts})"
  if [[ ${fresh} == true ]]; then
    echo "  ${pre}custom-layouts.json が無いので作る"
  fi
  printf '%s\n' "${lines}"
  if [[ -n ${pc_only} ]]; then
    echo "  PC にだけあるレイアウトには触りません: ${pc_only}"
  fi
  if [[ -n ${backup_dir} ]]; then
    echo "  書き換える前のファイルは ${backup_dir} に退避しました。"
  fi
  report_kept
}

# ---- ディスプレイへのあて方 (applied-layouts.json) ----

# jq で使う関数 (applied-layouts.json)。
#   well_formed            組が object で、device (monitor が文字列) と applied-layout が object
#   entry_key              あて方の記録のキー (monitor|monitor-instance|monitor-number|virtual-desktop)。シリアルは入れない
#   is_template            テンプレートのまま (blank を除く。FancyZones が既定であてたものも、エディターで選んだものも)
#   is_recorded($rec)      この段が前にあてたまま (今のカスタムレイアウトが、あて方の記録と同じ)
#   parse_displays         powershell.exe の返りを、FancyZones と同じ形 (DeviceID を # で分けた monitor・monitor-instance と、
#                          \\.\DISPLAY<n> の n) にする。形の合わないディスプレイは落とす
#   parse_desktops         powershell.exe の返りの仮想デスクトップを、大文字の {...} の GUID の並び (重ねず、Windows の並びのまま) に
#                          する。形の合わないものと、null の GUID は落とす
#   usable_layout          PC のレイアウトを組にあてられるか (canvas で、info.zones が配列)
#   applied_value($uuid)   PC のレイアウトを組にあてるときの applied-layout (エディターが canvas のカスタムをあてたときと同じ値)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
assign_lib='
def well_formed:
  type == "object" and (.device | type) == "object" and (.device.monitor | type) == "string"
  and (.["applied-layout"] | type) == "object";
def entry_key:
  "\(.device.monitor)|\(.device["monitor-instance"])|\(.device["monitor-number"])|\(.device["virtual-desktop"])";
def is_template:
  .["applied-layout"].type as $t | any("focus", "columns", "rows", "grid", "priority-grid"; . == $t);
def is_recorded($rec):
  .["applied-layout"].type == "custom" and (.["applied-layout"].uuid | type) == "string"
  and $rec[entry_key] == .["applied-layout"].uuid;
def parse_desktops:
  reduce (.desktops[]? | strings | ascii_upcase
      | select(test("^\\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\}$"))
      | select(. != "{00000000-0000-0000-0000-000000000000}")) as $v
    ([]; if any(.[]; . == $v) then . else . + [$v] end);
def usable_layout:
  type == "object" and .type == "canvas" and (.info | type) == "object" and (.info.zones | type) == "array";
def applied_value($uuid):
  {uuid: $uuid, type: "custom", "show-spacing": false, spacing: 0, "zone-count": (.info.zones | length),
   "sensitivity-radius": (if (.info["sensitivity-radius"] | type) == "number" then .info["sensitivity-radius"] else 20 end)};
def parse_displays:
  [.displays[]? | objects
    | select((.device | type) == "string" and (.id | type) == "string"
        and (.width | type) == "number" and (.height | type) == "number" and .width > 0 and .height > 0)
    | (.id | split("#")) as $p
    | ([.device | match("DISPLAY([0-9]+)$") | .captures[0].string] | first) as $n
    | select(($p | length) >= 4 and $n != null)
    | {monitor: $p[1], instance: $p[2], number: ($n | tonumber), width, height}];
'

# PC の applied-layouts.json を作業場所へ写す。applied-layouts が配列の JSON の object (無いのはよい) になるまで、5 回まで写す
# (FancyZones・エディターが書いている途中に当たっても読めるように)
snapshot_applied() {
  local i
  for ((i = 0; i < 5; i++)); do
    if cp -- "${pc_applied}" "${work_dir}/apl.json" 2>/dev/null \
      && jq -e 'type == "object" and ((has("applied-layouts") | not) or (.["applied-layouts"] | type) == "array")' \
        "${work_dir}/apl.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# あて方の記録を作業場所へ写す。無ければ空の記録。壊れていれば失敗する
load_assigned() {
  if [[ ! -e ${assigned_file} ]]; then
    printf '%s\n' '{"version":1,"assignments":{}}' >"${work_dir}/asg.json"
    return 0
  fi
  jq -e 'type == "object" and (.assignments | type) == "object"' "${assigned_file}" >/dev/null 2>&1 || return 1
  cp -- "${assigned_file}" "${work_dir}/asg.json"
}

# あて方の記録を書く (変わったときだけ。--dry-run では書かない)。applied-layouts.json から消えた組のキーは落とし、目標と同じ組で
# 記録が無いものと、書けたときは書いた組・作った組を、目標のレイアウトの uuid で記録する。$1: 書けたか (true / false)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
save_assigned() {
  local new old
  if ((dry_run)); then
    return 0
  fi
  new=$(jq -S -n --slurpfile apl "${work_dir}/apl.json" --slurpfile rec "${work_dir}/asg.json" --slurpfile plan "${work_dir}/plan3.json" \
    --argjson wrote "$1" "${assign_lib}"'
    (if $wrote then [($plan[0].created // [])[] | select(.write)] else [] end) as $made
    | ([($apl[0]["applied-layouts"] // [])[] | select(well_formed) | entry_key] + [$made[].key] | unique) as $keys
    | ($rec[0].assignments | with_entries(select(.key as $k | any($keys[]; . == $k)))) as $kept
    | reduce ($plan[0].entries[] | . as $x
        | select($x.key != null and (($x.action == "same" and ($kept | has($x.key) | not)) or ($wrote and $x.write)))) as $x
        ($kept; .[$x.key] = $x.target)
    | reduce $made[] as $x (.; .[$x.key] = $x.target)
    | {version: 1, assignments: .}')
  # 記録が無いのは、空の記録と同じ (記録するものが無ければ作らない)
  if [[ -f ${assigned_file} ]]; then
    old=$(jq -S . "${assigned_file}" 2>/dev/null) || old=""
  else
    old=$(jq -S -n '{version: 1, assignments: {}}')
  fi
  if [[ ${new} == "${old}" ]]; then
    return 0
  fi
  if ! { mkdir -p -- "${state_dir}" && printf '%s\n' "${new}" >"${assigned_file}.dotfiles-tmp" && mv -f -- "${assigned_file}.dotfiles-tmp" "${assigned_file}"; } 2>/dev/null; then
    rm -f -- "${assigned_file}.dotfiles-tmp" 2>/dev/null || true
    warn "FancyZones のディスプレイへのあて方の記録を書けませんでした: ${assigned_file}" \
      "次の回は、決まりであてた組を手であてたものとして残すことがあります (--force で決まりのレイアウトにし直せます)。"
  fi
}

# PowerShell のコードを、powershell.exe の -EncodedCommand に渡す形 (UTF-16LE の base64) にする。ASCII だけを受け、ASCII の外の
# 文字があれば 1 を返す (ASCII なら UTF-16LE は 1 byte ごとに 0 を足すだけなので、coreutils の od と base64 で作れる)。
# -EncodedCommand で渡すのは、C# の P/Invoke ("user32.dll") の二重引用符が、WSL の interop の付ける引用符と混ざらないようにするため
# (bootstrap-windows-international.sh と同じ)
encode_ps() {
  local LC_ALL=C hex bytes
  if [[ $1 == *[![:ascii:]]* ]]; then
    return 1
  fi
  hex=$(printf '%s' "$1" | od -An -v -tx1)
  read -r -d '' -a bytes <<<"${hex}" || true
  # 書式は \xHH の並びだけで、% を含まない
  # shellcheck disable=SC2059
  printf "$(printf '\\x%s\\x00' "${bytes[@]}")" | base64 -w0
}

# powershell.exe (Windows PowerShell 5.1) で流すコード (ASCII だけで書く)。FancyZones (MonitorUtils.cpp) と同じく、デスクトップに
# つながっているアダプターごとに、ACTIVE で MIRRORING_DRIVER でない最初のモニターの DeviceID (EDD_GET_DEVICE_INTERFACE_NAME) を取り、
# アダプターの今の表示の解像度 (EnumDisplaySettings の ENUM_CURRENT_SETTINGS。物理の値で、拡大率に左右されない) と組にする。
# Win32 は C# から呼ぶ (PowerShell から文字列の引数に $null を渡すと空文字になり、最初のアダプターを引けないため)。
# 同じ呼び出しで、Windows の仮想デスクトップの一覧も読む。FancyZones (VirtualDesktop.cpp) と同じく、HKCU の
# Explorer\VirtualDesktops の VirtualDesktopIDs (16 バイトずつの GUID) を、FancyZones が組に書く形 (大文字の {...}) にする。
# 値が無ければ (Windows に仮想デスクトップが 1 つのとき) 空の配列。
# $ProgressPreference は、Add-Type の進み具合が CLIXML で stderr に出ないようにするため。返りは 1 行の JSON:
#   {"displays":[{"device":"\\.\DISPLAY1","id":"\\?\DISPLAY#<monitor>#<monitor-instance>#{...}","width":3840,"height":2160}],
#    "desktops":["{EA30C0ED-D985-4D21-9BC7-27C9D2A6EDC5}"]}
ps_body=$(
  cat <<'EOS'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DotfilesFancyZonesDisplays {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX;
    public int dmPositionY;
    public int dmDisplayOrientation;
    public int dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel;
    public int dmPelsWidth;
    public int dmPelsHeight;
    public int dmDisplayFlags;
    public int dmDisplayFrequency;
    public int dmICMMethod;
    public int dmICMIntent;
    public int dmMediaType;
    public int dmDitherType;
    public int dmReserved1;
    public int dmReserved2;
    public int dmPanningWidth;
    public int dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplayDevicesW(string lpDevice, int iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, int dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
  public class Display {
    public string Device { get; set; }
    public string Id { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
  }
  // DISPLAY_DEVICE_ATTACHED_TO_DESKTOP (adapter) and DISPLAY_DEVICE_ACTIVE (monitor) are 0x1,
  // DISPLAY_DEVICE_MIRRORING_DRIVER is 0x8, EDD_GET_DEVICE_INTERFACE_NAME is 0x1, ENUM_CURRENT_SETTINGS is -1.
  public static Display[] Get() {
    var list = new List<Display>();
    for (int i = 0; ; i++) {
      var adapter = new DISPLAY_DEVICE();
      adapter.cb = Marshal.SizeOf(adapter);
      if (!EnumDisplayDevicesW(null, i, ref adapter, 0)) { break; }
      if ((adapter.StateFlags & 0x1) == 0 || (adapter.StateFlags & 0x8) != 0) { continue; }
      var mode = new DEVMODE();
      mode.dmSize = (short)Marshal.SizeOf(mode);
      if (!EnumDisplaySettingsW(adapter.DeviceName, -1, ref mode)) { continue; }
      for (int j = 0; ; j++) {
        var monitor = new DISPLAY_DEVICE();
        monitor.cb = Marshal.SizeOf(monitor);
        if (!EnumDisplayDevicesW(adapter.DeviceName, j, ref monitor, 0x1)) { break; }
        if ((monitor.StateFlags & 0x1) == 0 || (monitor.StateFlags & 0x8) != 0) { continue; }
        list.Add(new Display { Device = adapter.DeviceName, Id = monitor.DeviceID, Width = mode.dmPelsWidth, Height = mode.dmPelsHeight });
        break;
      }
    }
    return list.ToArray();
  }
}
'@
$displays = @([DotfilesFancyZonesDisplays]::Get() | ForEach-Object {
  [ordered]@{ device = $_.Device; id = $_.Id; width = $_.Width; height = $_.Height }
})
$desktops = @()
$vd = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops' -Name 'VirtualDesktopIDs' -ErrorAction SilentlyContinue
if ($null -ne $vd -and $vd.VirtualDesktopIDs -is [byte[]]) {
  $raw = $vd.VirtualDesktopIDs
  for ($i = 0; $i + 16 -le $raw.Length; $i += 16) {
    $desktops += [System.Guid]::new([byte[]]($raw[$i..($i + 15)])).ToString('B').ToUpperInvariant()
  }
}
ConvertTo-Json -Compress -Depth 3 -InputObject ([ordered]@{ displays = $displays; desktops = $desktops })
EOS
)

# powershell.exe でディスプレイを聞く。stdout (CR を落とす) を ps_out に、stderr (CR を落とす) を ps_err に、終了コード
# (時間切れは 124) を ps_rc に入れる。stdin は渡さない (interop が stdin を読み続けて止まらないように)。-OutputFormat Text は、
# -EncodedCommand で起動したときにエラーを CLIXML でなく平文で出すため
ps_rc=0
ps_out=""
ps_err=""
read_displays() {
  local enc
  ps_rc=0
  ps_out=""
  ps_err=""
  if ! enc=$(encode_ps "${ps_body}"); then
    ps_rc=1
    ps_err="powershell.exe に渡すコードに ASCII の外の文字があります (script の誤り)。"
    return 0
  fi
  ps_out=$(timeout 60 powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand "${enc}" </dev/null 2>"${work_dir}/ps-err") \
    || ps_rc=$?
  ps_out=${ps_out//$'\r'/}
  ps_err=$(<"${work_dir}/ps-err") || ps_err=""
  ps_err=${ps_err//$'\r'/}
}

# 書く中身 (applied-layouts.json の写しの、計画で書く組の applied-layout を置き換え、作る組を末尾に足したもの) を、PowerToys の書く形で
# 出す。今ある組の device・並び・ほかの組は変えない
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
render_applied() {
  jq -n --slurpfile apl "${work_dir}/apl.json" --slurpfile plan "${work_dir}/plan3.json" '
    ([$plan[0].entries[] | select(.write) | {key: (.i | tostring), value: .new_al}] | from_entries) as $w
    | [($plan[0].created // [])[] | select(.write) | {device, "applied-layout": .new_al}] as $add
    | $apl[0] | .["applied-layouts"] |= ([to_entries[] | (.key | tostring) as $k
        | if ($w | has($k)) then .value["applied-layout"] = $w[$k] else . end | .value] + $add)' | to_pt_form
}

# 隣に書いてから置き換える (読みかけを見せない)
write_applied() {
  local tmp="${pc_applied}.dotfiles-tmp" body
  if body=$(render_applied 2>/dev/null) && printf '%s' "${body}" 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${pc_applied}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 手であてたカスタムレイアウト・blank の組を残したことの 1 行 (警告のまとめには載せない。会社の PC で毎回出るため)。$1: 組の数
kept_line() {
  echo "手であてたカスタムレイアウト・blank の組 ($1 組) は残しました。決まりのレイアウトで上書きするなら: ${script_dir}/bootstrap-windows-fancyzones.sh --force (--force は、PC で直した・消した dotfiles のカスタムレイアウトも repo の中身に戻します。先に --dry-run --force で何が変わるかを見られます)"
}

# 写せる組が無いので組を作らなかった画面の 1 行 (警告のまとめには載せない。FancyZones かエディターがその画面の組を書けば、次の回に作る)。
# $1: 画面を「、」で並べたもの
nosrc_line() {
  echo "次の画面は、同じ画面 (モニター ID と instance が同じ) の組がどの仮想デスクトップにも無いので、組を作りません: $1"
}

# 揃っているときの 1 行の括弧の中。$1: 目標と同じ組の数、$2: 触らない組の数
same_note() {
  local parts=()
  if (($1 > 0)); then
    parts+=("決まりのレイアウトの組 $1 組")
  fi
  if (($2 > 0)); then
    parts+=("つながっていない・縦向きのディスプレイの組 $2 組には触りません")
  fi
  if ((${#parts[@]} == 2)); then
    echo " (${parts[0]}。${parts[1]})"
  elif ((${#parts[@]} == 1)); then
    echo " (${parts[0]})"
  fi
}

# ディスプレイへのあて方 (上の 4): つながっている横向きのディスプレイの組へ、解像度の決まり (layout-rules.json) のレイアウトをあてる
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
assign_layouts() {
  local problems force_json=false pre="" nkept counts nwrite nsame nuntouched ncreate nosrc missing lname lcount lines
  # 無いのは、FancyZones がまだ動いていない (ディスプレイを開いていない) とき
  [[ -e ${pc_applied} ]] || return 0
  if ! make_work_dir; then
    warn "一時ディレクトリを作れないので、FancyZones のディスプレイへのレイアウトのあて方を書きません (TMPDIR=${TMPDIR:-/tmp})。"
    return 0
  fi
  if ! snapshot_applied; then
    warn "FancyZones の applied-layouts.json を読めないので、ディスプレイへのレイアウトのあて方を書きません: ${pc_applied}" \
      "中身を確かめて直してから、流し直してください。"
    return 0
  fi
  if [[ $(jq '[.["applied-layouts"][]?] | length' "${work_dir}/apl.json") == 0 ]]; then
    return 0
  fi
  if [[ -n $(layouts_problems) ]]; then
    warn "${layouts_rel} に誤りがあるので、FancyZones のディスプレイへのレイアウトのあて方を書きません。"
    return 0
  fi
  problems=$(rules_problems)
  if [[ -n ${problems} ]]; then
    warn "${rules_rel} に誤りがあるので、FancyZones のディスプレイへのレイアウトのあて方を書きません:" "${problems}"
    return 0
  fi
  if ! load_assigned; then
    warn "FancyZones のディスプレイへのあて方の記録が壊れているので、あて方を書きません: ${assigned_file}" \
      "消してから流し直してください (前に決まりであてた組も、手であてたものとして残します。決まりのレイアウトにし直すなら --force)。"
    return 0
  fi
  if ((force)); then
    force_json=true
  fi
  if ((dry_run)); then
    pre="[dry-run] "
  fi

  # 組があれば、埋める組が無くても powershell.exe は呼ぶ。組の無い仮想デスクトップ (作る組) があるかは、Windows に仮想デスクトップの
  # 一覧を聞かないと分からないため

  # あてるレイアウトが PC にあるかと、ゾーンの数を見るために、カスタムレイアウトの段の後の PC の custom-layouts.json を読む
  if ! read_pc_layouts; then
    warn "FancyZones の custom-layouts.json を読めないので、ディスプレイへのレイアウトのあて方を書きません: ${pc_layouts}"
    return 0
  fi
  if ! command -v powershell.exe &>/dev/null; then
    warn "powershell.exe が見つからないので、ディスプレイの解像度が分からず、FancyZones のディスプレイへのレイアウトのあて方を書きません。" \
      "WSL の PATH に Windows の PATH が入っているか (/etc/wsl.conf の appendWindowsPath)、WSL の interop が動いているかを確かめてください。"
    return 0
  fi
  read_displays
  if ((ps_rc != 0)); then
    if ((ps_rc == 124)); then
      warn "powershell.exe が 60 秒たっても終わりませんでした (時間切れ。WSL の interop が止まっているかもしれません)。FancyZones のディスプレイへのレイアウトのあて方は書きません。"
    else
      warn "powershell.exe でディスプレイの解像度を読めませんでした (終了コード ${ps_rc})。FancyZones のディスプレイへのレイアウトのあて方は書きません:" \
        ${ps_err:+"${ps_err}"}
    fi
    return 0
  fi
  if ! printf '%s\n' "${ps_out}" 2>/dev/null >"${work_dir}/displays.json" \
    || ! jq -e 'type == "object" and (.displays | type) == "array" and (.desktops | type) == "array"' "${work_dir}/displays.json" >/dev/null 2>&1; then
    warn "powershell.exe の返りが、決めた形の JSON ではありません。FancyZones のディスプレイへのレイアウトのあて方は書きません:" \
      ${ps_out:+"${ps_out}"} ${ps_err:+"${ps_err}"}
    return 0
  fi

  # 計画: 組ごとの判定 (entries) と、作る組 (created) と、写せる組の無い画面 (nosrc)。
  # entries の action は untouched (合うディスプレイが無い・縦向き・壊れた組) / same (目標と同じ) / fill (テンプレート) /
  # retarget (この段が前にあてたままで目標が変わった) / default (横向きの既定 (決まりの default のレイアウト) があたり、この段の記録に
  # 無い) / force (--force で、手であてたカスタムレイアウト・blank・知らない type) / kept (それらを残す) / missing (目標のレイアウトが
  # PC に無いか canvas でない)。ディスプレイは、monitor が同じで monitor-instance が同じものを先に、無ければ monitor-number が同じものに
  # 合わせる (FancyZones の一致からシリアルを除いたもの)。
  # created は、つながっている横向きの画面ごとに、同じ画面 (monitor と monitor-instance が同じ。FancyZones が同じ画面とみなす) の組を
  # シリアル (中を見ない値) ごとに分け、Windows の仮想デスクトップのうち、今の番号でその組が無いデスクトップへ作る組。device は今の番号の
  # 組があればそれ、無ければ番号の違う組 (番号が振り直された直後) から写し、monitor-number と virtual-desktop だけを替える (FancyZones の
  # エディターは、組を monitor・シリアル・monitor-number・virtual-desktop の一致で引くため)
  jq -n --slurpfile apl "${work_dir}/apl.json" --slurpfile ps "${work_dir}/displays.json" --slurpfile rules "${rules_file}" \
    --slurpfile repo "${layouts_file}" --slurpfile pc "${work_dir}/pc.json" --slurpfile rec "${work_dir}/asg.json" \
    --argjson pending "${pending_layouts}" --argjson force "${force_json}" "${layouts_lib}${assign_lib}"'
    ($ps[0] | parse_displays) as $disp
    | ($ps[0] | parse_desktops) as $vds
    | $rules[0] as $r
    | ($repo[0] | layouts) as $repo_list
    | $rec[0].assignments as $asg
    | ["fill", "retarget", "default", "force"] as $writes
    | ([$repo_list[] | {key: .name, value: .}] | from_entries) as $by_name
    | $by_name[$r.default].uuid as $default_uuid
    | ([$pc[0] | layouts | .[] | objects | select((.uuid | type) == "string") | {key: .uuid, value: .}] | from_entries) as $pc_by_uuid
    | ($pc_by_uuid + ([$repo_list[] | select(.uuid as $u | any($pending[]; . == $u)) | {key: .uuid, value: .}] | from_entries)) as $present
    | [($apl[0]["applied-layouts"] // [])[] | select(well_formed)] as $wf
    | [$disp[] | select(.height <= .width)] as $landscape
    | {created: [
        $landscape[] as $d
        | [$wf[] | select(.device.monitor == $d.monitor and .device["monitor-instance"] == $d.instance)] as $same
        | select(($same | length) > 0)
        | ([$r.rules[] | select(.resolution == "\($d.width)x\($d.height)") | .layout] | first // $r.default) as $tname
        | $by_name[$tname] as $tl
        | $present[$tl.uuid] as $pl
        | ($same | group_by(.device["serial-number"]))[] as $grp
        | (([$grp[] | select(.device["monitor-number"] == $d.number)] | first) // $grp[0]) as $src
        | [$grp[] | select(.device["monitor-number"] == $d.number) | .device["virtual-desktop"] | tostring | ascii_upcase] as $have
        | $vds[] as $vd
        | select(all($have[]; . != $vd))
        | {device: ($src.device | .["monitor-number"] = $d.number | .["virtual-desktop"] = $vd)}
        | .key = entry_key
        | .target = $tl.uuid
        | .tname = $tname
        | .label = "\($d.monitor) (\($d.instance | split("&") | last))・\($d.width)x\($d.height)・仮想デスクトップ \($vd | ltrimstr("{") | .[0:8])"
        | if ($pl | usable_layout) then .write = true | .new_al = ($pl | applied_value($tl.uuid)) else .write = false end
      ],
      nosrc: [
        $landscape[] as $d
        | select(all($wf[]; (.device.monitor == $d.monitor and .device["monitor-instance"] == $d.instance) | not))
        | "\($d.monitor) (\($d.instance | split("&") | last))・\($d.width)x\($d.height)"
      ],
      entries: [
        ($apl[0]["applied-layouts"] // []) | to_entries[] | .key as $i | .value as $e
        | if ($e | well_formed | not) then
            {i: $i, action: "untouched"}
          else
            $e.device as $dev
            | (([$disp[] | select(.monitor == $dev.monitor and .instance == $dev["monitor-instance"])] | first)
               // ([$disp[] | select(.monitor == $dev.monitor and .number == $dev["monitor-number"])] | first)) as $d
            | if $d == null or $d.height > $d.width then
                {i: $i, action: "untouched"}
              else
                ([$r.rules[] | select(.resolution == "\($d.width)x\($d.height)") | .layout] | first // $r.default) as $tname
                | $by_name[$tname] as $tl
                | $present[$tl.uuid] as $pl
                | $e["applied-layout"] as $al
                | (if $al.type == "custom" and $al.uuid == $tl.uuid then "same"
                   elif ($e | is_template) then "fill"
                   elif ($e | is_recorded($asg)) then "retarget"
                   elif $al.type == "custom" and $al.uuid == $default_uuid then "default"
                   elif $force then "force"
                   else "kept" end) as $base
                | ($pl | usable_layout) as $usable
                | (if any($writes[]; . == $base) and ($usable | not) then "missing" else $base end) as $action
                | {i: $i, key: ($e | entry_key), action: $action, target: $tl.uuid, tname: $tname,
                   label: "\($dev.monitor) (\($dev["monitor-instance"] | tostring | split("&") | last))・\($d.width)x\($d.height)・仮想デスクトップ \($dev["virtual-desktop"] | tostring | ltrimstr("{") | .[0:8])",
                   before: (if $al.type == "custom" then ($pc_by_uuid[$al.uuid | tostring].name // "カスタム \($al.uuid)") else ($al.type | tostring) end),
                   note: (if $action == "retarget" then " (前に決まりであてたもの)" elif $action == "default" then " (横向きの既定)"
                          elif $action == "force" then " (--force)" else "" end)}
                | if any($writes[]; . == $action) then .new_al = ($pl | applied_value($tl.uuid)) else . end
              end
          end
        | .write = (.action as $a | any($writes[]; . == $a))
      ]}' >"${work_dir}/plan3.json"

  counts=$(jq -r '[(.entries | map(select(.write)), map(select(.action == "same")), map(select(.action == "kept")), map(select(.action == "untouched"))),
      (.created | map(select(.write)))] | map(length) | @tsv' "${work_dir}/plan3.json")
  read -r nwrite nsame nkept nuntouched ncreate <<<"${counts}"
  nosrc=$(jq -r '.nosrc | join("、")' "${work_dir}/plan3.json")
  # 目標のレイアウトが PC に無い組 (PC で消して、カスタムレイアウトの段が警告した) は、埋めず・作らずに知らせる
  missing=$(jq -r '[(.entries[] | select(.action == "missing") | .tname), (.created[] | select(.write | not) | .tname)]
    | group_by(.)[] | "\(.[0])\t\(length)"' "${work_dir}/plan3.json")
  if [[ -n ${missing} ]]; then
    while IFS=$'\t' read -r lname lcount; do
      warn "決まりのレイアウト「${lname}」が PC の custom-layouts.json に無い (か canvas でない) ので、${lcount} 組にあてていません: ${pc_layouts}" \
        "PC で消したものなら、--force で足し直すとあてます (先に --dry-run --force で何が変わるかを見られます)。"
    done <<<"${missing}"
  fi

  if ((nwrite == 0 && ncreate == 0)); then
    save_assigned false
    if [[ -z ${missing} ]]; then
      echo "FancyZones のディスプレイへのあて方は揃っています$(same_note "${nsame}" "${nuntouched}")。"
    else
      echo "FancyZones のディスプレイへのあて方で、変える組はありません$(same_note "${nsame}" "${nuntouched}")。"
    fi
    if ((nkept > 0)); then
      echo "  $(kept_line "${nkept}")"
    fi
    if [[ -n ${nosrc} ]]; then
      echo "  $(nosrc_line "${nosrc}")"
    fi
    return 0
  fi

  # 変える組と作る組を 1 組 1 行で (シリアルは出さない)。シリアルだけが違う組の同じ行は、1 行にまとめて組の数を添える
  lines=$(jq -r --arg pre "${pre}" '
    [(.entries[] | select(.write) | "  \($pre)\(.label): \(.before) → \(.tname)\(.note)"),
     (.created[] | select(.write) | "  \($pre)\(.label): 組なし → \(.tname)")]
    | reduce .[] as $l ([]; if any(.[]; .l == $l) then map(if .l == $l then .n += 1 else . end) else . + [{l: $l, n: 1}] end)
    | .[] | .l + (if .n > 1 then " (\(.n) 組)" else "" end)' "${work_dir}/plan3.json")
  if ((! dry_run)); then
    if ! backup_file "${pc_applied}"; then
      warn "FancyZones の applied-layouts.json を退避できないので、ディスプレイへのレイアウトのあて方を書きません: ${backup_root}" "${lines}"
      save_assigned false
      return 0
    fi
    if ! write_applied; then
      warn "FancyZones の applied-layouts.json に書けないので、ディスプレイへのレイアウトのあて方を変えられませんでした: ${pc_applied}" "${lines}"
      save_assigned false
      return 0
    fi
    # FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは読み直さない
    touch -- "${pc_applied}" 2>/dev/null \
      || warn "FancyZones の applied-layouts.json に書きましたが、FancyZones に読み直させられませんでした: ${pc_applied}" \
        "PowerToys を起動し直すと読みます。"
    save_assigned true
  fi

  echo "==> ${pre}FancyZones のディスプレイへのあて方 (${pc_applied})"
  printf '%s\n' "${lines}"
  if ((nuntouched > 0)); then
    echo "  つながっていない・縦向きのディスプレイの組 (${nuntouched} 組) には触りません。"
  fi
  if ((nkept > 0)); then
    echo "  $(kept_line "${nkept}")"
  fi
  if [[ -n ${nosrc} ]]; then
    echo "  $(nosrc_line "${nosrc}")"
  fi
  if ((! dry_run)) && [[ -n ${backup_dir} ]]; then
    echo "  書き換える前のファイルは ${backup_dir} に退避しました。"
  fi
}

# ---- 横向きの既定 (default-layouts.json) ----

# PC の default-layouts.json を作業場所へ写す。default-layouts が配列の JSON の object (無いのはよい) になるまで、5 回まで写す
# (エディターが書いている途中に当たっても読めるように)
snapshot_defaults() {
  local i
  for ((i = 0; i < 5; i++)); do
    if cp -- "${pc_defaults}" "${work_dir}/dl.json" 2>/dev/null \
      && jq -e 'type == "object" and ((has("default-layouts") | not) or (.["default-layouts"] | type) == "array")' \
        "${work_dir}/dl.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 隣に書いてから置き換える (読みかけを見せない)。中身は計画の doc を PowerToys の書く形で
write_defaults() {
  local tmp="${pc_defaults}.dotfiles-tmp" body
  if body=$(jq '.doc' "${work_dir}/dl-plan.json" 2>/dev/null | to_pt_form 2>/dev/null) \
    && printf '%s' "${body}" 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${pc_defaults}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 横向きの既定 (段 ② の後、段 ③ の前): FancyZones が組の無い横向きの画面にあてる既定 (default-layouts.json の horizontal) を、
# 決まりの default のカスタムレイアウトにそろえる。FancyZones の本体もエディターも、合う組が無い画面にこの既定をあてるので、ディスプレイの
# 番号が振り直されて新しい組ができても、決まりの default のレイアウトで始まる。縦向き (vertical) には触らない
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
sync_default_layout() {
  local pre="" fresh=false action before tname
  # 決まりか repo のレイアウトに誤りがあれば、黙って飛ばす (段 ③ が組のあるときに警告する。CI の --check も見る)
  if [[ -n $(layouts_problems) || -n $(rules_problems) ]]; then
    return 0
  fi
  if ! make_work_dir; then
    warn "一時ディレクトリを作れないので、FancyZones の横向きの既定を書きません (TMPDIR=${TMPDIR:-/tmp})。"
    return 0
  fi
  if ! read_pc_layouts; then
    warn "FancyZones の custom-layouts.json を読めないので、FancyZones の横向きの既定を書きません: ${pc_layouts}"
    return 0
  fi
  if [[ -e ${pc_defaults} ]]; then
    if ! snapshot_defaults; then
      warn "FancyZones の default-layouts.json を読めないので、横向きの既定を書きません: ${pc_defaults}" \
        "中身を確かめて直してから、流し直してください。"
      return 0
    fi
  else
    # 無いのは、エディターを一度も開いていない PC。横向きの項目だけで作る (縦向きは FancyZones の既定のまま)
    fresh=true
    printf '%s\n' '{}' >"${work_dir}/dl.json"
  fi
  if ((dry_run)); then
    pre="[dry-run] "
  fi

  # 計画: action は same (横向きのどの項目も、決まりの default のカスタムレイアウト。type と uuid だけを比べる) / write (書き換える・
  # 足す・作る) / missing (決まりの default のレイアウトが PC に無いか canvas でない)。書く値は、エディターがカスタムレイアウトを既定に
  # したときと同じ (zone-count と sensitivity-radius は 0。FancyZones はゾーンを計算するときに custom-layouts.json から引き直す)
  jq -n --slurpfile dl "${work_dir}/dl.json" --slurpfile rules "${rules_file}" --slurpfile repo "${layouts_file}" \
    --slurpfile pc "${work_dir}/pc.json" --argjson pending "${pending_layouts}" "${layouts_lib}${assign_lib}"'
    ($repo[0] | layouts) as $repo_list
    | $rules[0].default as $tname
    | ([$repo_list[] | objects | select(.name == $tname)] | first) as $tl
    | ([$pc[0] | layouts | .[] | objects | select((.uuid | type) == "string") | {key: .uuid, value: .}] | from_entries) as $pc_by_uuid
    | ($pc_by_uuid + ([$repo_list[] | select(.uuid as $u | any($pending[]; . == $u)) | {key: .uuid, value: .}] | from_entries)) as $present
    | ($dl[0] | if type == "object" then . else {} end) as $doc
    | ($doc["default-layouts"] // []) as $list
    | [$list[] | objects | select(.["monitor-configuration"] == "horizontal")] as $hz
    | {uuid: $tl.uuid, type: "custom", "show-spacing": false, spacing: 0, "zone-count": 0, "sensitivity-radius": 0} as $want
    | {tname: $tname,
       before: (if ($hz | length) == 0 or ($hz[0].layout | type) != "object" then "(横向きの既定なし)"
                elif $hz[0].layout.type == "custom" then ($pc_by_uuid[$hz[0].layout.uuid | tostring].name // "カスタム \($hz[0].layout.uuid)")
                else ($hz[0].layout.type | tostring) end),
       action: (if ($hz | length) > 0 and all($hz[]; (.layout | type) == "object" and .layout.type == "custom" and .layout.uuid == $tl.uuid) then "same"
                elif ($present[$tl.uuid] | usable_layout) then "write"
                else "missing" end),
       doc: ($doc | .["default-layouts"] = (if ($hz | length) > 0
               then [$list[] | if type == "object" and .["monitor-configuration"] == "horizontal" then .layout = $want else . end]
               else $list + [{"monitor-configuration": "horizontal", layout: $want}] end))}' >"${work_dir}/dl-plan.json"
  action=$(jq -r '.action' "${work_dir}/dl-plan.json")
  tname=$(jq -r '.tname' "${work_dir}/dl-plan.json")
  before=$(jq -r '.before' "${work_dir}/dl-plan.json")
  case ${action} in
    same)
      echo "FancyZones の横向きの既定のレイアウトは揃っています (${tname})。"
      return 0
      ;;
    missing)
      # PC で消したもの (カスタムレイアウトの段が警告した)。--force で足し直すと、その回に既定にする
      warn "決まりの既定のレイアウト「${tname}」が PC の custom-layouts.json に無い (か canvas でない) ので、FancyZones の横向きの既定にしていません: ${pc_defaults}" \
        "PC で消したものなら、--force で足し直すと既定にします (先に --dry-run --force で何が変わるかを見られます)。"
      return 0
      ;;
  esac
  if ((! dry_run)); then
    if [[ ${fresh} == true ]] && ! mkdir -p -- "${fz_dir}" 2>/dev/null; then
      warn "FancyZones の default-layouts.json を作れませんでした: ${pc_defaults}" \
        "Windows 側のディレクトリを確かめてから、流し直してください。"
      return 0
    fi
    if ! backup_file "${pc_defaults}"; then
      warn "FancyZones の default-layouts.json を退避できないので、横向きの既定を書きません: ${backup_root}" "${before} → ${tname}"
      return 0
    fi
    if ! write_defaults; then
      warn "FancyZones の default-layouts.json に書けないので、横向きの既定を変えられませんでした: ${pc_defaults}" "${before} → ${tname}"
      return 0
    fi
    # FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは読み直さない
    touch -- "${pc_defaults}" 2>/dev/null \
      || warn "FancyZones の default-layouts.json に書きましたが、FancyZones に読み直させられませんでした: ${pc_defaults}" \
        "PowerToys を起動し直すと読みます。"
  fi
  echo "==> ${pre}FancyZones の横向きの既定のレイアウト (${pc_defaults})"
  if [[ ${fresh} == true ]]; then
    echo "  ${pre}default-layouts.json が無いので作る"
  fi
  echo "  ${pre}${before} → ${tname}"
  if ((! dry_run)) && [[ -n ${backup_dir} ]]; then
    echo "  書き換える前のファイルは ${backup_dir} に退避しました。"
  fi
}

# ---- --import ----

# PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す。同じ uuid は同じ位置で置き換え、無ければ末尾に足す。
# PC のファイル・settings.json・記録には書かない (次の setup が、PC と repo が同じと見て記録する)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
import_layouts() {
  local problems changes errors line log changed tmp body names name_arg
  problems=$(layouts_problems)
  if [[ -n ${problems} ]]; then
    fail "${layouts_rel} に誤りがあるので、取り込めません。先に直してください:" "${problems}"
    return 1
  fi
  # 取り込みは repo のファイルを書き換える。commit していない変更 (未追跡も) があると痕跡なく消えるので、何も書かずに止まる。
  # git が無い・checkout の外で確かめられないときも止まる側に倒す。--no-optional-locks は index を書かないため
  if ! changes=$(git --no-optional-locks -C "${repo_dir}" status --porcelain --untracked-files=normal -- "${layouts_rel}" 2>&1); then
    fail "${layouts_rel} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):" \
      "${changes}" \
      "--import は ${layouts_rel} を書き換え、commit していない変更を消しうるので、止めます。"
    return 1
  fi
  if [[ -n ${changes} ]]; then
    fail "${layouts_rel} に commit していない変更があります。--import は書き換えるので、先に commit するか、変更を戻してから流し直してください。" \
      "${changes}"
    return 1
  fi
  if [[ ! -e ${pc_layouts} ]]; then
    fail "PC に custom-layouts.json がありません: ${pc_layouts}"
    return 1
  fi
  if ! make_work_dir; then
    fail "一時ディレクトリを作れないので、取り込めません (TMPDIR=${TMPDIR:-/tmp})。"
    return 1
  fi
  if ! snapshot_pc_layouts; then
    fail "PC の custom-layouts.json を読めません: ${pc_layouts}"
    return 1
  fi
  # 名前は --arg で 1 つずつ JSON の配列にする (- で始まる名前も、jq の引数と取り違えない)
  names='[]'
  for name_arg in "${import_names[@]}"; do
    names=$(jq -c --arg n "${name_arg}" '. + [$n]' <<<"${names}")
  done
  printf '%s\n' "${names}" >"${work_dir}/names.json"
  jq -n --slurpfile repo "${layouts_file}" --slurpfile pc "${work_dir}/pc.json" --slurpfile names "${work_dir}/names.json" "${layouts_lib}"'
    ($pc[0] | layouts) as $cur
    | reduce $names[0][] as $n ({doc: $repo[0], log: [], errors: [], changed: false};
        [$cur[] | objects | select(.name == $n)] as $m
        | if ($m | length) == 0 then
            .errors += ["PC に「\($n)」というカスタムレイアウトがありません (PC にあるもの: \([$cur[] | objects | (.name // "(名前なし)" | tostring)] | join("、")))。"]
          elif ($m | length) > 1 then
            .errors += ["PC に「\($n)」というカスタムレイアウトが \($m | length) つあります (uuid: \([$m[] | (.uuid // "(無い)" | tostring)] | join("、")))。エディターで名前を変えてから取り込んでください。"]
          else
            $m[0] as $l
            | [{"custom-layouts": [$l]} | layout_problems] as $bad
            | if ($bad | length) > 0 then
                .errors += ["「\($n)」は repo に置けない形です: \($bad | join(" "))"]
              else
                (.doc["custom-layouts"] | uuid_index($l.uuid)) as $i
                | if $i != null then
                    if .doc["custom-layouts"][$i] == $l then
                      .log += ["  \($n): repo と同じです"]
                    else
                      .doc["custom-layouts"][$i] = $l | .changed = true | .log += ["  \($n): repo の同じ uuid のレイアウトを置き換えた"]
                    end
                  else
                    [.doc["custom-layouts"][] | select(.name == $n) | .uuid] as $same
                    | if ($same | length) > 0 then
                        .errors += ["repo に、同じ名前「\($n)」の別のレイアウトがあります (uuid: \($same | join("、")))。エディターで名前を変えてから取り込んでください。"]
                      else
                        .doc["custom-layouts"] += [$l] | .changed = true | .log += ["  \($n): 足した"]
                      end
                  end
              end
          end)' >"${work_dir}/import.json"
  errors=$(jq -r '.errors[]' "${work_dir}/import.json")
  if [[ -n ${errors} ]]; then
    while IFS= read -r line; do
      fail "${line}"
    done <<<"${errors}"
    echo "   何も取り込んでいません。" >&2
    return 1
  fi
  log=$(jq -r '.log[]' "${work_dir}/import.json")
  changed=$(jq -r '.changed' "${work_dir}/import.json")
  if [[ ${changed} != true ]]; then
    echo "取り込むものはありません (repo と同じです)。"
    printf '%s\n' "${log}"
    return 0
  fi
  # 名前を変えて取り込んだときなど、全体で誤りが無いか (name の重なり) を確かめてから書く
  problems=$(jq -r "${layouts_lib}"'.doc | layout_problems' "${work_dir}/import.json")
  if [[ -n ${problems} ]]; then
    fail "取り込むと ${layouts_rel} に誤りができるので、取り込めません:" "${problems}"
    return 1
  fi
  tmp="${layouts_file}.dotfiles-tmp"
  if ! body=$(jq '.doc' "${work_dir}/import.json" | to_pt_form) \
    || ! printf '%s' "${body}" 2>/dev/null >"${tmp}" || ! mv -f -- "${tmp}" "${layouts_file}" 2>/dev/null; then
    rm -f -- "${tmp}" 2>/dev/null || true
    fail "${layouts_rel} に書けませんでした: ${layouts_file}"
    return 1
  fi
  echo "==> PC のレイアウトを ${layouts_rel} へ取り込みました"
  printf '%s\n' "${log}"
  echo "git -C ${repo_dir} diff -- ${layouts_rel} で見て commit してください。"
  echo "push すると、ほかの PC には次の setup --update で足されます (その PC で直していたものは、書き換えずに知らせます)。"
}

# ---- 全体の設定 ----

# 全体の設定で FancyZones がオフなら、効かないことを知らせる。読みかけに当たっても読めるよう、5 回まで見る。
# キーやファイルが無ければオン (FancyZones は既定でオン)
check_enabled() {
  local i state
  [[ -e ${global_json} ]] || return 0
  for ((i = 0; i < 5; i++)); do
    if state=$(jq -r '.enabled.FancyZones' "${global_json}" 2>/dev/null) && [[ -n ${state} ]]; then
      if [[ ${state} == false ]]; then
        warn "FancyZones がオフなので、FancyZones の設定は効きません (全体の設定の enabled.FancyZones が false。${global_json})。" \
          "自動ではオンにしません。使うなら、PowerToys の設定画面で「ウィンドウとレイアウト」→「FancyZones」をオンにしてください。オンにすると、書いてある設定を読みます。"
      fi
      return 0
    fi
    sleep 1
  done
  warn "PowerToys の全体の設定を読めないので、FancyZones がオンかを確かめられません: ${global_json}"
}

if ((import_mode)); then
  import_layouts || exit 1
  exit 0
fi

sync_settings
sync_layouts
sync_default_layout
assign_layouts
check_enabled
exit 0
