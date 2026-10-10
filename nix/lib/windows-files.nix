# win/manifest.toml から、Windows 側へ配る計画を作る (docs/adr/010_win_files_from_wsl_*)。
#
# 呼ぶのは nix/scripts/bootstrap-windows-files.sh だけで、flake (home-manager) からは
# 呼ばない。ローカル flake は本体を path:<repo>/nix で読むので、その評価からは repo 直下の
# win/ が見えないため (ADR 010 §1 の 3)。script は checkout の win/ を渡して、
#
#   nix-instantiate --eval --strict --json nix/lib/windows-files.nix \
#     --argstr winDir <repo>/win --argstr windowsHome /mnt/c/Users/<名前>
#
# で呼ぶ。nixpkgs を引かずに済むよう builtins だけで書く (0.04 秒ほどで返る)。
# --strict で全部の値を評価させるので、下の検証はどれも throw で止まる。
#
# 返り値:
#
#   {
#     version = 1;
#     files = [
#       {
#         src = "<winDir>/orca/keybindings.json";             # コピー元 (絶対パス)
#         repoPath = "win/orca/keybindings.json";             # repo からの相対パス (案内用)
#         dst = "/mnt/c/Users/<名前>/.orca/keybindings.json"; # 置き先 (絶対パス)
#         hint = "…";                                         # 置き先を書き換えたときに出す文。無ければ null
#       }
#     ];
#   }
{ winDir, windowsHome }:

let
  fail = msg: throw "win/manifest.toml: ${msg}";

  concat = builtins.concatStringsSep ", ";

  isAbs = s: builtins.substring 0 1 s == "/";

  # "a/b" -> [ "a" "b" ]。"a//b" や末尾の "/" は "" の要素として残る。
  segments = s: builtins.filter builtins.isString (builtins.split "/" s);

  # 空の要素・"."・".." を含まないか。
  cleanSegments = s: builtins.all (x: x != "" && x != "." && x != "..") (segments s);

  hasBackslash = s: builtins.replaceStrings [ "\\" ] [ "" ] s != s;

  # Windows (NTFS) は大文字小文字を区別しないので、dst の重複は小文字にして比べる。
  letters = s: builtins.genList (i: builtins.substring i 1 s) 26;
  toLower = builtins.replaceStrings (letters "ABCDEFGHIJKLMNOPQRSTUVWXYZ") (
    letters "abcdefghijklmnopqrstuvwxyz"
  );

  roots = {
    "%USERPROFILE%" = windowsHome;
    "%APPDATA%" = "${windowsHome}/AppData/Roaming";
    "%LOCALAPPDATA%" = "${windowsHome}/AppData/Local";
  };

  manifestFile = "${winDir}/manifest.toml";

  manifest =
    if !isAbs winDir then
      fail "winDir は絶対パスで渡してください: ${winDir}"
    else if !isAbs windowsHome then
      fail "windowsHome は絶対パスで渡してください: ${windowsHome}"
    else if !builtins.pathExists (/. + manifestFile) then
      fail "見つかりません: ${manifestFile}"
    else
      builtins.fromTOML (builtins.readFile (/. + manifestFile));

  unknownTop = builtins.filter (k: k != "files") (builtins.attrNames manifest);

  entries =
    if unknownTop != [ ] then
      fail "知らないキーがあります: ${concat unknownTop} (書けるのは [[files]] だけ)"
    else if !builtins.isList (manifest.files or [ ]) then
      fail "files は [[files]] の表の並びで書いてください"
    else
      manifest.files or [ ];

  # i はメッセージ用の 1 始まりの番号。
  toFile =
    i: f:
    let
      at = "files[${toString i}]";
      unknown = builtins.filter (
        k:
        !builtins.elem k [
          "src"
          "dst"
          "hint"
        ]
      ) (builtins.attrNames f);
      srcPath = /. + "${winDir}/${f.src}";
      m = builtins.match "(%[A-Z]+%)/(.*)" f.dst;
      root = builtins.elemAt m 0;
      rest = builtins.elemAt m 1;
    in
    if !builtins.isAttrs f then
      fail "${at}: [[files]] の表で書いてください"
    else if unknown != [ ] then
      fail "${at}: 知らないキーがあります: ${concat unknown} (書けるのは src / dst / hint)"
    else if !(f ? src && f ? dst) then
      fail "${at}: src と dst は必須です"
    else if
      !(builtins.isString f.src && builtins.isString f.dst && builtins.isString (f.hint or ""))
    then
      fail "${at}: src / dst / hint は文字列で書いてください"
    else if hasBackslash f.src then
      fail "${at}: src に \\ は書けません (区切りは /): ${f.src}"
    else if isAbs f.src then
      fail "${at}: src は win/ からの相対パスで書いてください: ${f.src}"
    else if !cleanSegments f.src then
      fail "${at}: src に空の要素・.・.. は書けません: ${f.src}"
    else if !(builtins.pathExists srcPath && builtins.readFileType srcPath == "regular") then
      fail "${at}: src が見つからないか、通常のファイルではありません: win/${f.src}"
    else if hasBackslash f.dst then
      fail "${at}: dst に \\ は書けません (区切りは /): ${f.dst}"
    else if m == null || !(roots ? ${root}) then
      fail "${at}: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: ${f.dst}"
    else if !cleanSegments rest then
      fail "${at}: dst に空の要素・.・.. は書けません: ${f.dst}"
    else
      {
        src = "${winDir}/${f.src}";
        repoPath = "win/${f.src}";
        dst = "${roots.${root}}/${rest}";
        hint = f.hint or null;
      };

  files = builtins.genList (i: toFile (i + 1) (builtins.elemAt entries i)) (builtins.length entries);

  lowered = map (f: toLower f.dst) files;
  dupes = builtins.filter (d: builtins.length (builtins.filter (x: x == d) lowered) > 1) lowered;
  uniq =
    xs:
    builtins.attrNames (
      builtins.listToAttrs (
        map (x: {
          name = x;
          value = null;
        }) xs
      )
    );
in
{
  version = 1;
  files =
    if dupes != [ ] then fail "dst が重複しています (Windows は大文字小文字を区別しない): ${concat (uniq dupes)}" else files;
}
