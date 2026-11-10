# 1Password を使うマシンにだけ入る pjp-op-env (home/modules/op-env.nix・pkgs/pjp-op-env) を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の `nix flake check --all-systems --no-build`
# (全 system の評価) でも落ちる。flake.nix の checks (op-env-state) から呼ぶ。ビルドして確かめる項目は Linux の checks にだけ
# 置く。動きそのものは pjp-op-env.test.sh が確かめる。
#
# ## 確かめること
#
#   評価時 (assert)
#     - onePassword.enable のマシン (WSL もそれ以外も) の home.packages に pjp-op-env (mainProgram) の package が 1 つ入る
#     - WSL だけ・どちらも無しのマシンには入らない
#   ビルド時 (このランナーの system が Linux のときだけ)
#     - 入るマシンの profile の bin/pjp-op-env は、この package のもの。入らないマシンの profile には無い
#     - profile の pjp-op-env は、呼ぶ側の PATH が空でも --dry-run で .env の名前と種類を出して 0 で終わり、参照でない値は出さない
#     - 参照のある .env で op が PATH に無ければ、127 で終わって program を起こさない
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

  isOpEnv = p: (p.meta.mainProgram or null) == "pjp-op-env";
  opEnvOf = cfg: builtins.filter isOpEnv cfg.home.packages;

  cases = [
    {
      name = "onePassword.enable のマシン (WSL もそれ以外も) の home.packages に pjp-op-env が 1 つ入る";
      ok = lib.length (opEnvOf wslOp) == 1 && lib.length (opEnvOf opOnly) == 1;
    }
    {
      name = "WSL だけ・どちらも無しのマシンには入らない";
      ok = opEnvOf wslOnly == [ ] && opEnvOf plain == [ ];
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
    pkg=${lib.head (opEnvOf opOnly)}
    got=$(readlink -f ${opOnly.home.path}/bin/pjp-op-env)
    if [[ $got != "$(readlink -f "$pkg/bin/pjp-op-env")" ]]; then
      echo "op-env-state: 入るマシンの profile の bin/pjp-op-env が $pkg のものでなく $got" >&2
      exit 1
    fi
    if [[ -e ${plain.home.path}/bin/pjp-op-env ]]; then
      echo "op-env-state: 入らないマシンの profile に bin/pjp-op-env がある" >&2
      exit 1
    fi
    echo "ok   入るマシンの profile の bin/pjp-op-env はこの package のもので、入らないマシンには無い"

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
  ''}
  touch $out
''
