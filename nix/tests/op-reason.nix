# WSL + 1Password のマシンにだけ入る op と pjp-op-log (home/modules/op-reason.nix・pkgs/pjp-op) と、Claude の hook に知らせる
# claude-op-reason.json を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の `nix flake check --all-systems --no-build`
# (全 system の評価) でも落ちる。flake.nix の checks (op-reason-state) から呼ぶ。ビルドして確かめる項目は Linux の checks に
# だけ置く (WSL は Linux)。動きそのものは pjp-op.test.sh・pjp-op-launcher.test.sh・pjp-op-log.test.sh が確かめる。
#
# ## 確かめること
#
#   評価時 (assert)
#     - wsl.enable と onePassword.enable が両方 true のマシンの home.packages に op (mainProgram) の package が 1 つ入る
#     - WSL だけ・1Password だけ・どちらも無しのマシンには入らない
#     - claude-op-reason.json は、入るマシンで {"enable":true}、ほかで {"enable":false}。どちらも改行で終わる
#     - Claude の hook (op-reason-guard.sh) は、入らないマシンにも repo の script から実行できるファイルとして置かれる
#       (hook は claude-op-reason.json を読んで黙る)
#   ビルド時 (このランナーの system だけ)
#     - 入るマシンの profile の bin/op と bin/pjp-op-log は、この package のもの
#     - 入らないマシンの profile に bin/op は無い
#     - profile の op は、呼ぶ側の PATH に何も無くても (runtimeInputs で足りる) 動き、op.exe が無ければ 127 で終わって、
#       断ったことを記録に書く
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
  wslOnly = configWith { wsl.enable = true; };
  opOnly = configWith { onePassword.enable = true; };
  plain = configWith { };

  isOp = p: (p.meta.mainProgram or null) == "op";
  opOf = cfg: builtins.filter isOp cfg.home.packages;
  state = cfg: cfg.home.file.".local/state/dotfiles/claude-op-reason.json".text;
  hook = cfg: cfg.home.file.".claude/hooks/op-reason-guard.sh";

  cases = [
    {
      name = "WSL + 1Password のマシンの home.packages に op の package が 1 つ入る";
      ok = lib.length (opOf wslOp) == 1;
    }
    {
      name = "WSL だけ・1Password だけ・どちらも無しのマシンには入らない";
      ok = opOf wslOnly == [ ] && opOf opOnly == [ ] && opOf plain == [ ];
    }
    {
      name = "claude-op-reason.json は入るマシンで {\"enable\":true}";
      ok = builtins.fromJSON (state wslOp) == { enable = true; };
    }
    {
      name = "claude-op-reason.json は入らないマシンで {\"enable\":false}";
      ok = lib.all (cfg: builtins.fromJSON (state cfg) == { enable = false; }) [
        wslOnly
        opOnly
        plain
      ];
    }
    {
      name = "claude-op-reason.json は改行で終わる";
      ok = lib.hasSuffix "\n" (state wslOp) && lib.hasSuffix "\n" (state plain);
    }
    {
      name = "hook は入るマシンにも入らないマシンにも、repo の script から実行できるファイルとして置かれる";
      ok =
        lib.all
          (
            cfg:
            (hook cfg).executable && "${(hook cfg).source}" == "${../files/claude/hooks/op-reason-guard.sh}"
          )
          [
            wslOp
            plain
          ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
  buildChecks = pkgs.stdenv.hostPlatform.isLinux;
in
assert lib.assertMsg (failed == [ ])
  "op-reason-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "op-reason-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ${lib.optionalString buildChecks ''
    pkg=${lib.head (opOf wslOp)}
    for bin in op pjp-op-log; do
      got=$(readlink -f ${wslOp.home.path}/bin/$bin)
      if [[ $got != "$(readlink -f "$pkg/bin/$bin")" ]]; then
        echo "op-reason-state: 入るマシンの profile の bin/$bin が $pkg のものでなく $got" >&2
        exit 1
      fi
    done
    echo "ok   入るマシンの profile の bin/op と bin/pjp-op-log は、この package のもの"

    if [[ -e ${plain.home.path}/bin/op ]]; then
      echo "op-reason-state: 入らないマシンの profile に bin/op がある" >&2
      exit 1
    fi
    echo "ok   入らないマシンの profile に bin/op は無い"

    rc=0
    env -i PATH=/nonexistent HOME="$TMPDIR" ${wslOp.home.path}/bin/op --reason "試す" item get x \
      >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -q 'op.exe' "$TMPDIR/err" \
      || ! grep -q '"why":"no-op-exe"' "$TMPDIR/.local/state/pjp-op/log.jsonl"; then
      echo "op-reason-state: PATH の無い op が 127 で断って記録に書かない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    echo "ok   profile の op は PATH が無くても動き、op.exe が無ければ 127 で断って記録に書く"
  ''}
  touch $out
''
