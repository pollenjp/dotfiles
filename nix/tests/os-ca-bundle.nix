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
#       あるときだけの if があり、その中で 4 つを、値が無い (空を含む) ときだけ束のパスにして export する
#     - darwin には、その if を置かない
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - home の hm-session-vars.sh を bash で、babelfish で fish に直した hm-session-vars.fish を fish で読む
#       (束のパスは、ビルドの中に作ったファイルか、無いパスに置き換える):
#       - 束があれば、4 つとも束のパスになる
#       - 束が無ければ、4 つとも立たない
#       - すでに値がある変数はその値のまま、空の変数は束のパスになる
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

  # if の行から fi の行までを取り出す。if の行が無ければ null。if の行は os-ca-bundle.nix に書いた行と
  # 1 文字も違わないこと
  ifLine = "if [ -f ${bundle} ]; then";
  block =
    let
      lines = lib.splitString "\n" extra;
      from = lib.lists.findFirstIndex (l: l == ifLine) null lines;
      rest = lib.drop from lines;
      to = lib.lists.findFirstIndex (l: l == "fi") null rest;
    in
    if from == null || to == null then null else lib.concatStringsSep "\n" (lib.take (to + 1) rest);

  cases =
    if isLinux then
      [
        {
          name = "Linux の hm-session-vars.sh の末尾に、${bundle} があるときだけの if がある";
          ok = block != null;
        }
      ]
      ++ map (n: {
        name = "その if の中で、${n} を値が無いときだけ束のパスにして export する";
        ok = block != null && lib.hasInfix "export ${n}=\"\${${n}:-${bundle}}\"" block;
      }) names
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

    # 束のパスを $2 に置き換えた hm-session-vars を、引数の NAME=VALUE だけを env にした shell で読み、
    # 4 つの値 (無ければ unset) を「名前=値 」の形で 1 行に並べる
    seen() {
      local shell=$1 path=$2
      shift 2
      case $shell in
        bash)
          sed "s|${bundle}|$path|g" ${varsSh} >vars.sh
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.bash.package} --noprofile --norc \
            -c '. ./vars.sh; for n in '"''${names[*]}"'; do printf "%s=%s " "$n" "''${!n-unset}"; done'
          ;;
        fish)
          sed "s|${bundle}|$path|g" ${varsFish} >vars.fish
          env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.fish.package} --no-config \
            -c 'source ./vars.fish; for n in '"''${names[*]}"'; printf "%s=%s " $n (set -q $n; and echo $$n; or echo unset); end'
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
      expect "$shell" "SSL_CERT_FILE がすでにある" "$have" "$(want "$have" /opt/corp.pem "$have" "$have")" \
        SSL_CERT_FILE=/opt/corp.pem
      expect "$shell" "REQUESTS_CA_BUNDLE が空" "$have" "$(want "$have" "$have" "$have" "$have")" REQUESTS_CA_BUNDLE=
    done
  ''
  + ''
    touch $out
  ''
)
