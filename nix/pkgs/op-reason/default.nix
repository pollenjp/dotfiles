# op-reason (1Password CLI の wrapper。呼ぶ理由を必須にし、承認を呼び出しごとに閉じる自作の OSS。pollenjp/op-reason) の WSL の側。
#
# GitHub の Release に置いた静的な実行ファイル (musl。op-reason-<arch>-linux) を、版と system ごとの SHA-256 で固定して入れる。
# SHA-256 は Release の隣の .sha256 の値。Windows の側 (op-reason-windows.zip の op-reason.exe と launcher.ps1) は
# win/op-reason/Install-OpReason.ps1 が同じ版で入れ、WSL の実行ファイルはそれを起こして窓を出す。呼び出しの取り決め (payload の版。
# 0.1.0 から 0.8.1 まで同じ 1) が変わった版どうしでは断るので、版を上げるときは version とこの表を、Install-OpReason.ps1 の表と同じ
# PR で上げる (手順は nix/README.md の「op-reason の新しい版を出したとき」)。
#
# op-reason の flake (packages.op) を input にしないのは、flake-lock-age.sh が github の input に commit から 7 日の猶予を課すため
# (公開したばかりの版では update が止まり、CI の lock-age が落ちる。release-age.nix の例外は nixpkgs にしか効かない)。自作の
# アプリの Release なので、type-clipboard (win/README.md の「type-clipboard」) と同じく公開からの猶予は置かず、中身を SHA-256 で
# 固定する。依存の更新 (.claude/skills/pjp-dotfiles-deps) も、ここは見ない (deps.toml の skip)。
#
# 1 つの実行ファイルを呼び名で切り替える: op と op-reason は wrapper、op-reason-log は記録を見る道具、op-reason-ssh (0.4.0 から) は
# Windows の ssh.exe を呼び出しの事実 (OPREASON_SSH_CALL) を付けて起こす入口 (op-reason.exe --ssh-agent の SSH の中継に呼び手を
# 知らせる。引数と stdin・stdout・stderr はそのまま)。bin/op・bin/op-reason-log・bin/op-reason-ssh は bin/op-reason への symlink。
# SSH の中継を使うホスト (dotfiles.opReason.sshRelay) では WSL の ssh の wrapper が op-reason-ssh を起こし、中継は Windows の op-reason 自身の
# task が起こす (Windows の runner が op-reason.exe --settings で揃える)。ほかのホストでは op-reason-ssh は名前を置くだけ。fish の補完 (op と op-reason の 2 つ。op を呼ばない) は、入れた実行ファイルに --completion fish で
# 出させて share/fish/vendor_completions.d に置く。マシンごとの既定 (Windows の op-reason.exe の場所 OPREASON_EXE) は、ここには
# 入れず home/modules/op-reason.nix が包む。
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.8.1";
  # system → Release の asset の名前と、その .sha256 の値
  # (https://github.com/pollenjp/op-reason/releases/download/v<version>/<name>.sha256)
  assets = {
    x86_64-linux = {
      name = "op-reason-x86_64-linux";
      sha256 = "fe1115153a7ab45508f2e93d21bcb2f1a78a5a6d57590970465e4587e571d4fc";
    };
    aarch64-linux = {
      name = "op-reason-aarch64-linux";
      sha256 = "badb41d3a7a9afad70c67b5cb3f198356c8368ddbe0286248b8830893d780cb1";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset =
    assets.${system}
      or (throw "op-reason ${version}: ${system} の配布物は無い (WSL の Linux の x86_64 と aarch64 だけ)");
in
stdenvNoCC.mkDerivation {
  pname = "op-reason";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pollenjp/op-reason/releases/download/v${version}/${asset.name}";
    inherit (asset) sha256;
  };

  # 静的リンクの実行ファイルを、そのまま置く
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/op-reason"
    ln -s op-reason "$out/bin/op"
    ln -s op-reason "$out/bin/op-reason-log"
    ln -s op-reason "$out/bin/op-reason-ssh"
    # 補完を出すのは op-reason --completion で、op.exe も記録も触らない。念のため HOME を build の一時ディレクトリへ向ける
    export HOME=$TMPDIR
    mkdir -p "$out/share/fish/vendor_completions.d"
    "$out/bin/op-reason" --completion fish op >"$out/share/fish/vendor_completions.d/op.fish"
    "$out/bin/op-reason" --completion fish op-reason >"$out/share/fish/vendor_completions.d/op-reason.fish"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    got=$("$out/bin/op-reason" --version)
    if [[ $got != "op-reason ${version}" ]]; then
      echo "op-reason --version が「op-reason ${version}」でなく「$got」 (Release の asset と version が食い違う)" >&2
      exit 1
    fi

    # op-reason-ssh の名で起こすと、OPREASON_SSH_EXE の ssh.exe (ここでは偽物) を引数そのままで起こし、その終了コードで終わる
    printf '#!%s\nprintf "%%s\\n" "$@" >"%s/ssh-args"\nexit 7\n' "$BASH" "$TMPDIR" >"$TMPDIR/ssh.exe"
    chmod +x "$TMPDIR/ssh.exe"
    rc=0
    OPREASON_SSH_EXE="$TMPDIR/ssh.exe" "$out/bin/op-reason-ssh" -o "BatchMode yes" host true || rc=$?
    if [[ $rc != 7 ]] || [[ $(cat "$TMPDIR/ssh-args") != $'-o\nBatchMode yes\nhost\ntrue' ]]; then
      echo "op-reason-ssh が OPREASON_SSH_EXE の ssh.exe を引数そのままで起こさない (rc=$rc): $(cat "$TMPDIR/ssh-args" 2>/dev/null)" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Wrapper for the 1Password CLI on WSL: every call gives a reason and gets its own approval";
    homepage = "https://github.com/pollenjp/op-reason";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "op";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
