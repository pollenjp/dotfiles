# login の環境の PATH (home/modules/shell-common.nix の home.sessionPath と home.sessionVariablesExtra) に、~/.cargo/bin と mise の
# shim が入るかを確かめる。hc の core は、SSH・--via で立つとアカウントの shell の非対話の login 環境を読み、hc の子をその env で
# 起こすので、hc の子が claude (mise)・pjp (~/.cargo/bin)・hc (~/.local/bin) を名前で引けるのはここで入れた PATH による。
# flake.nix の checks (login-path-state) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert。CI の `nix flake check --all-systems --no-build` でも落ちる)
#     - 既定 (personal) では home.sessionPath が ~/bin・~/.local/bin・~/.cargo/bin の順。dotfiles.claude.privateSkills.enable =
#       false では ~/.cargo/bin が無い
#     - Linux の既定 (dotfiles.herdrCore.enable) では home.sessionVariablesExtra に mise の shim を PATH の最後に足す行がある。
#       dotfiles.herdrCore.enable = false と macOS の既定には無い
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - home の hm-session-vars.sh を bash で、babelfish で fish に直した hm-session-vars.fish を fish で、HOME と PATH だけの
#       env で読むと、PATH は ~/bin・~/.local/bin・~/.cargo/bin・元の PATH・~/.local/share/mise/shims の順になる。
#       XDG_DATA_HOME があれば shim は <XDG_DATA_HOME>/mise/shims、MISE_DATA_DIR があれば <MISE_DATA_DIR>/shims。
#       元の PATH が空でも : が続かない
#     - privateSkills.enable = false では ~/.cargo/bin が、herdrCore.enable = false では shim が入らない
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  configWith =
    modules:
    (mkHome {
      username = "tester";
      inherit system modules;
    }).config;

  cfgs = {
    all = configWith [ ];
    # 集約ハブ (herdr.hub) は claude-skills の clone を要る (group.nix の assertion) ので、一緒に外す
    noCargo = configWith [
      {
        dotfiles.claude.privateSkills.enable = false;
        dotfiles.herdr.hub.enable = false;
      }
    ];
    noShims = configWith [ { dotfiles.herdrCore.enable = false; } ];
  };

  shimsLine = ''export PATH="$PATH''${PATH:+:}''${MISE_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"'';
  hasShims = cfg: lib.hasInfix shimsLine cfg.home.sessionVariablesExtra;

  cases = [
    {
      name = "既定では home.sessionPath が ~/bin・~/.local/bin・~/.cargo/bin の順";
      ok =
        cfgs.all.home.sessionPath == [
          "$HOME/bin"
          "$HOME/.local/bin"
          "$HOME/.cargo/bin"
        ];
    }
    {
      name = "privateSkills.enable = false では home.sessionPath に ~/.cargo/bin が無い";
      ok =
        cfgs.noCargo.home.sessionPath == [
          "$HOME/bin"
          "$HOME/.local/bin"
        ];
    }
    {
      name =
        if isLinux then
          "Linux の既定では、mise の shim を PATH の最後に足す行がある (herdrCore.enable = false では無い)"
        else
          "macOS の既定 (herdrCore.enable が false) には、mise の shim を足す行が無い";
      ok = if isLinux then hasShims cfgs.all && !(hasShims cfgs.noShims) else !(hasShims cfgs.all);
    }
  ];
  failed = builtins.filter (c: !c.ok) cases;

  varsSh = cfg: "${cfg.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
  varsFish = cfg: "${cfg.programs.fish.sessionVariablesPackage}/etc/profile.d/hm-session-vars.fish";
in
assert lib.assertMsg (failed == [ ])
  "login-path-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "login-path-state" { } (
  ''
    echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ''
  + lib.optionalString isLinux ''
    declare -A varsSh=(
      ${lib.concatStrings (lib.mapAttrsToList (s: cfg: "[${s}]=${varsSh cfg} ") cfgs)}
    )
    declare -A varsFish=(
      ${lib.concatStrings (lib.mapAttrsToList (s: cfg: "[${s}]=${varsFish cfg} ") cfgs)}
    )
    # 設定 $2 の hm-session-vars を shell $1 で、HOME=/h と引数の NAME=VALUE だけの env で読み、PATH を : で並べて出す
    # (fish の PATH は list なので : でつなぐ)
    seen() {
      local shell=$1 setting=$2
      shift 2
      case $shell in
        bash)
          env -i HOME=/h "$@" ${lib.getExe cfgs.all.programs.bash.package} --noprofile --norc \
            -c '. "$1"; printf "%s" "$PATH"' _ "''${varsSh[$setting]}"
          ;;
        fish)
          env -i HOME=/h "$@" ${lib.getExe cfgs.all.programs.fish.package} --no-config \
            -c 'source $argv[1]; string join : -- $PATH' "''${varsFish[$setting]}"
          ;;
      esac
    }
    expect() {
      local shell=$1 setting=$2 label=$3 want=$4 got
      shift 4
      got=$(seen "$shell" "$setting" "$@")
      if [[ $got != "$want" ]]; then
        echo "login-path-state: $shell・$setting ($label) の PATH が「$want」でなく「$got」" >&2
        exit 1
      fi
      echo "ok   $shell・$setting ($label): $got"
    }
    for shell in bash fish; do
      expect "$shell" all "既定" /h/bin:/h/.local/bin:/h/.cargo/bin:/base:/h/.local/share/mise/shims PATH=/base
      expect "$shell" all "XDG_DATA_HOME がある" /h/bin:/h/.local/bin:/h/.cargo/bin:/base:/x/mise/shims PATH=/base XDG_DATA_HOME=/x
      expect "$shell" all "MISE_DATA_DIR がある" /h/bin:/h/.local/bin:/h/.cargo/bin:/base:/m/shims PATH=/base MISE_DATA_DIR=/m XDG_DATA_HOME=/x
      expect "$shell" noCargo "privateSkills.enable = false" /h/bin:/h/.local/bin:/base:/h/.local/share/mise/shims PATH=/base
      expect "$shell" noShims "herdrCore.enable = false" /h/bin:/h/.local/bin:/h/.cargo/bin:/base PATH=/base
    done
    # 元の PATH が空 (bash で PATH= を渡す) でも、: が続かない
    expect bash all "元の PATH が空" /h/bin:/h/.local/bin:/h/.cargo/bin:/h/.local/share/mise/shims PATH=
  ''
  + ''
    touch $out
  ''
)
