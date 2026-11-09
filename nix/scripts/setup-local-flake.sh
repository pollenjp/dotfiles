#!/usr/bin/env bash
# shellcheck shell=bash
#
# ~/dotfiles にローカル専用の flake を用意する (git 管理外)。冪等。
#
# ## 置き場所の前提
#
#   リポジトリ本体  ~/ghq/github.com/pollenjp/dotfiles  git 管理
#   ローカル flake  ~/dotfiles                          git 管理外
#
# ~/ghq は ghq root の既定値。GHQ_ROOT や git config ghq.root で変えていれば
# そちらを使う (下の ghq_root() が判定する)。ghq 本体は Nix が入れるものなので、
# 初回はまだ PATH に無い前提で書いてある。
#
# リポジトリは ghq が決めるパスに置く。`cdrepo` など ghq 前提の仕組みと
# 置き場所が揃い、他のリポジトリと同じ規則で辿れるため。
# 一方で日々叩くパスは短く固定したいので、~/dotfiles を「常にここから
# 実行する入口」として別に用意する。
#
# ## ~/dotfiles に置くもの
#
#   flake.nix   本体を input として取り込み、homeConfigurations を再輸出する。
#               このマシンだけのホスト (tmp など) をここに書ける。
#               dotfiles-private の nix/ を 2 つ目の path: の入力 (inputs.dotfiles-private。flake = false) に取り、
#               そこに登録した PC のホスト (nix/hosts/<user>@<hostname>.nix) を登録簿のホストに重ねる (ADR 026)。
#               指す先は private-host.sh input-dir が決める: clone の nix/ があればそこ、無ければ本体の空の stub
#               (nix/private-stub)。clone ができたら local-flake-migrate.sh prepare が指し直す。heredoc の展開は
#               ${nix_dir}・${private_nix_dir}・${template_id} だけ (local-flake-migrate.sh が同じ展開を真似て描く。
#               足すならあちらも)。
#               雛形は、登録簿のホストに当てる「このマシンだけの設定」(前の雛形の local) を持たない (ADR 027)。
#               PC の値は、dotfiles-private の登録 (登録した PC) か、ここに足す tmp (登録していない PC) の
#               どちらか 1 か所にだけ書く。tmp の例 (コメント) は値を mkHome の引数と modules に直に書く
#               (mkForce は要らない)。有効な行は WSL・1Password・Dev Tracker (true)・Notion の宛先で、
#               gitViaGh・Notion の routes と override・解説動画の autoStart・cc-pages の port は、例の中の
#               コメントに置く。例を直したら nix/tests/fixtures/local-flake-tmp/tmp.nix も同じに直す
#               (setup-local-flake.test.sh が比べ、local-flake-tmp-state がそれを評価する)。WSL の PC で描くと、
#               例の windowsUserName にはその PC の名前が入る (下の「tmp の例の Windows のユーザー名」)。
#               先頭のコメントに「# 雛形の版: <印>」を置く。印は下の heredoc の原文 (展開する前) から
#               local-flake-migrate.sh id が計算する値で、heredoc を直すと変わる。
#   flake.lock  nix が生成する。
#   setup       setup.sh への symlink。更新は `~/dotfiles/setup --update`。
#
# ## 初期用のホスト initial (--initial)
#
# SSH 鍵 (1Password) も gh のログインもまだ無い新しい WSL の PC で、Windows のアプリまで入れるための踏み台。
# --initial を付けると、雛形を描いたあとで、tmp の例の終わり (「        # };」の行) の後ろに次の塊を差し込む
# (雛形の heredoc は変えない。変えると雛形の版の印が変わり、全 PC に移す知らせが出るため。ADR 024)。
#
#   initial = dotfiles.lib.mkHome {
#     username = "<$USER>";  system = "<private-host.sh system>";
#     wsl = { enable = true; windowsUserName = "<private-host.sh windows-user か --windows-user>"; windowsFiles.enable = true; };
#   };
#
# setup はローカル flake の一番上のホストを既定の対象ホストにするので、initial で当たる。dotfiles-private に登録して merge
# したら、--force で作り直して外す (initial のほかに手で足した値の無い雛形なので、作り直せば clone の nix/ を読む形になる)。
#
#   - flake.nix が無い・--force: 描いて差し込む。initial が既にある: 触らない。今の雛形のまま (local-flake-migrate.sh render と、
#     tmp の例の Windows のユーザー名のほかは 1 バイトも違わない): 差し込んで書き直す。それ以外 (手を入れた): 書かずに 1 で、
#     手で足す塊を出す
#   - 書く前に確かめる: Windows のユーザー名が引ける (WSL でなければ private-host.sh が止める)・<Windows のユーザーの
#     フォルダの親 (DOTFILES_WINDOWS_USERS_DIR。既定 /mnt/c/Users)>/<名前> がある・名前を Nix の文字列にそのまま書ける
#     (" \ $ と制御文字が無い)。pwsh.exe (PowerShell 7) が無ければ警告する (setup の Windows の手順が pwsh.exe で流すため)
#
# ## tmp の例の Windows のユーザー名
#
# 雛形を描くとき (flake.nix が無い・--force・--initial) は、WSL の PC なら、描いたあとで tmp の例 (コメント) の
# windowsUserName の行 (「        #     windowsUserName = "alice";」) の名前を、その PC の Windows のユーザー名に置き換える。
# 行はコメントのまま (行頭の # は外さない)。雛形の heredoc は変えない (initial の塊と同じく、雛形の版の印を変えないため)。
#
#   - 名前の引き方と確かめ方は initial と同じ (private-host.sh windows-user・<DOTFILES_WINDOWS_USERS_DIR>/<名前> がある・
#     Nix の文字列に書ける)。--initial のときは initial に書く名前 (--windows-user で渡した名前も) をそのまま使い、引き直さない
#   - 決まらなくても止めない (例は作り物の名前のまま)。WSL の PC で決まらなければ (interop の不調・フォルダが無い など)、
#     わけを 1 行出す (例はコメントなので、setup の警告のまとめには載せない)。WSL でない PC では何も言わない
#   - 名前の入った例は、手を入れたと見ない: --initial が今の雛形のままかを見るときは、同じ名前を入れて描いたものと比べる
#     (local-flake-migrate.sh render --windows-user)。local-flake-migrate.sh prepare は、手元の例の名前を元の雛形と今の
#     雛形にも入れてから 3-way merge する。行の形は local-flake-migrate.sh も同じものを見る (直すならあちらも)
#
# ## 雛形が新しくなったら
#
# 既にある flake.nix は、雛形が変わっても触らない (--force は作り直すので、手で足したホストと、前の雛形なら
# local に書いた値が消える)。印が今の雛形と違えば (印の無い、印を入れる前の雛形も)、ここと setup.sh が知らせる。
# 値を引き継いで今の雛形へ移すのは local-flake-migrate.sh (手順は nix/README.md「雛形が新しくなったら」。
# Claude Code なら pjp-dotfiles-local-flake-migrate skill)。
#
# ## なぜ本体の git 管理下に置かないのか
#
# 一時的な検証マシンの定義を登録簿 (hosts/default.nix) に混ぜたくない。
# また flake の input は絶対パスでしか書けず、ghq root はマシンごとに
# 異なりうるので、このファイル自体がマシン固有になる。
#
# ## なぜ path: を使うのか
#
# `path:` は git を介さずディレクトリをそのまま複製するので、**commit して
# いない変更もそのまま試せる**。
#
# ただし いまの nix (Determinate 3.21.9 / 2.34 で実測) は path: 入力を
# **narHash で厳密に lock する**ので、本体を編集すると flake.lock が合わなくなり
# 評価が NAR hash mismatch で落ちる。張り直しは setup.sh が switch の前に行う
# (sync_local_flake_lock)。手で直すなら:
#
#   nix flake update dotfiles --flake ~/dotfiles
#
# `nix flake lock` では直らない (同じエラーになる)。
#
# 対して `--flake <repo>/nix` のように git リポジトリ内のパスを直接指すと
# git 解決になり、**追跡済みファイルしか見えない**。CI はこちらなので、
# 手元で通っても commit を忘れると CI で落ちる点だけ注意する。

set -eu -o pipefail

repo_path_suffix="github.com/pollenjp/dotfiles"
local_dir=${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}
users_dir=${DOTFILES_WINDOWS_USERS_DIR:-/mnt/c/Users}
force=0
initial=0
initial_windows_user=""

usage() {
  cat <<'EOS'
~/dotfiles にローカル専用の flake を用意する (git 管理外)。

使い方:
  setup-local-flake.sh           用意する (既にあれば触らない)
  setup-local-flake.sh --force   flake.nix を作り直す
  setup-local-flake.sh --initial [--windows-user <名前>]
                                 初期用のホスト initial を書く (SSH 鍵も gh のログインもまだの、新しい WSL の PC)。
                                 Windows のユーザー名は引く (--windows-user で渡せる)。--force と一緒なら作り直して書く
  setup-local-flake.sh -h        これ

  flake.nix を描くとき、WSL の PC なら、tmp の例 (コメント) の windowsUserName に Windows のユーザー名を入れる
  (--initial なら initial と同じ名前。引けなければ作り物の名前のまま)。

環境変数:
  DOTFILES_LOCAL_DIR          ローカル flake の場所 (既定: ~/dotfiles)
  DOTFILES_ALLOW_ANY_PATH     1 なら ghq のパス確認を警告だけにする
  DOTFILES_WINDOWS_USERS_DIR  Windows のユーザーのフォルダの親 (既定: /mnt/c/Users。テスト用)
EOS
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1 ;;
    --initial) initial=1 ;;
    --windows-user)
      if [[ $# -lt 2 || -z $2 ]]; then
        echo "--windows-user に Windows のユーザー名を渡してください  (--help)" >&2
        exit 1
      fi
      initial_windows_user=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "知らないオプション: $1  (--help)" >&2
      exit 1
      ;;
  esac
  shift
done

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
  printf '!! %s\n' "$*" >&2
  exit 1
}

if [[ -n ${initial_windows_user} && ${initial} == 0 ]]; then
  die "--windows-user は --initial と一緒に使います。"
fi

# Nix の文字列 ("…") にそのまま書けるか (" \ $ と制御文字が無い)
nix_string_ok() {
  [[ $1 != *[\"\\\$]* && ! $1 =~ [[:cntrl:]] ]]
}

# 初期用のホスト initial に書く値 (initial_username・initial_system・initial_windows_user) を決めて確かめる (--initial)。
# 決まらなければ理由を出して exit 1 (ローカル flake には何も書かない)。pwsh.exe が無ければ警告だけする
initial_values() {
  local d n cand=""
  initial_username=${USER:-$(id -un 2>/dev/null || true)}
  initial_system=$("${BASH}" "${script_dir}/private-host.sh" system) \
    || die "この PC の system を決められません (${script_dir}/private-host.sh system)。"
  if [[ -n ${initial_windows_user} ]]; then
    # 名前を渡されたときも、WSL でなければ止める (Windows の区画を /mnt/c に mount した Linux に WSL の値を書かない)
    if ! "${BASH}" "${script_dir}/private-host.sh" is-wsl; then
      printf '!! 初期用のホスト initial は、新しい WSL の PC 用です。WSL でない PC は、--host <型> か ~/dotfiles/flake.nix の tmp で当てる (nix/README.md「新規マシンの手順」)。\n' >&2
      exit 1
    fi
  else
    if ! initial_windows_user=$("${BASH}" "${script_dir}/private-host.sh" windows-user); then
      {
        printf '!! Windows のユーザー名を引けないので、初期用のホスト initial を書けません (わけは上)。\n'
        printf '   WSL の PC なら、名前を渡して打ち直す: %s --initial --windows-user <名前>\n' "${script_dir}/setup-local-flake.sh"
        printf '   WSL でない PC は、--host <型> か ~/dotfiles/flake.nix の tmp で当てる (nix/README.md「新規マシンの手順」)。\n'
      } >&2
      exit 1
    fi
  fi
  if [[ -z ${initial_username} ]] || ! nix_string_ok "${initial_username}"; then
    die "この PC のユーザー名 (${initial_username:-空}) を、Nix の文字列に書けません (\" \\ \$ と制御文字は書けない)。"
  fi
  if ! nix_string_ok "${initial_windows_user}"; then
    die "Windows のユーザー名 (${initial_windows_user}) に、Nix の文字列に書けない文字 (\" \\ \$ と制御文字) があります。"
  fi
  if [[ ! -d ${users_dir}/${initial_windows_user} ]]; then
    for d in "${users_dir}"/*/; do
      [[ -d ${d} ]] || continue
      n=${d%/}
      n=${n##*/}
      case ${n} in
        Public | Default | "Default User" | "All Users") continue ;;
      esac
      cand+="${cand:+, }${n}"
    done
    {
      printf '!! %s がありません (Windows のユーザー名 %s)。初期用のホスト initial を書けません。\n' \
        "${users_dir}/${initial_windows_user}" "${initial_windows_user}"
      printf '   %s の中: %s\n' "${users_dir}" "${cand:-(見当たりません)}"
      printf '   ユーザーのフォルダの名前が違うなら、フォルダの名前を渡して打ち直す: %s --initial --windows-user <フォルダの名前>\n' \
        "${script_dir}/setup-local-flake.sh"
    } >&2
    exit 1
  fi
  if ! command -v pwsh.exe &>/dev/null; then
    warn "pwsh.exe (PowerShell 7) が見つかりません。setup の Windows の手順 (bootstrap-windows-*) は pwsh.exe で流すので、先に Windows で入れてください:" \
      "winget install --id Microsoft.PowerShell --exact --source winget"
  fi
}

# 初期用のホスト initial の塊 (先頭の空行・コメント 3 行・mkHome)。字下げは 8 桁 (雛形の homeConfigurations の中)
initial_block() {
  cat <<EOB

        # 初期用のホスト (setup-local-flake.sh --initial が書いた)。SSH 鍵 (1Password) も gh のログインもまだ無い
        # 新しい WSL の PC で、win/ を配り、Windows のアプリを winget で入れる。dotfiles-private に登録して merge したら、
        # setup-local-flake.sh --force で作り直して外す (nix/README.md「新しい WSL の PC」)。
        initial = dotfiles.lib.mkHome {
          username = "${initial_username}";
          system = "${initial_system}";
          wsl = {
            enable = true;
            windowsUserName = "${initial_windows_user}";
            windowsFiles.enable = true;
          };
        };
EOB
}

# ローカル flake ($1) に initial のホストがあるか (コメントでない「initial = …mkHome」の行。setup.sh の parse_hosts と同じ見方)
has_initial_host() {
  grep -qE '^[[:space:]]*initial[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome' "$1"
}

# ローカル flake ($1) の initial の塊の windowsUserName の値 (読めなければ空)
initial_windows_user_of() {
  awk '
    /^[[:space:]]*initial[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome/ { f = 1 }
    f && /^[[:space:]]*windowsUserName[[:space:]]*=/ {
      v = $0
      sub(/^[^"]*"/, "", v)
      sub(/";[[:space:]]*$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# $1 (描いたばかりの雛形) の tmp の例の終わり (「        # };」の行) の後ろに、initial の塊を差し込む。
# 目印がちょうど 1 行でなければ 1 (書き換えない)
insert_initial_block() {
  local f=$1 n
  n=$(grep -cxF '        # };' "${f}") || n=0
  [[ ${n} == 1 ]] || return 1
  initial_block >"${f}.block"
  awk -v blockfile="${f}.block" '
    { print }
    $0 == "        # };" {
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
    }
  ' "${f}" >"${f}.new"
  rm -f "${f}.block"
  mv "${f}.new" "${f}"
}

# 雛形の tmp の例の、Windows のユーザー名の行 (「        #     windowsUserName = "<名前>";」。コメント)。雛形の heredoc の中に
# ちょうど 1 行あり、initial の塊の windowsUserName (字下げが違い、# が無い) には当たらない。local-flake-migrate.sh
# (render --windows-user・prepare) も同じ形の行を見る (直すならあちらも)。
#
# $1 の tmp の例の Windows のユーザー名を出す。その行がちょうど 1 行でなければ 1
example_windows_user_of() {
  awk '
    /^        #     windowsUserName = "[^"]*";$/ {
      n++
      v = $0
      sub(/^[^"]*"/, "", v)
      sub(/";$/, "", v)
    }
    END {
      if (n != 1) exit 1
      print v
    }
  ' "$1"
}

# $1 (描いたばかりの雛形) の tmp の例の Windows のユーザー名を $2 にする (行はコメントのまま)。その行がちょうど 1 行で
# なければ 1 (書き換えない)
set_example_windows_user() {
  local f=$1
  example_windows_user_of "${f}" >/dev/null || return 1
  NAME=$2 awk '
    /^        #     windowsUserName = "[^"]*";$/ { print "        #     windowsUserName = \"" ENVIRON["NAME"] "\";"; next }
    { print }
  ' "${f}" >"${f}.example"
  mv "${f}.example" "${f}"
}

# 雛形の tmp の例に入れる Windows のユーザー名を example_windows_user に決める (雛形を描くとき)。--initial なら initial に書く
# 名前をそのまま使う (引き直さない)。ほかは WSL の PC のときだけ、initial と同じ引き方・確かめ方で決める。決まらなければ空に
# し、WSL の PC ならわけを example_user_note に入れる (止めない。例は作り物の名前のまま)。WSL でなければ何も入れない
example_user_values() {
  local u
  example_windows_user=""
  example_user_note=""
  if [[ ${initial} == 1 ]]; then
    example_windows_user=${initial_windows_user}
    return 0
  fi
  "${BASH}" "${script_dir}/private-host.sh" is-wsl 2>/dev/null || return 0
  if ! u=$("${BASH}" "${script_dir}/private-host.sh" windows-user 2>/dev/null); then
    # shellcheck disable=SC2016 # 文面の $env:USERNAME は PowerShell の変数の名前
    example_user_note='Windows のユーザー名を引けない。pwsh.exe・powershell.exe の $env:USERNAME が返らない。WSL の interop を確かめる'
  elif ! nix_string_ok "${u}"; then
    example_user_note="Windows のユーザー名に、Nix の文字列に書けない文字 (\" \\ \$ と制御文字) がある"
  elif [[ ! -d ${users_dir}/${u} ]]; then
    example_user_note="Windows のユーザー名 ${u} のフォルダ ${users_dir}/${u} が無い"
  else
    example_windows_user=${u}
  fi
}

# 既にある flake.nix ($1) が今の雛形のまま (手を入れていない) か。local-flake-migrate.sh render と 1 バイトも違わなければ 0。
# tmp の例の Windows のユーザー名 (WSL の PC で描くと入る) は違ってよい (同じ名前を入れて描いたものと比べる)
template_as_is() {
  local name
  name=$(example_windows_user_of "$1") || name=""
  "${BASH}" "${migrate}" render --file "${script_dir}/setup-local-flake.sh" --nix-dir "${nix_dir}" \
    --private-dir "${private_nix_dir}" ${name:+--windows-user "${name}"} 2>/dev/null | cmp -s - "$1"
}

# $0 が symlink (~/dotfiles/setup など) 経由でも実体の場所を返す。
# macOS の readlink には -f が無いので手で辿る。
resolve_dir() {
  local src=$1 dir
  while [[ -L ${src} ]]; do
    dir=$(
      cd -P -- "$(dirname -- "${src}")" &>/dev/null
      pwd
    )
    src=$(readlink -- "${src}")
    case ${src} in
      /*) ;;
      *) src="${dir}/${src}" ;;
    esac
  done
  cd -P -- "$(dirname -- "${src}")" &>/dev/null
  pwd
}

script_dir=$(resolve_dir "$0")
nix_dir=$(dirname "${script_dir}")
repo_dir=$(dirname "${nix_dir}")

# ghq root は ghq 本体が無くても決める。この手順は Nix 導入直後、
# まだ ghq が PATH に無い状態でも走りうるため。
# 優先順位は ghq 自身の規則に合わせる。
ghq_root() {
  local root
  if command -v ghq &>/dev/null && root=$(ghq root 2>/dev/null | head -n 1) && [[ -n ${root} ]]; then
    printf '%s' "${root}"
    return 0
  fi
  if [[ -n ${GHQ_ROOT:-} ]]; then
    printf '%s' "${GHQ_ROOT}"
    return 0
  fi
  if command -v git &>/dev/null && root=$(git config --get ghq.root 2>/dev/null) && [[ -n ${root} ]]; then
    # git config の値は ~ が展開されないまま入りうるので手で開く。
    # shellcheck disable=SC2088  # 展開ではなく "~" で始まる文字列の照合
    case ${root} in
      "~") root=${HOME} ;;
      "~/"*) root="${HOME}/${root#\~/}" ;;
    esac
    printf '%s' "${root}"
    return 0
  fi
  printf '%s' "${HOME}/ghq"
}

expected_repo="$(ghq_root)/${repo_path_suffix}"

echo "==> 置き場所の確認"
printf '  リポジトリ本体: %s\n' "${repo_dir}"
printf '  ghq が決める先: %s\n' "${expected_repo}"

if [[ ${repo_dir} != "${expected_repo}" ]]; then
  if [[ ${DOTFILES_ALLOW_ANY_PATH:-0} == 1 ]]; then
    warn "ghq のパスと違いますが DOTFILES_ALLOW_ANY_PATH=1 なので続けます。"
  else
    cat >&2 <<EOS
!! リポジトリが ghq の決めるパスにありません。

   いま:     ${repo_dir}
   あるべき: ${expected_repo}

   ghq 配下へ置き直してください。

     # 既存の作業を持ち越すなら移動が早い
     mkdir -p "$(dirname "${expected_repo}")"
     mv "${repo_dir}" "${expected_repo}"

     # 取り直すなら (ghq がまだ無ければ git clone。https / SSH はどちらでも)
     git clone https://github.com/pollenjp/dotfiles.git "${expected_repo}"
     ghq get https://github.com/pollenjp/dotfiles.git

   このパスのまま進めるなら DOTFILES_ALLOW_ANY_PATH=1 を付けてください。
EOS
    exit 1
  fi
fi

echo "==> ${local_dir}"

# 旧レイアウト (リポジトリそのものが ~/dotfiles) を壊さない。
if [[ ${repo_dir} == "${local_dir}" ]]; then
  die "${local_dir} はリポジトリ本体そのものです。先に ghq 配下へ移動してください。"
fi
if [[ -e ${local_dir} && ! -d ${local_dir} ]]; then
  die "${local_dir} がディレクトリではありません。"
fi
if git -C "${local_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
  die "${local_dir} は git の作業ツリーです。ローカル flake は git 管理外に置きます。"
fi

# 初期用のホスト initial の値は、ローカル flake に触る前に決めて確かめる (決まらなければ何も書かずに止まる)。
# initial が既にあれば (--force なし)、値を引きも確かめもしない (冪等。interop の不調で 2 回目が落ちないように)
if [[ ${initial} == 1 ]]; then
  if [[ ${force} == 0 && -f ${local_dir}/flake.nix ]] && has_initial_host "${local_dir}/flake.nix"; then
    :
  else
    initial_values
  fi
fi

mkdir -p "${local_dir}"

# 雛形の版の印を計算し、照合する道具 (この script の隣)。印は heredoc の原文から計算する
migrate="${script_dir}/local-flake-migrate.sh"
migrate_cmd="${migrate} prepare"
if [[ ${local_dir} != "${HOME}/dotfiles" ]]; then
  migrate_cmd+=" --flake ${local_dir}"
fi

# dotfiles-private の入力が指す先 (clone の nix/ か、無ければ本体の空の stub)。決め方は private-host.sh だけが持つ
private_nix_dir=$("${BASH}" "${script_dir}/private-host.sh" input-dir --nix-dir "${nix_dir}" 2>/dev/null) \
  || private_nix_dir="${nix_dir}/private-stub"

flake_file="${local_dir}/flake.nix"
write_flake=1
if [[ -f ${flake_file} && ${force} == 0 && ${initial} == 1 ]]; then
  # 初期用のホスト initial を書く: 既にあれば触らない。今の雛形のまま (手を入れていない) なら差し込んで書き直す
  write_flake=0
  if has_initial_host "${flake_file}"; then
    echo "  flake.nix: 初期用のホスト initial は既にあります (そのまま)"
    # 渡された --windows-user が今の値と違えば、使っていないことと変え方を出す
    current_user=$(initial_windows_user_of "${flake_file}")
    if [[ -n ${initial_windows_user} && ${initial_windows_user} != "${current_user}" ]]; then
      echo "    --windows-user ${initial_windows_user} は使っていません (今の initial の Windows のユーザー名: ${current_user:-読めない})。"
      echo "    変えるなら作り直す (手で足した値は消える): ${script_dir}/setup-local-flake.sh --force --initial --windows-user ${initial_windows_user}"
    fi
  elif template_as_is "${flake_file}"; then
    echo "  flake.nix: 今の雛形のままなので、初期用のホスト initial を差し込みます"
    write_flake=1
  else
    {
      printf '!! %s に手を入れてあるので (今の雛形のままではない)、初期用のホスト initial を書き込みません。\n' "${flake_file}"
      printf '   homeConfigurations の中 (tmp の例の後ろ) に、次の塊を手で足す:\n'
      initial_block
      printf '\n   作り直してよい (手で足した値は消える) なら: %s --force --initial\n' "${script_dir}/setup-local-flake.sh"
    } >&2
    exit 1
  fi
elif [[ -f ${flake_file} && ${force} == 0 ]]; then
  write_flake=0
  if grep -qF "\"path:${nix_dir}\"" "${flake_file}"; then
    echo "  flake.nix: 既にあります (そのまま)"
    # 雛形が変わっても既存のファイルには触らない。印が今の雛形と違えば、値を引き継いで移す道具を知らせる
    # (check は git も nix も使わない。調べられないとき (2) は黙る)。
    stale_rc=0
    stale=$("${BASH}" "${migrate}" check --flake "${local_dir}" 2>/dev/null) || stale_rc=$?
    if [[ ${stale_rc} == 1 ]]; then
      warn "flake.nix は前の雛形から作られています (雛形の版 ${stale})。" \
        "値を引き継いで今の雛形へ移す: ${migrate_cmd} (Claude Code なら pjp-dotfiles-local-flake-migrate skill)" \
        "--force は作り直すので、手で足したホスト (前の雛形なら local に書いた値も) が消えます。"
    fi
  else
    # 指している先の行 (あれば) を続きの行にする
    pointed=$(grep -n 'inputs.dotfiles.url' "${flake_file}" || true)
    warn "既存の ${flake_file} が別のパスを指しています:" \
      ${pointed:+"${pointed}"} \
      "本体は ${nix_dir} です。作り直すなら --force を付けてください。"
  fi
fi

if [[ ${write_flake} == 1 ]]; then
  template_id=$("${BASH}" "${migrate}" id "${script_dir}/setup-local-flake.sh") \
    || die "雛形の版の印を計算できません (${migrate} id)。"
  example_user_values
  # 雛形は隣の一時ファイルに描き、initial の塊と tmp の例の Windows のユーザー名を入れてから置き換える (差し込めなければ
  # 元のファイルを残す)。開きの行 (cat >"${flake_file}" <<EOS) は local-flake-migrate.sh が原文を抜く目印なので変えない
  real_flake_file=${flake_file}
  flake_file="${local_dir}/.flake.nix.new-$$"
  cat >"${flake_file}" <<EOS
# ローカル専用の flake。setup-local-flake.sh が生成した。
# **git 管理外**なので、ここに書いたことはこのマシンにしか無い。
#
# 雛形の版: ${template_id}
#   雛形が新しくなると setup が知らせる。値を引き継いで今の雛形へ移すには
#   (Claude Code なら pjp-dotfiles-local-flake-migrate skill):
#     ${nix_dir}/scripts/local-flake-migrate.sh prepare
#
#   home-manager switch --flake ~/dotfiles#<ホスト>
#   ~/dotfiles/setup --update
{
  # path: は git を介さずそのまま複製するので commit していない変更も試せる。
  #
  # ただし path: 入力は flake.lock の narHash で厳密に pin されるので、本体を
  # 編集したらこの lock を張り直さないと NAR hash mismatch で落ちる。
  # setup.sh は switch の前に自動で張り直す。手で直すなら:
  #   nix flake update dotfiles --flake ~/dotfiles
  inputs.dotfiles.url = "path:${nix_dir}";

  # dotfiles-private (private な repo) の nix/。この PC を登録したホストの定義と値
  # (nix/hosts/<user>@<hostname>.nix。登録は pjp-dotfiles-register-host skill) を読む (ADR 026)。
  # public な本体の input にはしない (public の lock に private の rev を残さない) ので、ここで取る。
  # clone の nix/ が無かったマシンは本体の空の stub を指す。clone ができたら、値を引き継いで今の
  # 雛形へ移すとき (local-flake-migrate.sh prepare) に指し直す。中身 (nix/ の下だけ) は誰でも読める
  # /nix/store に入る。本体と同じく narHash で lock され、setup.sh が switch の前に張り直す。手で直すなら:
  #   nix flake update dotfiles-private --flake ~/dotfiles
  inputs.dotfiles-private.url = "path:${private_nix_dir}";
  inputs.dotfiles-private.flake = false;

  outputs =
    { dotfiles, dotfiles-private, ... }:
    let
      # dotfiles-private に登録した PC のホスト (nix/hosts/<user>@<hostname>.nix のファイル名が名前)。そのファイルが
      # その PC の値の全部を持つ。setup は --host が無ければ、この PC の名前のホストを選ぶ (ADR 026)。
      privateHosts = dotfiles.lib.privateHosts dotfiles-private;
    in
    {
      # 本体の出力をそのまま引き継ぐ。日々の操作は ~/dotfiles だけ見ればよい。
      inherit (dotfiles)
        packages
        devShells
        formatter
        lib
        ;

      # 登録簿のホスト (型と sandbox) に、dotfiles-private に登録したホストと、このマシンだけのホストを重ねる
      # (後ろが勝つ)。PC の値は、dotfiles-private の登録 (登録した PC) か、下に足す tmp (登録していない PC) の
      # どちらか 1 か所にだけ書く (ADR 027)。
      homeConfigurations = dotfiles.homeConfigurations // privateHosts // {
        # このマシンだけのホストはここに足す (登録簿 hosts/default.nix は触らない)。dotfiles-private を
        # 読めない PC は、ここに tmp を足してその PC の値を書く。読める PC は dotfiles-private に登録する
        # (pjp-dotfiles-register-host skill。登録の前の 1 回は ~/dotfiles/setup --host <型> で当てる)。
        #
        # ここに足した名前は setup の **既定の対象ホスト** になる (dotfiles-private に登録したこの PC の
        # ホストより優先する)。複数足したときは一番上のものが既定になるので、切り替えたいときは行を入れ替える。
        # どちらも無ければ、setup は推測せずに止まり、選べる道を出す。
        #
        # 値は mkHome の引数と modules に直に書く。option の既定より強いだけの普通の定義なので、mkForce は
        # 要らない。書かなかった option は本体の既定 (nix/home/options.nix) になる。例を使うなら、行頭の
        # 「# 」を 1 段外し、値をこのマシンのものに直す (例の値は作り物)。
        #
        # tmp = dotfiles.lib.mkHome {
        #   username = "pollenjp";
        #   system = "x86_64-linux";
        #
        #   # WSL のマシンだけ書く (書かなければ WSL でないマシン)。
        #   wsl = {
        #     enable = true;
        #     # ホスト側 Windows のユーザー名 (例は作り物)。/mnt/c/Users/<名前>/... の組み立てに使う
        #     # (1Password の op-ssh-sign のパスと、win/ の配り先)。値はこのマシンで:
        #     #   pwsh.exe -NoProfile -Command '\$env:USERNAME'
        #     windowsUserName = "alice";
        #     # repo 直下の win/ を Windows 側へ配る (反映は ~/dotfiles/setup --update)。
        #     windowsFiles.enable = true;
        #     # WSL から起動された Windows の .exe を、起動元の祖先付きで journald に常時記録する (ADR 012)。
        #     # unit を /etc へ入れるのは ~/dotfiles/setup --update の最後の手順 exe-exec-trace (中で sudo を呼ぶ)。
        #     exeExecTrace.enable = true;
        #   };
        #   # 1Password で git の署名をする (WSL ならホスト側 Windows の 1Password)。
        #   onePassword.enable = true;
        #
        #   claude = {
        #     # Notion Dev Tracker (pjp-dev-tracker skill) をこのマシンで使うか。本体の既定は false で、
        #     # 使うマシンだけ true にする。CLAUDE.md の「タスク管理」の節と settings.json の
        #     # skillOverrides の両方がこの値から決まる。
        #     # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
        #     devTracker.enable = true;
        #
        #     # Notion へ書く skill (pjp-dev-tracker・pjp-notion-authoring など) の宛先。
        #     # 宛先は作業中の repo で決まる: このマシンの routes → claude-skills の profiles.toml の
        #     # [routes] → この profile (規則に当たらない repo と repo の外で使う既定)。
        #     # 値は private の claude-skills (skills/pjp-notion-profile/profiles.toml) にあり、
        #     # ここでは名前を選ぶ ("personal" / "work")。書かなければ null で、規則に当たらない所で
        #     # skill は止まる (devTracker.enable = true なら、評価のたびに警告も出る)。
        #     # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
        #     notion.profile = "personal";
        #     # このマシンだけ規則を足す・上書きする (例: 会社の PC で pollenjp の repo も work に書く)。
        #     # 共通の [routes] より先に見る:
        #     #   notion.routes = { "pollenjp/*" = "work"; };
        #     # このマシンだけプロファイルの値を差し替える (外側はプロファイルの名前。null はキーを消す):
        #     #   notion.override = { personal = { scanData = "https://app.notion.com/p/…"; }; };
        #
        #     # Claude のセッションの git と、fetch 系の abbr / alias (gf・gfp・gpul など) と、
        #     # setup の取得 (bootstrap の clone / 取得と本体の更新) を、gh の資格情報で GitHub へ
        #     # HTTPS で通すか (setup の取得は、gh で取れなければ ssh で取り直す)。
        #     # 本体の既定は true で、gh auth login 済みが前提 (未ログインなら setup が警告する)。
        #     # gh にログインしないマシンは false にすると、今までどおり ssh を通る。
        #     # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
        #     #   gitViaGh.enable = false;
        #
        #     # 設計を出したとき・PR を作ったときに、解説動画の短尺を答えを待たずに裏で作り始めるか
        #     # (claude-skills の pjp-video-explainer-offer)。本体の既定は false で、作る前に「解説動画を
        #     # 作りますか？」と聞き、選ばれたときだけ作る (1 本ごとに token を大きく使うため)。
        #     # 聞かずに作り始めたいマシンだけ true にする。
        #     # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
        #     #   videoOffer.autoStart.enable = true;
        #   };
        #
        #   # mkHome の引数に無い option (本体の nix/home/options.nix) と home-manager の設定は、modules に書く。
        #   modules = [
        #     {
        #       # cc-pages (cc-page のページを見せるローカル web ビューア) が待ち受ける port。
        #       # 書かなければ cc-pages の既定の 7777。7777 がほかと衝突するマシンだけ書く。
        #       # 反映は ~/dotfiles/setup --update (switch だけでもよい。daemon は switch が再起動する)。
        #       #   dotfiles.ccPages.port = 7778;
        #     }
        #   ];
        # };
      };
    };
}
EOS
  if [[ ${initial} == 1 ]] && ! insert_initial_block "${flake_file}"; then
    rm -f "${flake_file}"
    die "雛形に、初期用のホスト initial を差し込む目印 (tmp の例の終わりの「        # };」) が 1 行ではありません。setup-local-flake.sh の差し込み方を直してください。"
  fi
  if [[ -n ${example_windows_user} ]] && ! set_example_windows_user "${flake_file}" "${example_windows_user}"; then
    example_windows_user=""
    example_user_note="雛形の tmp の例に windowsUserName の行がちょうど 1 行ではない。setup-local-flake.sh の置き換え方を直す"
  fi
  mv "${flake_file}" "${real_flake_file}"
  flake_file=${real_flake_file}
  echo "  flake.nix: 書きました"
  if [[ ${initial} == 1 ]]; then
    echo "  初期用のホスト initial を書きました (Windows のユーザー名: ${initial_windows_user})"
  fi
  if [[ -n ${example_windows_user} ]]; then
    echo "  tmp の例 (コメント) の windowsUserName に ${example_windows_user} を入れました"
  elif [[ -n ${example_user_note} ]]; then
    echo "  tmp の例 (コメント) の windowsUserName は作り物の名前のままです (${example_user_note})"
  fi
  if [[ ${private_nix_dir} == "${nix_dir}/private-stub" ]]; then
    echo "  dotfiles-private: clone の nix/ が無いので、本体の空の stub を指しました (${private_nix_dir})。"
    if [[ ${initial} == 1 ]]; then
      # local-flake-migrate.sh prepare は initial を手で足したホストとして残す (残すと登録したホストが選ばれない)
      echo "    この PC を登録して merge したら、${script_dir}/setup-local-flake.sh --force で作り直す (initial も外れ、clone の nix/ を読む)。"
    else
      echo "    clone ができたら ${migrate_cmd} で指し直す (pjp-dotfiles-register-host skill)。"
    fi
  else
    echo "  dotfiles-private: ${private_nix_dir} を読みます (この PC を登録したホストがあれば、setup が選ぶ)。"
  fi
fi

link="${local_dir}/setup"
target="${script_dir}/setup.sh"
if [[ -L ${link} ]]; then
  if [[ $(readlink -- "${link}") == "${target}" ]]; then
    echo "  setup: 既に張られています"
  else
    ln -sfn "${target}" "${link}"
    echo "  setup: 張り直しました"
  fi
elif [[ -e ${link} ]]; then
  die "${link} が symlink ではありません。手で退けてください。"
else
  ln -s "${target}" "${link}"
  echo "  setup: 張りました -> ${target}"
fi

echo
echo "完了しました。以後はここから実行できます:"
echo "  ~/dotfiles/setup            メニュー"
echo "  ~/dotfiles/setup --update   既存マシンの更新"
echo "  home-manager switch --flake ~/dotfiles#<ホスト>"
if [[ ${initial} == 1 ]]; then
  echo
  echo "次は Nix を入れて、初期用のホスト initial で当てる (Windows のアプリも入る):"
  echo "  ~/dotfiles/setup --new-machine"
fi
