# 自前の証明書の束を持つツールにも OS の信頼ストアを読ませる環境変数 4 つ (home/modules/os-ca-bundle.nix。
# ADR 028) を、home/options.nix の dotfiles.osCaBundle の 3 つの選び方ごとに確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (os-ca-bundle-state) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - Linux の既定 (4 つ) では、hm-session-vars.sh の末尾 (home.sessionVariablesExtra) に、
#       /etc/ssl/certs/ca-certificates.crt があるときだけの if があり、その中で SSL_CERT_FILE を (値が無ければ
#       NIX_SSL_CERT_FILE か束に) 決めてから、残りの 3 つを値が無いときだけ SSL_CERT_FILE に揃えて export する
#     - requestsCaBundle.enable = false では、同じ if から REQUESTS_CA_BUNDLE の行だけが無い
#     - enable = false では、if を置かない
#     - darwin には、どの選び方でも if を置かない
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - home の hm-session-vars.sh を bash で、babelfish で fish に直した hm-session-vars.fish を fish で読み、子の
#       printenv で 4 つを見る (束のパスは、ビルドの中に作ったファイルか、無いパスに置き換える):
#       - 既定: 束があれば 4 つとも束のパス、束が無ければ 4 つとも立たない。SSL_CERT_FILE があれば 4 つともその値、
#         NIX_SSL_CERT_FILE だけあれば 4 つともその値 (Ubuntu の nix の profile が先に立てるときと同じ)、
#         両方あれば NIX_SSL_CERT_FILE は残して残りは SSL_CERT_FILE。空の変数は値が無いものとして扱い、
#         空白を含む値もそのまま揃う
#       - requestsCaBundle.enable = false: REQUESTS_CA_BUNDLE は立たず (すでにあればその値のまま)、残りの 3 つは既定と同じ
#       - enable = false: 束があっても 4 つとも立たない (すでにある値はそのまま)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configOn =
    system: modules:
    (mkHome {
      username = "tester";
      inherit system modules;
    }).config;

  # 3 つの選び方
  settings = {
    all = [ ];
    noRequests = [ { dotfiles.osCaBundle.requestsCaBundle.enable = false; } ];
    none = [ { dotfiles.osCaBundle.enable = false; } ];
  };
  cfgs = lib.mapAttrs (_: configOn system) settings;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  bundle = "/etc/ssl/certs/ca-certificates.crt";
  names = [
    "NIX_SSL_CERT_FILE"
    "SSL_CERT_FILE"
    "REQUESTS_CA_BUNDLE"
    "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"
  ];

  # if の行から fi の行までを取り出す。if の行が無ければ null。if の行と export の行は os-ca-bundle.nix に
  # 書いた行と 1 文字も違わないこと
  ifLine = "if [ -f ${bundle} ]; then";
  blockOf =
    cfg:
    let
      lines = lib.splitString "\n" cfg.home.sessionVariablesExtra;
      from = lib.lists.findFirstIndex (l: l == ifLine) null lines;
      rest = lib.drop from lines;
      to = lib.lists.findFirstIndex (l: l == "fi") null rest;
    in
    if from == null || to == null then null else lib.concatStringsSep "\n" (lib.take (to + 1) rest);

  exportOf = {
    SSL_CERT_FILE = {
      what = "SSL_CERT_FILE を、値が無ければ NIX_SSL_CERT_FILE か束のパスにする";
      line = "export SSL_CERT_FILE=\"\${SSL_CERT_FILE:-\${NIX_SSL_CERT_FILE:-${bundle}}}\"";
    };
  }
  // lib.genAttrs (lib.remove "SSL_CERT_FILE" names) (n: {
    what = "${n} を、値が無ければ SSL_CERT_FILE に揃える";
    line = "export ${n}=\"\${${n}:-$SSL_CERT_FILE}\"";
  });

  # 選び方 s の if に、入れる変数の行があり、入れない変数の行が無いか
  blockCases =
    s: label: wanted:
    let
      block = blockOf cfgs.${s};
    in
    [
      {
        name = "${label}: hm-session-vars.sh の末尾に、${bundle} があるときだけの if がある";
        ok = block != null;
      }
    ]
    ++ map (n: {
      name =
        if builtins.elem n wanted then
          "${label}: その if の中で、${exportOf.${n}.what}"
        else
          "${label}: その if の中に ${n} の行が無い";
      ok = block != null && lib.hasInfix exportOf.${n}.line block == builtins.elem n wanted;
    }) names;

  cases =
    if isLinux then
      blockCases "all" "既定 (4 つ)" names
      ++ blockCases "noRequests" "requestsCaBundle.enable = false" (lib.remove "REQUESTS_CA_BUNDLE" names)
      ++ [
        {
          name = "enable = false: hm-session-vars.sh に束の if を置かない";
          ok = !(lib.hasInfix bundle cfgs.none.home.sessionVariablesExtra);
        }
      ]
    else
      [
        {
          name = "darwin の hm-session-vars.sh に、どの選び方でも束の if を置かない";
          ok = lib.all (cfg: !(lib.hasInfix bundle cfg.home.sessionVariablesExtra)) (lib.attrValues cfgs);
        }
      ];

  failed = builtins.filter (c: !c.ok) cases;

  varsSh = cfg: "${cfg.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
  varsFish = cfg: "${cfg.programs.fish.sessionVariablesPackage}/etc/profile.d/hm-session-vars.fish";
in
assert lib.assertMsg (failed == [ ])
  "os-ca-bundle-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "os-ca-bundle-state" { } (
  ''
    echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ''
  + lib.optionalString isLinux ''
    names=(${lib.escapeShellArgs names})
    # 選び方ごとの hm-session-vars
    declare -A varsSh=(
      ${lib.concatStrings (lib.mapAttrsToList (s: cfg: "[${s}]=${varsSh cfg} ") cfgs)}
    )
    declare -A varsFish=(
      ${lib.concatStrings (lib.mapAttrsToList (s: cfg: "[${s}]=${varsFish cfg} ") cfgs)}
    )

    # 選び方 $2 の hm-session-vars の束のパスを $3 に置き換え、引数の NAME=VALUE だけを env にした shell で読む。
    # 子の printenv で見た 4 つの値 (無ければ unset) を「名前=値 」の形で 1 行に並べる (export されたかも見る)
    seen() {
      local shell=$1 setting=$2 path=$3
      shift 3
      case $shell in
        bash)
          sed "s|${bundle}|$path|g" "''${varsSh[$setting]}" >vars.sh
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfgs.all.programs.bash.package} --noprofile --norc \
            -c '. ./vars.sh; for n in '"''${names[*]}"'; do printf "%s=%s " "$n" "$(printenv "$n" || echo unset)"; done'
          ;;
        fish)
          sed "s|${bundle}|$path|g" "''${varsFish[$setting]}" >vars.fish
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfgs.all.programs.fish.package} --no-config \
            -c 'source ./vars.fish; for n in '"''${names[*]}"'; printf "%s=%s " $n (printenv $n; or echo unset); end'
          ;;
      esac
    }
    # 4 つの値を名前の順に受け取り、seen と同じ形の 1 行にする
    want() {
      local out="" i=0 v
      for v in "$@"; do
        out+="''${names[$i]}=$v "
        i=$((i + 1))
      done
      printf '%s' "$out"
    }
    expect() {
      local shell=$1 setting=$2 label=$3 path=$4 want=$5 got
      shift 5
      got=$(seen "$shell" "$setting" "$path" "$@")
      if [[ $got != "$want" ]]; then
        echo "os-ca-bundle-state: $shell・$setting ($label) が「$want」でなく「$got」" >&2
        exit 1
      fi
      echo "ok   $shell・$setting ($label): $got"
    }

    have=$TMPDIR/ca.crt
    touch "$have"
    missing=$TMPDIR/missing.crt
    for shell in bash fish; do
      expect "$shell" all "束がある" "$have" "$(want "$have" "$have" "$have" "$have")"
      expect "$shell" all "束が無い" "$missing" "$(want unset unset unset unset)"
      expect "$shell" all "SSL_CERT_FILE がすでにある" "$have" \
        "$(want /opt/corp.pem /opt/corp.pem /opt/corp.pem /opt/corp.pem)" SSL_CERT_FILE=/opt/corp.pem
      expect "$shell" all "NIX_SSL_CERT_FILE だけがすでにある" "$have" \
        "$(want /opt/nix.pem /opt/nix.pem /opt/nix.pem /opt/nix.pem)" NIX_SSL_CERT_FILE=/opt/nix.pem
      expect "$shell" all "両方がすでにある" "$have" \
        "$(want /opt/nix.pem /opt/corp.pem /opt/corp.pem /opt/corp.pem)" NIX_SSL_CERT_FILE=/opt/nix.pem SSL_CERT_FILE=/opt/corp.pem
      expect "$shell" all "REQUESTS_CA_BUNDLE が空" "$have" "$(want "$have" "$have" "$have" "$have")" REQUESTS_CA_BUNDLE=
      expect "$shell" all "SSL_CERT_FILE に空白がある" "$have" \
        "$(want "/opt/a b.pem" "/opt/a b.pem" "/opt/a b.pem" "/opt/a b.pem")" "SSL_CERT_FILE=/opt/a b.pem"

      expect "$shell" noRequests "束がある" "$have" "$(want "$have" "$have" unset "$have")"
      expect "$shell" noRequests "REQUESTS_CA_BUNDLE がすでにある" "$have" \
        "$(want "$have" "$have" /opt/req.pem "$have")" REQUESTS_CA_BUNDLE=/opt/req.pem

      expect "$shell" none "束がある" "$have" "$(want unset unset unset unset)"
      expect "$shell" none "SSL_CERT_FILE がすでにある" "$have" \
        "$(want unset /opt/corp.pem unset unset)" SSL_CERT_FILE=/opt/corp.pem
    done
  ''
  + ''
    touch $out
  ''
)
