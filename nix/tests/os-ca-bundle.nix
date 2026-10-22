# 自前の証明書の束を持つツールにも OS の信頼ストアを読ませる環境変数 4 つ (home/modules/os-ca-bundle.nix。
# ADR 028) を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (os-ca-bundle-state) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - Linux では、hm-session-vars.sh の末尾 (home.sessionVariablesExtra) に、/etc/ssl/certs/ca-certificates.crt が
#       あるときだけの if があり、その中で SSL_CERT_FILE を (値が無ければ NIX_SSL_CERT_FILE か束に) 決めてから、
#       残りの 3 つを値が無いときだけ SSL_CERT_FILE に揃えて export する
#     - darwin には、その if を置かない
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - home の hm-session-vars.sh を bash で、babelfish で fish に直した hm-session-vars.fish を fish で読み、子の
#       printenv で 4 つを見る (束のパスは、ビルドの中に作ったファイルか、無いパスに置き換える):
#       - 束があれば、4 つとも束のパスになる
#       - 束が無ければ、4 つとも立たない
#       - SSL_CERT_FILE があれば 4 つともその値、NIX_SSL_CERT_FILE だけあれば 4 つともその値 (Ubuntu の nix の
#         profile が先に立てるときと同じ)、両方あれば NIX_SSL_CERT_FILE は残して残りは SSL_CERT_FILE
#       - 空の変数は値が無いものとして扱う。空白を含む値もそのまま揃う
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  cfg =
    (mkHome {
      username = "tester";
      inherit system;
    }).config;

  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  bundle = "/etc/ssl/certs/ca-certificates.crt";
  names = [
    "NIX_SSL_CERT_FILE"
    "SSL_CERT_FILE"
    "REQUESTS_CA_BUNDLE"
    "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE"
  ];

  extra = cfg.home.sessionVariablesExtra;

  # if の行から fi の行までを取り出す。if の行が無ければ null。if の行と export の行は os-ca-bundle.nix に
  # 書いた行と 1 文字も違わないこと
  ifLine = "if [ -f ${bundle} ]; then";
  block =
    let
      lines = lib.splitString "\n" extra;
      from = lib.lists.findFirstIndex (l: l == ifLine) null lines;
      rest = lib.drop from lines;
      to = lib.lists.findFirstIndex (l: l == "fi") null rest;
    in
    if from == null || to == null then null else lib.concatStringsSep "\n" (lib.take (to + 1) rest);

  exports = [
    {
      what = "SSL_CERT_FILE を、値が無ければ NIX_SSL_CERT_FILE か束のパスにする";
      line = "export SSL_CERT_FILE=\"\${SSL_CERT_FILE:-\${NIX_SSL_CERT_FILE:-${bundle}}}\"";
    }
  ]
  ++ map (n: {
    what = "${n} を、値が無ければ SSL_CERT_FILE に揃える";
    line = "export ${n}=\"\${${n}:-$SSL_CERT_FILE}\"";
  }) (lib.remove "SSL_CERT_FILE" names);

  cases =
    if isLinux then
      [
        {
          name = "Linux の hm-session-vars.sh の末尾に、${bundle} があるときだけの if がある";
          ok = block != null;
        }
      ]
      ++ map (e: {
        name = "その if の中で、${e.what}";
        ok = block != null && lib.hasInfix e.line block;
      }) exports
    else
      [
        {
          name = "darwin の hm-session-vars.sh に、束の if を置かない";
          ok = !(lib.hasInfix bundle extra);
        }
      ];

  failed = builtins.filter (c: !c.ok) cases;

  varsSh = "${cfg.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
  varsFish = "${cfg.programs.fish.sessionVariablesPackage}/etc/profile.d/hm-session-vars.fish";
in
assert lib.assertMsg (failed == [ ])
  "os-ca-bundle-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "os-ca-bundle-state" { } (
  ''
    echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ''
  + lib.optionalString isLinux ''
    names=(${lib.escapeShellArgs names})

    # 束のパスを $2 に置き換えた hm-session-vars を、引数の NAME=VALUE だけを env にした shell で読む。
    # 子の printenv で見た 4 つの値 (無ければ unset) を「名前=値 」の形で 1 行に並べる (export されたかも見る)
    seen() {
      local shell=$1 path=$2
      shift 2
      case $shell in
        bash)
          sed "s|${bundle}|$path|g" ${varsSh} >vars.sh
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.bash.package} --noprofile --norc \
            -c '. ./vars.sh; for n in '"''${names[*]}"'; do printf "%s=%s " "$n" "$(printenv "$n" || echo unset)"; done'
          ;;
        fish)
          sed "s|${bundle}|$path|g" ${varsFish} >vars.fish
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.fish.package} --no-config \
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
      local shell=$1 label=$2 path=$3 want=$4 got
      shift 4
      got=$(seen "$shell" "$path" "$@")
      if [[ $got != "$want" ]]; then
        echo "os-ca-bundle-state: $shell ($label) が「$want」でなく「$got」" >&2
        exit 1
      fi
      echo "ok   $shell ($label): $got"
    }

    have=$TMPDIR/ca.crt
    touch "$have"
    missing=$TMPDIR/missing.crt
    for shell in bash fish; do
      expect "$shell" "束がある" "$have" "$(want "$have" "$have" "$have" "$have")"
      expect "$shell" "束が無い" "$missing" "$(want unset unset unset unset)"
      expect "$shell" "SSL_CERT_FILE がすでにある" "$have" \
        "$(want /opt/corp.pem /opt/corp.pem /opt/corp.pem /opt/corp.pem)" SSL_CERT_FILE=/opt/corp.pem
      expect "$shell" "NIX_SSL_CERT_FILE だけがすでにある" "$have" \
        "$(want /opt/nix.pem /opt/nix.pem /opt/nix.pem /opt/nix.pem)" NIX_SSL_CERT_FILE=/opt/nix.pem
      expect "$shell" "両方がすでにある" "$have" \
        "$(want /opt/nix.pem /opt/corp.pem /opt/corp.pem /opt/corp.pem)" NIX_SSL_CERT_FILE=/opt/nix.pem SSL_CERT_FILE=/opt/corp.pem
      expect "$shell" "REQUESTS_CA_BUNDLE が空" "$have" "$(want "$have" "$have" "$have" "$have")" REQUESTS_CA_BUNDLE=
      expect "$shell" "SSL_CERT_FILE に空白がある" "$have" \
        "$(want "/opt/a b.pem" "/opt/a b.pem" "/opt/a b.pem" "/opt/a b.pem")" "SSL_CERT_FILE=/opt/a b.pem"
    done
  ''
  + ''
    touch $out
  ''
)
