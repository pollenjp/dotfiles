# 1Password を使うマシンにだけ入る pjp-op-env・pjp-op-ref (home/modules/op-env.nix・pkgs/pjp-op-env・pkgs/pjp-op-ref) を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の `nix flake check --all-systems --no-build`
# (全 system の評価) でも落ちる。flake.nix の checks (op-env-state) から呼ぶ。ビルドして確かめる項目は Linux の checks にだけ
# 置く。動きそのものは pjp-op-env.test.sh・pjp-op-ref.test.sh が確かめる。
#
# ## 確かめること
#
#   評価時 (assert)
#     - onePassword.enable のマシン (WSL もそれ以外も) の home.packages に pjp-op-env と pjp-op-ref (mainProgram) の package が
#       1 つずつ入る
#     - WSL だけ・どちらも無しのマシンには入らない
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - 入るマシンの profile の bin/pjp-op-env・bin/pjp-op-ref は、この package のもの。入らないマシンの profile には無い
#     - profile の pjp-op-env は、呼ぶ側の PATH が空でも --dry-run で .env の名前と種類を出して 0 で終わり、参照でない値は出さない
#     - 参照のある .env で op が PATH に無ければ、pjp-op-env は 127 で終わって program を起こさない
#     - profile の pjp-op-ref は、呼ぶ側の PATH に偽の op しか無くても (jq は package が足す)、名前の参照を ID の参照に直し、値を
#       出さない。op が PATH に無ければ 127
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    args:
    (mkHome (
      {
        username = "tester";
        inherit system;
      }
      // args
    )).config;

  wslOp = configWith {
    wsl = {
      enable = true;
      windowsUserName = "alice";
    };
    onePassword.enable = true;
  };
  opOnly = configWith { onePassword.enable = true; };
  wslOnly = configWith { wsl.enable = true; };
  plain = configWith { };

  isProgram = name: p: (p.meta.mainProgram or null) == name;
  opEnvOf = cfg: builtins.filter (isProgram "pjp-op-env") cfg.home.packages;
  opRefOf = cfg: builtins.filter (isProgram "pjp-op-ref") cfg.home.packages;

  cases = [
    {
      name = "onePassword.enable のマシン (WSL もそれ以外も) の home.packages に pjp-op-env が 1 つ入る";
      ok = lib.length (opEnvOf wslOp) == 1 && lib.length (opEnvOf opOnly) == 1;
    }
    {
      name = "onePassword.enable のマシン (WSL もそれ以外も) の home.packages に pjp-op-ref が 1 つ入る";
      ok = lib.length (opRefOf wslOp) == 1 && lib.length (opRefOf opOnly) == 1;
    }
    {
      name = "WSL だけ・どちらも無しのマシンには入らない";
      ok =
        opEnvOf wslOnly == [ ] && opEnvOf plain == [ ] && opRefOf wslOnly == [ ] && opRefOf plain == [ ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
  buildChecks = pkgs.stdenv.hostPlatform.isLinux;
in
assert lib.assertMsg (failed == [ ])
  "op-env-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "op-env-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ${lib.optionalString buildChecks ''
    for prog in pjp-op-env pjp-op-ref; do
      case $prog in
        pjp-op-env) pkg=${lib.head (opEnvOf opOnly)} ;;
        pjp-op-ref) pkg=${lib.head (opRefOf opOnly)} ;;
      esac
      got=$(readlink -f ${opOnly.home.path}/bin/$prog)
      if [[ $got != "$(readlink -f "$pkg/bin/$prog")" ]]; then
        echo "op-env-state: 入るマシンの profile の bin/$prog が $pkg のものでなく $got" >&2
        exit 1
      fi
      if [[ -e ${plain.home.path}/bin/$prog ]]; then
        echo "op-env-state: 入らないマシンの profile に bin/$prog がある" >&2
        exit 1
      fi
    done
    echo "ok   入るマシンの profile の bin/pjp-op-env・bin/pjp-op-ref はこの package のもので、入らないマシンには無い"

    mkdir -p "$TMPDIR/proj"
    printf '%s\n' 'A=op://Test/a/password' 'PLAIN=plain-value-hidden' >"$TMPDIR/proj/.env"
    rc=0
    (cd "$TMPDIR/proj" && env -i PATH=/nonexistent HOME="$TMPDIR" ${opOnly.home.path}/bin/pjp-op-env --dry-run) \
      >"$TMPDIR/dry.out" 2>"$TMPDIR/dry.err" || rc=$?
    if [[ $rc != 0 ]] || ! grep -qF 'op://Test/a/password' "$TMPDIR/dry.out" || grep -qF 'plain-value-hidden' "$TMPDIR/dry.out"; then
      echo "op-env-state: PATH の無い pjp-op-env --dry-run が合わない (rc=$rc): $(cat "$TMPDIR/dry.out" "$TMPDIR/dry.err")" >&2
      exit 1
    fi
    echo "ok   profile の pjp-op-env は PATH が空でも --dry-run で名前と種類を出し、参照でない値は出さない"

    rc=0
    (cd "$TMPDIR/proj" && env -i PATH=/nonexistent HOME="$TMPDIR" ${opOnly.home.path}/bin/pjp-op-env --reason "試す" \
      -- ${pkgs.coreutils}/bin/touch "$TMPDIR/started") >"$TMPDIR/run.out" 2>"$TMPDIR/run.err" || rc=$?
    if [[ $rc != 127 || -e $TMPDIR/started ]] || ! grep -qF 'op' "$TMPDIR/run.err"; then
      echo "op-env-state: op の無い pjp-op-env が 127 で止まらない (rc=$rc): $(cat "$TMPDIR/run.err")" >&2
      exit 1
    fi
    echo "ok   参照のある .env で op が PATH に無ければ、127 で終わって program を起こさない"

    # 偽の op は bash の組み込みだけで、op item get --format json の形の 1 項目を出す (ID は作り物、値は S3CR3T)
    mkdir -p "$TMPDIR/fakeop"
    {
      printf '#!%s\n' ${pkgs.runtimeShell}
      printf '%s\n' "printf '%s\n' '{\"id\":\"itemid00000000000000000001\",\"title\":\"Example Service\",\"vault\":{\"id\":\"vaultid0000000000000000001\",\"name\":\"Dev\"},\"fields\":[{\"id\":\"password\",\"type\":\"CONCEALED\",\"label\":\"password\",\"value\":\"S3CR3T-value\"}]}'"
    } >"$TMPDIR/fakeop/op"
    chmod +x "$TMPDIR/fakeop/op"
    rc=0
    env -i PATH="$TMPDIR/fakeop" HOME="$TMPDIR" ${opOnly.home.path}/bin/pjp-op-ref --reason "試す" \
      "op://Dev/Example Service/password" >"$TMPDIR/ref.out" 2>"$TMPDIR/ref.err" || rc=$?
    if [[ $rc != 0 || $(<"$TMPDIR/ref.out") != op://vaultid0000000000000000001/itemid00000000000000000001/password ]] \
      || grep -qF S3CR3T "$TMPDIR/ref.out" "$TMPDIR/ref.err"; then
      echo "op-env-state: 偽の op だけの PATH の pjp-op-ref が合わない (rc=$rc): $(cat "$TMPDIR/ref.out" "$TMPDIR/ref.err")" >&2
      exit 1
    fi
    echo "ok   profile の pjp-op-ref は、PATH に偽の op しか無くても名前の参照を ID の参照に直し、値を出さない"

    rc=0
    env -i PATH=/nonexistent HOME="$TMPDIR" ${opOnly.home.path}/bin/pjp-op-ref --reason "試す" "op://Dev/Example Service/password" \
      >"$TMPDIR/refnoop.out" 2>"$TMPDIR/refnoop.err" || rc=$?
    if [[ $rc != 127 || -s $TMPDIR/refnoop.out ]] || ! grep -qF 'op (1Password CLI)' "$TMPDIR/refnoop.err"; then
      echo "op-env-state: op の無い pjp-op-ref が 127 で止まらない (rc=$rc): $(cat "$TMPDIR/refnoop.err")" >&2
      exit 1
    fi
    echo "ok   op が PATH に無ければ、pjp-op-ref は 127 で終わる"
  ''}
  touch $out
''
