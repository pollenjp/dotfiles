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
#               このマシンだけの設定 (local) と、このマシンだけのホストをここに書ける。
#               dotfiles-private の nix/ を 2 つ目の path: の入力 (inputs.dotfiles-private。flake = false) に取り、
#               そこに登録した PC のホスト (nix/hosts/<user>@<hostname>.nix) を登録簿のホストに重ねる
#               (local は当たらない。ADR 026)。指す先は private-host.sh input-dir が決める: clone の nix/ があれば
#               そこ、無ければ本体の空の stub (nix/private-stub)。clone ができたら local-flake-migrate.sh prepare が
#               指し直す。heredoc の展開は ${nix_dir}・${private_nix_dir}・${template_id} だけ (local-flake-migrate.sh が
#               同じ展開を真似て描く。足すならあちらも)。
#               雛形の local は dotfiles.claude.devTracker.enable = false を持つ
#               (Notion Dev Tracker を使うマシンだけ true に直す)。
#               dotfiles.claude.gitViaGh.enable は既定の true のままで、
#               コメントアウトした false の例だけ置く (gh にログインしないマシンだけ外す)。
#               Notion へ書く skill の既定の宛先 dotfiles.claude.notion.profile は null
#               (選ぶまで、規則に当たらない repo と repo の外で止まる)。
#               cc-pages の待ち受け port (dotfiles.ccPages.port) は、コメントアウトした
#               例だけ置く (7777 がほかと衝突するマシンだけ書く)。
#               解説動画を答えを待たずに作り始めるか (dotfiles.claude.videoOffer.autoStart.enable) は
#               本体の既定の false (作る前に聞く) のままで、コメントアウトした true の例だけ置く。
#               先頭のコメントに「# 雛形の版: <印>」を置く。印は下の heredoc の原文 (展開する前) から
#               local-flake-migrate.sh id が計算する値で、heredoc を直すと変わる。
#   flake.lock  nix が生成する。
#   setup       setup.sh への symlink。更新は `~/dotfiles/setup --update`。
#
# ## 雛形が新しくなったら
#
# 既にある flake.nix は、雛形が変わっても触らない (--force は作り直すので、local に書いた値と手で足した
# ホストが消える)。印が今の雛形と違えば (印の無い、印を入れる前の雛形も)、ここと setup.sh が知らせる。
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
force=0

usage() {
  cat <<'EOS'
~/dotfiles にローカル専用の flake を用意する (git 管理外)。

使い方:
  setup-local-flake.sh           用意する (既にあれば触らない)
  setup-local-flake.sh --force   flake.nix を作り直す
  setup-local-flake.sh -h        これ

環境変数:
  DOTFILES_LOCAL_DIR        ローカル flake の場所 (既定: ~/dotfiles)
  DOTFILES_ALLOW_ANY_PATH   1 なら ghq のパス確認を警告だけにする
EOS
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1 ;;
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

mkdir -p "${local_dir}"

# 雛形の版の印を計算し、照合する道具 (この script の隣)。印は heredoc の原文から計算する
migrate="${script_dir}/local-flake-migrate.sh"
migrate_cmd="${migrate} prepare"
if [[ ${local_dir} != "${HOME}/dotfiles" ]]; then
  migrate_cmd+=" --flake ${local_dir}"
fi

flake_file="${local_dir}/flake.nix"
write_flake=1
if [[ -f ${flake_file} && ${force} == 0 ]]; then
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
        "--force は作り直すので、local に書いた値と手で足したホストが消えます。"
    fi
    # 古い形のままだと、登録簿のホストに local (dotfiles.claude.devTracker.enable など) が当たらないので、
    # 何が困るかも知らせる。
    if ! grep -q 'hostsWith' "${flake_file}"; then
      warn "flake.nix が古い雛形のままです (dotfiles.lib.hostsWith / local が無い)。" \
        "local が無いと Notion の宛先の既定 (dotfiles.claude.notion.profile) を選べず、規則に当たらない repo と repo の外で Notion へ書く skill は止まる。" \
        "直すなら ${migrate_cmd} で今の雛形へ移す (手で足したホストを引き継ぐ)。手で足したホストが無ければ --force で作り直してもよい。"
    fi
    if ! grep -q 'notion\.profile' "${flake_file}"; then
      warn "flake.nix の local に dotfiles.claude.notion.profile がありません。" \
        "規則に当たらない repo と repo の外で、Notion へ書く skill (pjp-dev-tracker など) は宛先が決まらず止まります。README「Notion の宛先を host ごとに選ぶ」の形で local に足してください。"
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
  # dotfiles-private の入力が指す先 (clone の nix/ か、無ければ本体の空の stub)。決め方は private-host.sh だけが持つ
  private_nix_dir=$("${BASH}" "${script_dir}/private-host.sh" input-dir --nix-dir "${nix_dir}" 2>/dev/null) \
    || private_nix_dir="${nix_dir}/private-stub"
  cat >"${flake_file}" <<EOS
# ローカル専用の flake。setup-local-flake.sh が生成した。
# **git 管理外**なので、ここに書いたことはこのマシンにしか無い。
#
# 雛形の版: ${template_id}
#   雛形が新しくなると setup が知らせる。値を引き継いで今の雛形へ移すには
#   (Claude Code なら pjp-dotfiles-local-flake-migrate skill):
#     ${nix_dir}/scripts/local-flake-migrate.sh prepare
#
#   home-manager switch --flake ~/dotfiles#pollenjp@wsl
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
      # このマシンだけの設定。登録簿 (hosts/default.nix) のホストにも、下で足した
      # ホストにも同じものが当たる。本体の option (nix/home/options.nix) をここで決める。
      # dotfiles-private に登録したホスト (下の privateHosts) には当たらない (値はそのホストの
      # ファイルにある。この PC を登録したら、ここに書いた値はこの PC のホストでは使われない)。
      #
      # 登録簿側が同じ option を既に定義していて差し替えたいときは、関数の形にして
      # mkForce を使う (同じ優先度の定義が 2 つあると conflicting definition values で落ちる):
      #   local = { lib, ... }: { dotfiles.claude.devTracker.enable = lib.mkForce false; };
      local = {
        # Notion Dev Tracker (pjp-dev-tracker skill) をこのマシンで使うか。
        # 本体の既定は true だが、この雛形では false にしてある (使うマシンだけ
        # true に直す)。CLAUDE.md の「タスク管理」の節と settings.json の
        # skillOverrides の両方がこの値から決まる。
        # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
        dotfiles.claude.devTracker.enable = false;

        # Claude のセッションの git と、fetch 系の abbr / alias (gf・gfp・gpul など) と、
        # setup の取得 (bootstrap の clone / 取得と本体の更新) を、gh の資格情報で GitHub へ
        # HTTPS で通すか (setup の取得は、gh で取れなければ ssh で取り直す)。
        # 本体の既定は true で、gh auth login 済みが前提 (未ログインなら setup が警告する)。
        # gh にログインしないマシンは false にすると、今までどおり ssh を通る。
        # 反映は ~/dotfiles/setup --update (switch だけでは settings.json に届かない)。
        # dotfiles.claude.gitViaGh.enable = false;

        # Notion へ書く skill (pjp-dev-tracker・pjp-notion-authoring など) の宛先。
        # 宛先は作業中の repo で決まる: このマシンの routes → claude-skills の profiles.toml の
        # [routes] → この profile (規則に当たらない repo と repo の外で使う既定)。
        # 値は private の claude-skills (skills/pjp-notion-profile/profiles.toml) にあり、
        # ここでは名前を選ぶ ("personal" / "work")。null のままだと、規則に当たらない所で skill は止まる。
        # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
        dotfiles.claude.notion.profile = null;
        # このマシンだけ規則を足す・上書きする (例: 会社の PC で pollenjp の repo も work に書く)。
        # 共通の [routes] より先に見る:
        #   dotfiles.claude.notion.routes = { "pollenjp/*" = "work"; };
        # このマシンだけプロファイルの値を差し替える (外側はプロファイルの名前。null はキーを消す):
        #   dotfiles.claude.notion.override = { personal = { scanData = "https://app.notion.com/p/…"; }; };

        # cc-pages (cc-page のページを見せるローカル web ビューア) が待ち受ける port。
        # 書かなければ cc-pages の既定の 7777。7777 がほかと衝突するマシンだけ書く。
        # 反映は ~/dotfiles/setup --update (switch だけでもよい。daemon は switch が再起動する)。
        # dotfiles.ccPages.port = 7778;

        # 設計を出したとき・PR を作ったときに、解説動画の短尺を答えを待たずに裏で作り始めるか
        # (claude-skills の pjp-video-explainer-offer)。本体の既定は false で、作る前に「解説動画を
        # 作りますか？」と聞き、選ばれたときだけ作る (1 本ごとに token を大きく使うため)。
        # 聞かずに作り始めたいマシンだけ true にする。
        # 反映は ~/dotfiles/setup --update (switch だけでもよい)。
        # dotfiles.claude.videoOffer.autoStart.enable = true;
      };

      # dotfiles-private に登録した PC のホスト (nix/hosts/<user>@<hostname>.nix のファイル名が名前)。
      # local は当たらない。setup は --host が無ければ、この PC の名前のホストを選ぶ (ADR 026)。
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

      # 登録簿のホストに local を当てて引き継ぎ (dotfiles.homeConfigurations に local を足したもの)、
      # dotfiles-private に登録したホストを重ねる (同じ名前なら登録簿のものに勝つ)。
      homeConfigurations = dotfiles.lib.hostsWith [ local ] // privateHosts // {
        # このマシンだけのホストはここに足す (登録簿 hosts/default.nix は触らない)。
        #
        # ここに足した名前は setup の **既定の対象ホスト** になる (dotfiles-private に
        # 登録したこの PC のホストと、登録簿からの推測より優先する)。複数足したときは
        # 一番上のものが既定になるので、切り替えたいときは行を入れ替える。
        #
        # tmp = dotfiles.lib.mkHome {
        #   username = "pollenjp";
        #   system = "x86_64-linux";
        #   wsl = {
        #     enable = true;
        #     # ホスト側 Windows のユーザー名。/mnt/c/Users/<名前>/... の組み立てに使う
        #     # (1Password の op-ssh-sign のパスと、win/ の配り先)。登録簿の pollenjp@wsl は
        #     # "polle" 固定なので、別の名前のマシンはここで足す。値はこのマシンで:
        #     #   pwsh.exe -NoProfile -Command '\$env:USERNAME'
        #     windowsUserName = "polle";
        #   };
        #   # 1Password で git の署名をする (WSL ならホスト側 Windows の 1Password)。
        #   onePassword.enable = true;
        #
        #   # local はここにも渡す (hostsWith が当てるのは登録簿のホストだけ)。
        #   # 本体が既に定義している値を差し替えるには mkForce が要る。
        #   modules = [
        #     local
        #     (
        #       { lib, ... }:
        #       {
        #         programs.git.settings.user.email = lib.mkForce "tmp@example.com";
        #       }
        #     )
        #   ];
        # };
      };
    };
}
EOS
  echo "  flake.nix: 書きました"
  if [[ ${private_nix_dir} == "${nix_dir}/private-stub" ]]; then
    echo "  dotfiles-private: clone の nix/ が無いので、本体の空の stub を指しました (${private_nix_dir})。"
    echo "    clone ができたら ${migrate_cmd} で指し直す (pjp-dotfiles-register-host skill)。"
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
