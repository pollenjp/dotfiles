# herdr の pane の中だけ FORCE_HYPERLINK=1 を export する、fish の interactiveShellInit と bash の initExtra の
# ブロックを確かめる (TKT-270)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (herdr-hyperlink-state) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert)
#     - fish の interactiveShellInit と bash の initExtra に、HERDR_ENV が空でなく FORCE_HYPERLINK が無いときだけ
#       FORCE_HYPERLINK=1 を export するブロックがある
#   ビルド時 (このランナーの system だけ)
#     - 取り出したブロックを home の fish と bash で流すと、HERDR_ENV=1 なら子のプロセスに FORCE_HYPERLINK=1 が渡る
#     - HERDR_ENV が無い・空なら、FORCE_HYPERLINK は立たない
#     - HERDR_ENV=1 でも、すでに FORCE_HYPERLINK=0 があれば 0 のまま
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

  fishInit = cfg.programs.fish.interactiveShellInit;
  bashInit = cfg.programs.bash.initExtra;

  # init の中の、if の行から閉じる行 (fish は end、bash は fi) までを取り出す。if の行が無ければ null
  blockOf =
    text: first: last:
    let
      lines = lib.splitString "\n" text;
      from = lib.lists.findFirstIndex (l: l == first) null lines;
      rest = lib.drop from lines;
      to = lib.lists.findFirstIndex (l: l == last) null rest;
    in
    if from == null || to == null then null else lib.concatStringsSep "\n" (lib.take (to + 1) rest);

  # ブロックの if の行。fish.nix・bash.nix に書いた行と 1 文字も違わないこと
  fishIf = ''if test -n "$HERDR_ENV"; and not set -q FORCE_HYPERLINK'';
  bashIf = ''if [[ -n "''${HERDR_ENV:-}" && -z "''${FORCE_HYPERLINK+set}" ]]; then'';
  fishBlock = blockOf fishInit fishIf "end";
  bashBlock = blockOf bashInit bashIf "fi";

  cases = [
    {
      name = "fish の interactiveShellInit に、HERDR_ENV があって FORCE_HYPERLINK が無いときだけ立てるブロックがある";
      ok = fishBlock != null && lib.hasInfix "set -gx FORCE_HYPERLINK 1" fishBlock;
    }
    {
      name = "bash の initExtra に、HERDR_ENV があって FORCE_HYPERLINK が無いときだけ立てるブロックがある";
      ok = bashBlock != null && lib.hasInfix "export FORCE_HYPERLINK=1" bashBlock;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "herdr-hyperlink-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "herdr-hyperlink-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  printf '%s\n' ${lib.escapeShellArg fishBlock} >block.fish
  printf '%s\n' ${lib.escapeShellArg bashBlock} >block.bash

  # ブロックを流した shell の子 (printenv) から見た FORCE_HYPERLINK。無ければ unset。
  # 引数の NAME=VALUE だけを env にして流す
  seen() {
    local shell=$1
    shift
    case $shell in
      fish)
        env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.fish.package} --no-config \
          -c 'source ./block.fish; printenv FORCE_HYPERLINK; or echo unset'
        ;;
      bash)
        env -i HOME="$TMPDIR" PATH=${pkgs.coreutils}/bin "$@" ${lib.getExe cfg.programs.bash.package} --noprofile --norc \
          -c 'source ./block.bash; printenv FORCE_HYPERLINK || echo unset'
        ;;
    esac
  }
  expect() {
    local shell=$1 want=$2 label=$3 got
    shift 3
    got=$(seen "$shell" "$@")
    if [[ $got != "$want" ]]; then
      echo "herdr-hyperlink-state: $shell ($label) の FORCE_HYPERLINK が $want でなく $got" >&2
      exit 1
    fi
    echo "ok   $shell ($label) の FORCE_HYPERLINK は $want"
  }
  for shell in fish bash; do
    expect "$shell" 1 "HERDR_ENV=1" HERDR_ENV=1
    expect "$shell" unset "HERDR_ENV が無い"
    expect "$shell" unset "HERDR_ENV が空" HERDR_ENV=
    expect "$shell" 0 "HERDR_ENV=1 で FORCE_HYPERLINK=0 がある" HERDR_ENV=1 FORCE_HYPERLINK=0
  done
  touch $out
''
