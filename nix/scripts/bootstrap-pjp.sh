#!/usr/bin/env bash
# shellcheck shell=bash
#
# claude-skills の Rust の道具の入口 (shim) を pjp-skills として入れ、clone の道具を作る (pjp-skills --build)。
#
# order: 55
# tool: claudePrivateSkills (dotfiles.claude.privateSkills.enable)
#
# ^ setup.sh が読む実行順と道具の名前。bootstrap-claude-skills.sh (order 50。claude-skills の clone を取得し、場所を
#   ~/.local/state/dotfiles/claude-skills-dir に書く) の後に流す。claude-skills を使わないホスト (設定グループで off) では、
#   setup はこの手順を飛ばす。
#
# ## 何をするか
#
# claude-skills は skill の script を Rust に移している (claude-skills の docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md
# の §6.3・§9)。道具は `pjp <道具> …` で打つ。入口の pjp は公開の dotfiles の道具 (nix/pkgs/pjp-tools。home-manager が入れる) で、
# hub・child・mark・pack のほかは claude-skills の shim (pjp-skills) に渡す (dotfiles-private の ADR 124)。shim は clone の
# rust-toolchain.toml の版で `cargo build` してから道具を起こす (clone を pull すれば、次の呼び出しから新しいコードで動く)。ここでは、
# その shim を pjp-skills の名前で入れ、clone の道具を作っておく。
#
#   1. clone を決める (--dir → PJP_SKILLS_DIR → bootstrap-claude-skills.sh が書いた claude-skills-dir。相対パスは今の dir から
#      読んで絶対パスにする)。決まらない・clone に Rust の道具が無い (crates/pjp-shim が無い。claude-skills の W0-1 より前) なら、
#      何もしない
#   2. 前の shim を外す: 前の手順が cargo install で入れた ${CARGO_HOME:-~/.cargo}/bin/pjp (cargo の記録 .crates.toml に pjp-shim の
#      bin pjp がある) は、公開の入口 pjp を覆うので `cargo uninstall --root ${CARGO_HOME:-~/.cargo} pjp-shim` で外す (前の dotfiles が
#      bin を 2 つとも入れた形も、記録ごと外れる)。記録に無い bin/pjp (ほかのもの) は外さずに警告する
#   3. shim を入れる: ${CARGO_HOME:-~/.cargo}/bin/pjp-skills が無い・起きない・`pjp-skills --version` の版 (shim はどの bin の名前でも
#      「pjp <版>」と出す) が clone の crates/pjp-shim の Cargo.toml の版と違うときだけ、`cargo install --locked --root <使い捨ての
#      dir>/root --target-dir <使い捨ての dir>/target --path <clone>/crates/pjp-shim` を打ち、出来た bin (pjp-skills があればそれ、無ければ
#      pjp。clone の shim の crate の bin は、前の pjp だけ・pjp と pjp-skills・pjp-skills だけ、のどれか) を pjp-skills の名前で置く (shim は
#      argv[0] を読まないので、名前を替えても動く。shim の Cargo.toml の決まり: shim の動きを変えたら版を上げる)。使い捨ての root に
#      入れるのは、<CARGO_HOME>/bin/pjp も cargo の記録も <CARGO_HOME> に残さないため。使い捨ての target dir は、workspace の target/ に
#      残った古い exe (GC root の無い devShell で作ったもの) を link し直さずに写すのを避け、いつも今の環境で作り直して link するため。
#      置いた後に shim が起きなければ警告して止まる
#   4. 道具を作る: `pjp-skills --build` (clone の `cargo build --release --locked --bins`)。会話の途中で道具を初めて打ったときに、
#      作り直しを待たせない。clone が変わっていなければ cargo の確かめだけで終わるので、毎回流す
#
# cargo は clone の中で、clone の rust-toolchain.toml の channel を RUSTUP_TOOLCHAIN にして打つ (shim と同じ。mise の rust が
# 対話のシェルに入れる RUSTUP_TOOLCHAIN や、cwd の設定に引きずられない)。cargo は $CARGO_HOME/bin → ~/.cargo/bin → PATH の順に探す
# (shim の locate_cargo と同じ。bootstrap-mise.sh の mise の rust が入れた rustup の proxy を、mise の shim より先に使う)。
#
# cargo が無い、または Linux でリンカの cc が無い (example-wsl など) ときは、claude-skills の nix の devShell (path:<clone>/nix。rustup と
# cc がある) の中で cargo install・uninstall を打つ (shim が道具を作るときと同じ判断)。devShell の cc で作った exe は devShell の glibc に
# 結ばれるので、devShell を ~/.local/state/dotfiles/pjp-shim-devshell の profile に残す (nix develop --profile が nix の GC root に
# 足す)。nix の GC で glibc が消えると shim が起きなくなるため。入れられたら、その profile の前の世代 (前の glibc の GC root) は
# nix-env --delete-generations old で消す (入れた shim は今の世代に結ばれている)。pjp-skills --build は shim が同じ判断をする (道具の
# devShell の GC root は clone の target/ の中)。
#
# ## 止まらない
#
# どこで落ちても警告して exit 0 する (setup.sh は手順が 1 つ落ちると残りを走らせない)。shim が無くても、claude-skills の skill は
# 今までどおり scripts/ の bash・Python で動く (Rust に移した道具は、shim が無ければ使えない)。

set -eu -o pipefail

state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/claude-skills-dir"
# shim を devShell で作ったときに残す devShell の profile (nix の GC root)
devshell_profile="${state_dir}/pjp-shim-devshell"

dir_arg=""
dry_run=0

usage() {
  cat <<'EOS'
claude-skills の Rust の道具の入口 (shim) を pjp-skills として入れ、clone の道具を作る (pjp-skills --build)。

使い方:
  bootstrap-pjp.sh              shim を (要れば) 入れ、pjp-skills --build を流す
  bootstrap-pjp.sh --dir <path> claude-skills の clone を指定する
  bootstrap-pjp.sh --dry-run    実行せず、走るコマンドを表示するだけ
  bootstrap-pjp.sh -h, --help   これ

clone の決まり方 (上から順に):
  1. --dir
  2. $PJP_SKILLS_DIR
  3. ~/.local/state/dotfiles/claude-skills-dir (bootstrap-claude-skills.sh が書く)

shim は ${CARGO_HOME:-~/.cargo}/bin/pjp-skills に入る。clone の crates/pjp-shim の版と違う・無い・起きないときだけ入れ直す。
前の手順が入れた ${CARGO_HOME:-~/.cargo}/bin/pjp (cargo の記録で pjp-shim のもの) は、公開の入口 pjp を覆うので外す。
どこで落ちても警告して正常終了する (claude-skills の skill は、shim が無くても scripts/ のまま動く)。
EOS
}

note() {
  printf '  %s\n' "$*"
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

# clone の場所を出す (ある dir は絶対パスにする。cargo と nix は clone の中で打つので、相対パスのままだと先が変わる)。
# 決まらなければ 1
resolve_dir() {
  local d=""
  if [[ -n ${dir_arg} ]]; then
    d=${dir_arg}
  elif [[ -n ${PJP_SKILLS_DIR:-} ]]; then
    d=${PJP_SKILLS_DIR}
  elif [[ -r ${state_file} ]]; then
    d=$(head -n 1 "${state_file}")
  fi
  [[ -n ${d} ]] || return 1
  if [[ -d ${d} ]]; then
    d=$(cd -- "${d}" && pwd -P) || return 1
  fi
  printf '%s' "${d%/}"
}

# TOML のファイル $1 の [$2] の $3 = "<値>" の値を出す (無ければ何も出さない)。素の 1 行の文字列だけを読む
# (rust-toolchain.toml の channel と Cargo.toml の version。どちらもそう書く決まり)
toml_string() {
  awk -v section="$2" -v key="$3" '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ {
      name = $0
      sub(/^[[:space:]]*\[[[:space:]]*/, "", name)
      sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", name)
      in_section = (name == section)
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\"" {
      v = $0
      sub(/^[^"]*"/, "", v)
      sub(/".*$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# 使う cargo のパスを出す ($CARGO_HOME/bin → ~/.cargo/bin → PATH)。無ければ 1
locate_cargo() {
  local c
  for c in ${CARGO_HOME:+"${CARGO_HOME}/bin/cargo"} "${HOME}/.cargo/bin/cargo"; do
    if [[ -f ${c} && -x ${c} ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  command -v cargo
}

# 入れてある shim の版 (`pjp-skills --version` の「pjp <版>」の版。shim は bin の名前によらず pjp と出す) を出す。無い・起きないときは 1
installed_version() {
  local out
  [[ -x ${shim} ]] || return 1
  out=$("${shim}" --version 2>/dev/null) || return 1
  [[ ${out} == "pjp "* ]] || return 1
  printf '%s' "${out#pjp }"
}

echo "==> claude-skills の clone"
if ! clone=$(resolve_dir); then
  note "claude-skills の clone の場所が決まりません (bootstrap-claude-skills.sh が取得できていない)。飛ばします。"
  exit 0
fi
note "${clone}"
if [[ ! -f ${clone}/crates/pjp-shim/Cargo.toml ]]; then
  note "この clone には Rust の道具 (crates/pjp-shim) がまだありません。飛ばします (claude-skills を pull すると入ります)。"
  exit 0
fi

channel=$(toml_string "${clone}/rust-toolchain.toml" toolchain channel 2>/dev/null) || channel=""
want=$(toml_string "${clone}/crates/pjp-shim/Cargo.toml" package version 2>/dev/null) || want=""
if [[ ! ${channel} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  warn "claude-skills の rust-toolchain.toml の [toolchain] の channel を読めません: ${clone}/rust-toolchain.toml" \
    "shim を入れず、道具も作りません。"
  exit 0
fi
if [[ ! ${want} =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
  warn "claude-skills の crates/pjp-shim/Cargo.toml の [package] の version を読めません: ${clone}/crates/pjp-shim/Cargo.toml" \
    "shim を入れず、道具も作りません。"
  exit 0
fi
note "toolchain ${channel}・shim ${want}"

# claude-skills の shim の置き場。入口の pjp は公開の dotfiles の道具 (nix/pkgs/pjp-tools) なので、shim は pjp-skills の名前で置き、
# <CARGO_HOME>/bin/pjp は置かない (PATH で公開の pjp を覆うため。dotfiles-private の ADR 124)
cargo_root="${CARGO_HOME:-${HOME}/.cargo}"
shim="${cargo_root}/bin/pjp-skills"
# 前の手順が cargo install で入れた shim (bin pjp)
old_shim="${cargo_root}/bin/pjp"

# devShell で cargo を打つか: cargo が無い、または Linux でリンカの cc が無い (shim が道具を作るときと同じ判断)。わけを in_nix に入れる
cargo=$(locate_cargo) || cargo=""
in_nix=""
if [[ -z ${cargo} ]]; then
  in_nix="cargo が見つかりません"
elif [[ $(uname -s) == Linux ]] && ! command -v cc &>/dev/null; then
  in_nix="リンカの cc が見つかりません"
fi

# cargo を打てるか (cargo か、devShell の nix と claude-skills の nix/flake.nix がある)
can_cargo() {
  [[ -z ${in_nix} ]] || { command -v nix &>/dev/null && [[ -f ${clone}/nix/flake.nix ]]; }
}

# cargo の引数 $@ を clone の中で、clone の channel を RUSTUP_TOOLCHAIN にして打つ (devShell なら --profile の devShell の中で。devShell を
# GC root に残す)。落ちたら 1
run_cargo() {
  if [[ -z ${in_nix} ]]; then
    (cd "${clone}" && run env RUSTUP_TOOLCHAIN="${channel}" "${cargo}" "$@")
    return
  fi
  if [[ ${dry_run} == 0 ]] && ! mkdir -p "${state_dir}"; then
    warn "devShell の profile を置く dir を作れません: ${state_dir}"
    return 1
  fi
  (cd "${clone}" && run nix develop --profile "${devshell_profile}" "path:${clone}/nix" --command \
    env RUSTUP_TOOLCHAIN="${channel}" cargo "$@")
}

# <CARGO_HOME>/bin/pjp が、前の手順が cargo install で入れた claude-skills の shim か (cargo の記録 .crates.toml に、pjp-shim の bin pjp がある)
old_shim_recorded() {
  local f="${cargo_root}/.crates.toml"
  [[ -r ${f} ]] || return 1
  grep -Eq '^"pjp-shim [^"]*" = \[[^]]*"pjp"' "${f}"
}

echo "==> 前の shim (${old_shim})"
if [[ ! -e ${old_shim} && ! -L ${old_shim} ]]; then
  note "ありません"
elif ! old_shim_recorded; then
  warn "${old_shim} は claude-skills の shim と確かめられないので外しません (cargo の記録 ${cargo_root}/.crates.toml に pjp-shim の bin pjp が無い)。" \
    "PATH で公開の入口 pjp (Nix の profile) より前に来ると覆うので、要らなければ消してください。"
elif ! can_cargo; then
  warn "${in_nix}。nix (か claude-skills の nix/flake.nix) も無いので、前の shim ${old_shim} を外せません。" \
    "公開の入口 pjp を覆うので、cargo uninstall --root ${cargo_root} pjp-shim で外してください。"
else
  note "前の手順が cargo install で入れた claude-skills の shim です。公開の入口 pjp を覆わないよう外します"
  [[ -z ${in_nix} ]] || note "${in_nix}。claude-skills の nix の devShell (path:${clone}/nix) の中で外します"
  if ! run_cargo uninstall --root "${cargo_root}" pjp-shim; then
    warn "前の shim を外せませんでした (上の cargo のエラー): ${old_shim}" \
      "公開の入口 pjp を覆うので、cargo uninstall --root ${cargo_root} pjp-shim で外してください。"
  fi
fi

echo "==> claude-skills の shim (${shim})"
have=$(installed_version) || have=""
if [[ ${have} == "${want}" ]]; then
  note "${shim} は ${want} のまま"
else
  if [[ -n ${have} ]]; then
    note "${shim} は ${have}。clone の ${want} に入れ直します"
  elif [[ -e ${shim} ]]; then
    note "${shim} が起きません (devShell で作った shim の glibc が nix の GC で消えたなど)。入れ直します"
  else
    note "${shim} がありません。入れます"
  fi
  if ! can_cargo; then
    warn "${in_nix}。nix (か claude-skills の nix/flake.nix) も無いので、claude-skills の shim を入れられません。道具も作りません。" \
      "rustup は bootstrap-mise.sh が mise の rust で入れます (dotfiles.claude.privateSkills.enable のホスト)。入れてから流し直してください: $0"
    exit 0
  fi
  # shim は使い捨ての root と target dir で毎回作り直して link し、出来た exe を pjp-skills の名前で置く。cargo install --path は既定で
  # workspace の target/ を使い、fingerprint が新しい exe を link し直さずに写すので、前に別の devShell (GC root の無いもの) で作った exe が
  # 残っていると、起きない shim をまた入れてしまう。使い捨ての root に入れるのは、clone の shim の crate の bin がどの形 (前の pjp だけ・
  # pjp と pjp-skills・pjp-skills だけ) でも <CARGO_HOME>/bin/pjp を置かず、cargo の記録も <CARGO_HOME> に残さないため
  if [[ ${dry_run} == 1 ]]; then
    work_dir="<使い捨ての dir>"
  elif ! work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pjp-shim.XXXXXX") || ! mkdir -p "${work_dir}/root" "${work_dir}/target"; then
    warn "shim を作る一時の dir を作れません (TMPDIR: ${TMPDIR:-/tmp})。shim を入れず、道具も作りません。"
    exit 0
  else
    trap 'rm -rf -- "${work_dir}"' EXIT
  fi
  [[ -z ${in_nix} ]] || note "${in_nix}。claude-skills の nix の devShell (path:${clone}/nix) の中で入れます"
  if ! run_cargo install --locked --root "${work_dir}/root" --target-dir "${work_dir}/target" --path "${clone}/crates/pjp-shim"; then
    if [[ -n ${in_nix} ]]; then
      warn "claude-skills の shim を nix の devShell で入れられませんでした (上の nix・cargo のエラー): ${clone}/crates/pjp-shim" \
        "道具も作りません。直してから流し直してください: $0"
    else
      warn "claude-skills の shim を入れられませんでした (上の cargo のエラー): ${clone}/crates/pjp-shim" \
        "道具も作りません。直してから流し直してください: $0"
    fi
    exit 0
  fi
  # 入れた shim は今の世代の devShell に結ばれている。前の世代 (前の glibc の GC root) は要らないので消す (消せなくても止めない)
  if [[ -n ${in_nix} && ${dry_run} == 0 ]] && command -v nix-env &>/dev/null; then
    nix-env --profile "${devshell_profile}" --delete-generations old &>/dev/null || true
  fi
  if [[ ${dry_run} == 1 ]]; then
    built="${work_dir}/root/bin/<pjp-skills か pjp>"
  elif [[ -e ${work_dir}/root/bin/pjp-skills ]]; then
    built="${work_dir}/root/bin/pjp-skills"
  else
    built="${work_dir}/root/bin/pjp"
  fi
  if [[ ${dry_run} == 0 && ! -e ${built} ]]; then
    warn "入れたはずの shim が見つかりません: ${work_dir}/root/bin (pjp-skills も pjp も無い)" "道具は作りません。"
    exit 0
  fi
  if ! run mkdir -p "${cargo_root}/bin" || ! run cp -f "${built}" "${shim}.new" || ! run mv -f "${shim}.new" "${shim}"; then
    warn "claude-skills の shim を置けませんでした: ${shim}" "道具は作りません。"
    exit 0
  fi
  if [[ ${dry_run} == 0 ]]; then
    if ! have=$(installed_version); then
      warn "置いた shim が起きません: ${shim}" "道具は作りません。"
      exit 0
    elif [[ ${have} != "${want}" ]]; then
      warn "置いた shim の版 (${have}) が clone の版 (${want}) と違います: ${shim}"
    fi
  fi
fi

echo "==> 道具を作る (pjp-skills --build)"
if ! run env PJP_SKILLS_DIR="${clone}" "${shim}" --build; then
  warn "claude-skills の道具を作れませんでした (上の cargo のエラー): ${clone}" \
    "道具は、初めて打ったときに shim が作り直します。直してから流し直してください: $0"
  exit 0
fi

echo
echo "完了しました。道具は pjp <道具> … で打てます (入口は公開の pjp。claude-skills の道具は pjp-skills に渡る。一覧: pjp-skills --help)。"
