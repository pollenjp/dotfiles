# WSL + 1Password のマシンにだけ入る op・op-reason・op-reason-log (home/modules/op-reason.nix が pkgs/op-reason を包んだもの) と、
# Claude の hook に知らせる claude-op-reason.json を確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の `nix flake check --all-systems --no-build`
# (全 system の評価) でも落ちる。flake.nix の checks (op-reason-state) から呼ぶ。ビルドして確かめる項目は Linux の checks に
# だけ置く (WSL は Linux)。wrapper そのものの動き (理由・lock・窓・記録・補完) は op-reason の repo のテストが確かめる。
#
# ## 確かめること
#
#   評価時 (assert)
#     - wsl.enable と onePassword.enable が両方 true のマシンの home.packages に op (mainProgram) の package が 1 つ入る
#     - WSL だけ・1Password だけ・どちらも無しのマシンには入らない
#     - 包みが既定にする OPREASON_EXE は、Install-OpReason.ps1 の既定の置き場所 (%LOCALAPPDATA%\Programs\op-reason) の op-reason.exe
#       を、wsl.windowsUserName (無ければ wsl.onePassword.windowsUserName) で組み立てた WSL のパス
#     - claude-op-reason.json は、入るマシンで {"enable":true}、ほかで {"enable":false}。どちらも改行で終わる
#     - Claude の hook (op-reason-guard.sh) は、入らないマシンにも repo の script から実行できるファイルとして置かれる
#       (hook は claude-op-reason.json を読んで黙る)
#     - fish の op と op-reason の補完 (~/.config/fish/completions/op.fish・op-reason.fish) は入るマシンにだけ置き、中身は
#       pkgs/op-reason が出したもの (ほかのマシンは fish に同梱の op の補完のまま)
#   ビルド時 (このランナーの system だけ)
#     - 入るマシンの profile の bin/op・bin/op-reason・bin/op-reason-log は、この包みのもの。入らないマシンの profile に bin/op は無い
#     - profile の op-reason --version は、呼ぶ側の PATH に何も無くても pkgs/op-reason の版を出す
#     - profile の op は、op.exe が無ければ 127 で断り、op-reason の記録 (~/.local/state/op-reason/log.jsonl) に refused の
#       no-op-exe を書く。包みは表示の言語を決めない (OPREASON_LANG が無ければ英語で、LANG=ja_JP.UTF-8 でも英語。
#       OPREASON_LANG=ja なら日本語。op-reason は 0.2.0 から LANG などで決めない)
#     - op.exe があって op-reason.exe が無ければ、既定の OPREASON_EXE の場所を断りの文に出して 127 (no-exe)。環境に
#       OPREASON_EXE があれば、そちらを探す (既定は --set-default)
#     - profile の op-reason-log は、呼び名どおり記録を見る道具として動き、上の断りを表に出す
#     - 置いた補完を fish が読むと、op を呼ばずに op <Tab> の候補 (item など) と --reason を出す
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
  # 1Password だけ別の Windows のユーザー名を書いたマシン (wsl.windowsUserName が無い)
  wslOpOnly1p = configWith {
    wsl = {
      enable = true;
      onePassword.windowsUserName = "bob";
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
  fishCompletion = cfg: name: cfg.xdg.configFile."fish/completions/${name}.fish" or null;
  hasFishCompletion = cfg: fishCompletion cfg "op" != null || fishCompletion cfg "op-reason" != null;
  exeFor = user: "/mnt/c/Users/${user}/AppData/Local/Programs/op-reason/op-reason.exe";

  # 入るマシンの op の package (無ければ null。無いことは最初の項目で落とすので、ほかの項目は null で投げずに外れにする)
  opPkg =
    cfg:
    let
      found = opOf cfg;
    in
    if found == [ ] then null else lib.head found;
  pkg = opPkg wslOp;
  unwrapped = pkg.unwrapped;

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
      name = "OPREASON_EXE の既定は Install-OpReason.ps1 の既定の置き場所の op-reason.exe (wsl.windowsUserName か wsl.onePassword.windowsUserName)";
      ok =
        pkg != null
        && opPkg wslOpOnly1p != null
        && pkg.exePath == exeFor "alice"
        && (opPkg wslOpOnly1p).exePath == exeFor "bob";
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
    {
      name = "fish の op と op-reason の補完は入るマシンにだけ置き、中身は pkgs/op-reason が出したもの";
      ok =
        pkg != null
        && fishCompletion wslOp "op" != null
        && fishCompletion wslOp "op-reason" != null
        # 中身のパスは op-reason の package の出力で、package は Linux にしか無い (ほかの system で評価すると止まる)
        && (
          !buildChecks
          || (
            "${(fishCompletion wslOp "op").source}" == "${unwrapped}/share/fish/vendor_completions.d/op.fish"
            &&
              "${(fishCompletion wslOp "op-reason").source}"
              == "${unwrapped}/share/fish/vendor_completions.d/op-reason.fish"
          )
        )
        && !(hasFishCompletion wslOnly)
        && !(hasFishCompletion opOnly)
        && !(hasFishCompletion plain);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
  buildChecks = pkgs.stdenv.hostPlatform.isLinux;
in
assert lib.assertMsg (failed == [ ])
  "op-reason-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "op-reason-state" { nativeBuildInputs = lib.optional buildChecks pkgs.fish; } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  ${lib.optionalString buildChecks ''
    profile=${wslOp.home.path}
    for bin in op op-reason op-reason-log; do
      got=$(readlink -f "$profile/bin/$bin")
      if [[ $got != "$(readlink -f "${pkg}/bin/$bin")" ]]; then
        echo "op-reason-state: 入るマシンの profile の bin/$bin が ${pkg} のものでなく $got" >&2
        exit 1
      fi
    done
    echo "ok   入るマシンの profile の bin/op・bin/op-reason・bin/op-reason-log は、この包みのもの"

    if [[ -e ${plain.home.path}/bin/op ]]; then
      echo "op-reason-state: 入らないマシンの profile に bin/op がある" >&2
      exit 1
    fi
    echo "ok   入らないマシンの profile に bin/op は無い"

    got=$(env -i PATH=/nonexistent HOME="$TMPDIR/v" "$profile/bin/op-reason" --version)
    if [[ $got != "op-reason ${unwrapped.version}" ]]; then
      echo "op-reason-state: profile の op-reason --version が「op-reason ${unwrapped.version}」でなく「$got」" >&2
      exit 1
    fi
    echo "ok   profile の op-reason --version は、PATH が無くても pkgs/op-reason の版を出す"

    # op.exe が無い: 127 で断り、記録に no-op-exe。包みは言語を決めない (OPREASON_LANG が無ければ英語で、LANG=ja_JP.UTF-8 でも
    # 英語。OPREASON_LANG=ja なら日本語。窓で選んだ言語の控え (~/.local/state/op-reason/lang.json) は、この HOME には無い)
    home=$TMPDIR/h1
    mkdir -p "$home"
    rc=0
    env -i PATH=/nonexistent HOME="$home" "$profile/bin/op" --reason "試す" item get x >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -q 'op.exe was not found' "$TMPDIR/err" \
      || ! grep -q '"why":"no-op-exe"' "$home/.local/state/op-reason/log.jsonl"; then
      echo "op-reason-state: op.exe の無い op が 127 で英語の断りを出して記録に書かない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    rc=0
    env -i PATH=/nonexistent HOME="$home" LANG=ja_JP.UTF-8 "$profile/bin/op" --reason "試す" item get x \
      >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -q 'op.exe was not found' "$TMPDIR/err"; then
      echo "op-reason-state: LANG=ja_JP.UTF-8 の op が 127 で英語の断りを出さない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    rc=0
    env -i PATH=/nonexistent HOME="$home" OPREASON_LANG=ja "$profile/bin/op" --reason "試す" item get x \
      >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -q 'op.exe が見つかりません' "$TMPDIR/err"; then
      echo "op-reason-state: OPREASON_LANG=ja の op が 127 で日本語の断りを出さない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    if [[ -e $home/.local/state/op-reason/lang.json ]]; then
      echo "op-reason-state: 断っただけの op が、窓で選んだ言語の控え (lang.json) を書いた" >&2
      exit 1
    fi
    echo "ok   profile の op は、op.exe が無ければ 127 で断り、記録に no-op-exe を書く。言語は LANG で決まらず (英語)、OPREASON_LANG=ja なら日本語"

    # op.exe はあるが op-reason.exe が無い: 既定の OPREASON_EXE の場所を断りの文に出す。環境の OPREASON_EXE が勝つ
    touch "$TMPDIR/op.exe"
    rc=0
    env -i PATH=/nonexistent HOME="$home" OPREASON_OP_EXE="$TMPDIR/op.exe" "$profile/bin/op" --reason "試す" item get x \
      >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -qF '${pkg.exePath}' "$TMPDIR/err" \
      || ! grep -q '"why":"no-exe"' "$home/.local/state/op-reason/log.jsonl"; then
      echo "op-reason-state: op-reason.exe の無い op が既定の場所を出して 127 (no-exe) で終わらない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    rc=0
    env -i PATH=/nonexistent HOME="$home" OPREASON_OP_EXE="$TMPDIR/op.exe" OPREASON_EXE=/x/op-reason.exe \
      "$profile/bin/op" --reason "試す" item get x >"$TMPDIR/out" 2>"$TMPDIR/err" || rc=$?
    if [[ $rc != 127 ]] || ! grep -qF '(/x/op-reason.exe)' "$TMPDIR/err"; then
      echo "op-reason-state: 環境の OPREASON_EXE が既定に勝たない (rc=$rc): $(cat "$TMPDIR/err")" >&2
      exit 1
    fi
    echo "ok   op-reason.exe が無ければ既定の OPREASON_EXE の場所を出して 127 (no-exe)。環境の OPREASON_EXE が勝つ"

    if ! env -i PATH=/nonexistent HOME="$home" "$profile/bin/op-reason-log" --all >"$TMPDIR/log" 2>&1 \
      || ! grep -qF 'no op-reason.exe' "$TMPDIR/log"; then
      echo "op-reason-state: op-reason-log が記録の表を出さない: $(cat "$TMPDIR/log")" >&2
      exit 1
    fi
    echo "ok   profile の op-reason-log は記録を見る道具として動き、上の断りを表に出す"

    # 置いた補完を fish の補完の置き場の頭に足し、偽の op (呼ばれたら印を書いて 2 で終わる) で op <Tab> の候補を見る
    mkdir -p "$TMPDIR/comp" "$TMPDIR/bin" "$TMPDIR/fish-home"
    cp ${(fishCompletion wslOp "op").source} "$TMPDIR/comp/op.fish"
    printf '#!%s\necho called >>%s/op.calls\nexit 2\n' "$BASH" "$TMPDIR" >"$TMPDIR/bin/op"
    chmod +x "$TMPDIR/bin/op"
    HOME="$TMPDIR/fish-home" PATH="$TMPDIR/bin:$PATH" \
      fish --no-config -c 'set -p fish_complete_path $argv[1]; complete -C "op "' "$TMPDIR/comp" >"$TMPDIR/cand"
    cut -f1 "$TMPDIR/cand" >"$TMPDIR/cand1"
    if ! grep -qx 'item' "$TMPDIR/cand1" || ! grep -qx -- '--reason' "$TMPDIR/cand1" || [[ -e $TMPDIR/op.calls ]]; then
      echo "op-reason-state: 置いた fish の補完で op <Tab> が item と --reason を出さないか、op を呼んだ: $(cat "$TMPDIR/cand1")" >&2
      exit 1
    fi
    echo "ok   置いた fish の補完は、op を呼ばずに op <Tab> の候補 (item と --reason) を出す"
  ''}
  touch $out
''
