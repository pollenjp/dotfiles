# ホストの要約 (nix/lib/host-summary/。mkHome が hostSummary として足す) を、評価時に確かめる (ADR 057・093)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (host-summary-state) から呼ぶ。
# 図を描く JS (page.js) の並び・配置・囲みは、node のテスト (host-summary-page.test.mjs) が見る。
#
# ## 確かめること
#
#   - どこで決まったか: グループを書かないホストのグループは「選んでいない」(unset)、company の ③ の段はグループの既定 (group) で
#     off、② の道具は段の既定 (tier)、ホストのファイルで書いた道具はホスト (host)、dotfiles-private の nix/shared/ の module で
#     書いた値は shared。既定が段によらない道具と ① の道具は既定 (default)
#   - 既定 (書かなかったときの値): ホストで on にした ③ の道具の既定は company なら off。Windows の道具は、段の既定が on でも
#     効く条件 (wsl.windowsFiles.enable) の既定が off なので、既定では効かない (defaultEffective が false)。段の switch をホストで
#     書いても、段から決まる道具の既定はグループの段の既定で決まる (company で ③ の段を on にしたホストの ntn の既定は off、
#     personal で ② の段を off にしたホストの claude の既定は on)
#   - 効く条件 (wsl.windowsFiles.enable) が off の Windows の道具は、値が on でも「–」(効かない) で、off の条件の名前を持つ
#   - 図の列: ① の道具は c1、② は c2、② と ③ の両方は c23、③ は c3。どの道具も箱に出す短い名前を持つ。groups.nix の runnerTools
#     は全部が表の道具で、runner の印の数と同じ
#   - pages (setup.sh が比べる 1 台ぶん) は nix/<名前>.md と nix/html/<名前>.html だけで、files (summaries が書く全部) の同じ
#     ファイルと 1 字も違わない
#   - md は h1 (code span のホスト名) から始まり、3 行目が HTML 版の跡の行 (Notion に写す道具が h1 の下に行を足せるように)、
#     ホストの値のファイルへの相対のリンク・グループ・ホストで決めた値・効かない道具の理由・生成物の断り (末尾) を持つ
#   - HTML 版は doctype と charset から始まる 1 ファイルで、外のファイルを読まない。#data の JSON は < を逃がしてあり、読み直すと
#     タブ (このホスト・既定・重ねて比べる)・列・28 の道具・option の頭 (dotfiles.) を持つ。リンクは新しいタブで開く GitHub の URL
#   - winData: グループ・[tools] の上書き (host) とグループの既定 (group)・効く条件 (opReasonSshRelay は onePassword) で効かない道具・
#     runner の道具だけ・図に描けない値 (受け持ち・鍵の本数とコメント (鍵そのものは出さない)・ユーザー・送り元の数)。group を書かない
#     ホストは personal で unset。知らないグループ・知らない道具・bool でない道具の値は評価で止める。図の段の説明は、① が「どのグループ
#     でも」、② ③ はグループの既定 (Windows のホストは段の option を持たないが、① と取り違えない)
#   - files: 入口 (README.md と html/hosts.html)・Nix と Windows のホストのページを出し、入口の表で同じ PC (@ の後ろを小文字で比べる)
#     の Nix と Windows のホストを結ぶ。入口の図は Nix と Windows の 2 つで、重ねるタブは 2 台以上のときだけ。ホストが 0 台でも
#     README.md と html/hosts.html だけを出す (「ありません」)
#   - 名前に空白を含むホスト (Windows のユーザー名の空白が、runner の読むファイル名に入る): md のリンク先 (HTML 版の跡の行・ホストの
#     値・入口の表のホストのページ) と HTML 版の href (blob の URL) は空白を %20 にし、@ はそのまま。リンクの字 (h1・リンクの字・
#     code) は空白のまま。files の md のリンク先と HTML 版の href に空白は無い (GitHub でも Notion に写す道具でもリンクになる)
#   - line は グループと段を 1 行にし、text は効かない道具に off の条件を添える
{
  lib,
  pkgs,
  mkHome,
  system,
  hostSummary,
  privateHosts,
  windowsHosts,
  windowsGroups,
}:

let
  groups = import ../lib/groups.nix;

  hostWith =
    args:
    mkHome (
      {
        username = "tester";
        inherit system;
      }
      // args
    );
  dataOf = args: (hostWith args).hostSummary.data;
  rowOf = d: key: builtins.head (builtins.filter (r: r.key == key) d.tools);
  tierOf = d: name: builtins.head (builtins.filter (t: t.name == name) d.tiers);

  unset = dataOf { };
  company = dataOf { group = "company"; };
  # 段の switch をホストで書いたホスト
  companyTier3 = dataOf {
    group = "company";
    modules = [ { dotfiles.personalAccounts.enable = true; } ];
  };
  personalNoAi = dataOf { modules = [ { dotfiles.aiTools.enable = false; } ]; };

  # ホストのファイルと shared/ (fixtures/host-summary) から組み立てた、自社のホスト
  private = privateHosts ./fixtures/host-summary;
  carol = private."carol@three";
  carolData = carol.hostSummary.data;
  carolPages = carol.hostSummary.pages "carol@three";
  carolMd = carolPages.nix."carol@three.md";
  carolHtml = carolPages.nix.html."carol@three.html";

  # Windows のホスト (fixtures/host-summary/win-hosts)
  winHosts = windowsHosts ./fixtures/host-summary/win-hosts;
  dave = hostSummary.winData windowsGroups "dave@three" winHosts."dave@three";
  erin = hostSummary.winData windowsGroups "erin@four" winHosts."erin@four";
  throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;

  files = hostSummary.files {
    hosts = private;
    inherit winHosts windowsGroups;
  };

  # HTML 版の #data の JSON
  dataOfHtml =
    html:
    builtins.fromJSON (
      builtins.head (
        lib.splitString "</script>" (
          builtins.elemAt (lib.splitString ''<script type="application/json" id="data">'' html) 1
        )
      )
    );
  carolFig = builtins.head (dataOfHtml carolHtml).figures;
  indexFigs = (dataOfHtml files.html."hosts.html").figures;
  lines = s: lib.splitString "\n" s;
  hrefs =
    html:
    builtins.filter (s: s != "") (
      map (x: builtins.head (lib.splitString "\"" x)) (builtins.tail (lib.splitString "href=\"" html))
    );
  # md のリンク先 (`](` の後ろから `)` まで)
  mdDests =
    md: map (x: builtins.head (lib.splitString ")" x)) (builtins.tail (lib.splitString "](" md));
  # files の葉 (docs/hosts/ からの path と中身)
  leaves =
    prefix: attrs:
    lib.concatLists (
      lib.mapAttrsToList (
        n: v:
        if builtins.isString v then
          [
            {
              path = prefix + n;
              text = v;
            }
          ]
        else
          leaves "${prefix}${n}/" v
      ) attrs
    );
  mdFiles = builtins.filter (f: lib.hasSuffix ".md" f.path) (leaves "" files);
  htmlFiles = builtins.filter (f: lib.hasSuffix ".html" f.path) (leaves "" files);

  # 名前に空白を含む Windows のホスト (fixtures/host-summary/win-hosts/Frank Example@three.toml)
  frankMd = files.win."Frank Example@three.md";
  frankHtml = files.win.html."Frank Example@three.html";

  cases = [
    {
      name = "グループを書かないホストのグループは「選んでいない」(unset)、line にもそう出る";
      ok =
        unset.group == {
          value = "personal";
          source = "unset";
        }
        && lib.hasInfix "選んでいない" ((hostWith { }).hostSummary.line);
    }
    {
      name = "company の ③ の段はグループの既定で off、② の段はグループの既定で on";
      ok =
        (tierOf company "personalAccounts").value == false
        && (tierOf company "personalAccounts").source == "group"
        && (tierOf company "personalAccounts").default == false
        && (tierOf company "aiTools").value == true;
    }
    {
      name = "② の道具は段の既定 (tier)、既定が段によらない道具と ① の道具は既定 (default)";
      ok =
        (rowOf company "claude").source == "tier"
        && (rowOf company "ntn").source == "tier"
        && (rowOf company "ntn").value == false
        && (rowOf company "onePassword").source == "default"
        && (rowOf company "cleanup").source == "default";
    }
    {
      name = "ホストのファイルで書いた道具は host、nix/shared/ で書いた値は shared";
      ok =
        carolData.group.source == "host"
        && (rowOf carolData "ntn").source == "host"
        && (rowOf carolData "ntn").value
        && (rowOf carolData "claudePrivateSkills").source == "host"
        && (rowOf carolData "cleanup").source == "shared"
        && (rowOf carolData "cleanup").value == false;
    }
    {
      name = "既定: ホストで on にした ③ の道具の既定は off、Windows の道具は既定では効かない (windowsFiles の既定が off)";
      ok =
        (rowOf carolData "ntn").default == false
        && !(rowOf carolData "ntn").defaultEffective
        && (rowOf carolData "claude").default
        && (rowOf carolData "claude").defaultEffective
        && (rowOf carolData "windowsClaudeCode").effective
        && (rowOf carolData "windowsClaudeCode").default
        && !(rowOf carolData "windowsClaudeCode").defaultEffective
        && (rowOf carolData "cleanup").default;
    }
    {
      name = "段の switch をホストで書いても、段から決まる道具の既定はグループの段の既定 (company の ③ の道具は off、personal の ② の道具は on)";
      ok =
        (tierOf companyTier3 "personalAccounts").value
        && (tierOf companyTier3 "personalAccounts").source == "host"
        && (tierOf companyTier3 "personalAccounts").default == false
        && (rowOf companyTier3 "ntn").value
        && (rowOf companyTier3 "ntn").source == "tier"
        && (rowOf companyTier3 "ntn").default == false
        && !(rowOf companyTier3 "ntn").defaultEffective
        && (rowOf companyTier3 "claudePrivateSkills").default == false
        && (rowOf companyTier3 "claude").default
        && (rowOf personalNoAi "claude").value == false
        && (rowOf personalNoAi "claude").default
        && (rowOf personalNoAi "claude").defaultEffective;
    }
    {
      name = "windowsFiles が off の Windows の道具は、値が on でも「–」(効かない) で、off の条件の名前を持つ";
      ok =
        (rowOf unset "windowsClaudeCode").value
        && (rowOf unset "windowsClaudeCode").blocked
        && (rowOf unset "windowsClaudeCode").requiresOff == [ "wsl.windowsFiles.enable" ]
        && !(rowOf carolData "windowsNtn").blocked;
    }
    {
      name = "図の列は ①→c1・②→c2・②③→c23・③→c3 で、どの道具も短い名前を持つ。runnerTools は表の道具で、runner の印と同じ数";
      ok =
        (rowOf carolData "wsl").column == "c1"
        && (rowOf carolData "claude").column == "c2"
        && (rowOf carolData "claudePrivateSkills").column == "c23"
        && (rowOf carolData "ntn").column == "c3"
        && builtins.all (r: r.short != "") carolData.tools
        && builtins.all (k: builtins.any (t: t.key == k) groups.tools) groups.runnerTools
        &&
          builtins.length (builtins.filter (t: t.runner) groups.tools) == builtins.length groups.runnerTools;
    }
    {
      name = "pages は nix/<名前>.md と nix/html/<名前>.html だけで、files の同じファイルと同じ";
      ok =
        builtins.attrNames carolPages == [ "nix" ]
        &&
          builtins.attrNames carolPages.nix == [
            "carol@three.md"
            "html"
          ]
        && builtins.attrNames carolPages.nix.html == [ "carol@three.html" ]
        && files.nix."carol@three.md" == carolMd
        && files.nix.html."carol@three.html" == carolHtml;
    }
    {
      name = "md は h1 から始まり 3 行目が HTML 版の跡の行で、ホストの値へのリンク・グループ・ホストで決めた値・効かない理由・生成物の断りを持つ";
      ok =
        builtins.elemAt (lines carolMd) 0 == "# `carol@three`"
        && builtins.elemAt (lines carolMd) 1 == ""
        && builtins.elemAt (lines carolMd) 2 == "🌐 [HTML 版: carol@three の道具](./html/carol@three.html)"
        && lib.hasInfix "[`nix/hosts/carol@three.nix`](../../../nix/hosts/carol@three.nix)" carolMd
        && lib.hasInfix "- グループ: `company` (ホストで選んだ) · ① on · ② on · ③ off\n" carolMd
        && lib.hasInfix "ntn (Notion の CLI) on" carolMd
        && lib.hasInfix "dotfiles-private の `nix/shared/` で決めた値: 使わない store path・mise の版の掃除 off" carolMd
        && !(lib.hasInfix "効かない道具" carolMd)
        &&
          lib.hasInfix
            "- 効かない道具 (値は on だが、効く条件が off): Windows の Claude Code (`dotfiles.wsl.windowsFiles.enable` が off)"
            ((hostWith { }).hostSummary.pages "tester@box").nix."tester@box.md"
        && lib.hasSuffix "skill pjp-dotfiles-register-host)。\n" carolMd
        && !(lib.hasInfix "<!--" carolMd);
    }
    {
      name = "HTML 版は doctype と charset から始まる 1 ファイルで、外のファイルを読まず、リンクは新しいタブで開く GitHub の URL";
      ok =
        lib.hasPrefix "<!doctype html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">" carolHtml
        && !(lib.hasInfix "<script src" carolHtml)
        && !(lib.hasInfix "<link " carolHtml)
        && !(lib.hasInfix "@@" carolHtml)
        && builtins.all (h: lib.hasPrefix "https://github.com/pollenjp/" h) (hrefs carolHtml)
        &&
          builtins.length (lib.splitString "target=\"_blank\" rel=\"noopener\"" carolHtml)
          == builtins.length (hrefs carolHtml) + 1
        && lib.hasInfix "https://github.com/pollenjp/dotfiles-private/blob/main/nix/hosts/carol@three.nix" carolHtml;
    }
    {
      name = "#data の JSON は < を逃がしてあり、タブ・列・28 の道具・dotfiles. の頭の option を持つ";
      ok =
        !(lib.hasInfix "</" (
          builtins.head (
            lib.splitString "</script>" (builtins.elemAt (lib.splitString ''id="data">'' carolHtml) 1)
          )
        ))
        &&
          map (v: v.id) carolFig.views == [
            "host"
            "default"
            "both"
          ]
        &&
          map (c: c.id) carolFig.columns == [
            "c1"
            "c2"
            "c23"
            "c3"
          ]
        && builtins.length (builtins.attrNames carolFig.tools) == builtins.length groups.tools
        && carolFig.tools.ntn.option == "dotfiles.ntn.enable"
        &&
          (builtins.elemAt carolFig.views 0).tools.ntn == {
            v = true;
            e = true;
            s = "host";
            t = "ホストのファイル";
            d = false;
            off = [ ];
          }
        && (builtins.elemAt carolFig.views 1).tools.ntn.e == false;
    }
    {
      name = "winData: グループ・[tools] の上書き・グループの既定・効く条件 (onePassword) と、runner の道具だけ";
      ok =
        dave.group == {
          value = "company";
          source = "host";
        }
        && (rowOf dave "windowsNtn").source == "host"
        && (rowOf dave "windowsNtn").effective
        && (rowOf dave "windowsNtn").default == false
        && (rowOf dave "windowsClaudeCode").source == "group"
        && (rowOf dave "windowsClaudeCode").effective
        && (rowOf dave "opReasonSshRelay").blocked
        && (rowOf dave "opReasonSshRelay").requiresOff == [ "[tools] onePassword" ]
        && (rowOf dave "windowsClaudeAccounts").requires == [ "[tools] windowsClaudeCode" ]
        &&
          map (r: r.key) dave.tools
          == builtins.filter (k: builtins.elem k groups.runnerTools) (map (t: t.key) groups.tools)
        && (tierOf dave "personalAccounts").value == false
        && dave.runner;
    }
    {
      name = "winData: 図に描けない値 (受け持ち・鍵の本数とコメントだけ・ユーザー・送り元の数)。group を書かなければ personal で unset";
      ok =
        let
          v = k: (builtins.head (builtins.filter (x: lib.hasInfix k x.k) dave.extras)).v;
        in
        lib.hasPrefix "runner" (v "[runner]")
        && v "authorizedKeys" == "1 本 (コメント: dave@example)"
        && !(lib.hasInfix "AAAA" (builtins.toJSON dave))
        && v "allowUsers" == "dave"
        && v "allowFrom" == "1 個"
        &&
          erin.group == {
            value = "personal";
            source = "unset";
          }
        && (rowOf erin "windowsTypeClipboard").source == "host"
        && !erin.runner;
    }
    {
      name = "Windows のホストの図の段の説明は、① が「どのグループでも」、② ③ はグループの既定";
      ok =
        let
          host = builtins.head (builtins.head (dataOfHtml files.win.html."dave@three.html").figures).views;
        in
        host.tiers.engineer.text == "どのグループでも"
        && host.tiers.aiTools.text == "グループ (company) の既定"
        && host.tiers.personalAccounts.text == "グループ (company) の既定"
        && host.tiers.personalAccounts.source == "group";
    }
    {
      name = "winData: 知らないグループ・知らない道具・bool でない道具の値は評価で止める";
      ok =
        throws (hostSummary.winData windowsGroups "x@y" { group = "nope"; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.noSuchTool = true; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.windowsNtn = "yes"; });
    }
    {
      name = "files: 入口・Nix と Windows のホストのページを出し、入口の表で同じ PC の Nix と Windows のホストを結ぶ";
      ok =
        builtins.attrNames files == [
          "README.md"
          "html"
          "nix"
          "win"
        ]
        && builtins.attrNames files.html == [ "hosts.html" ]
        &&
          builtins.attrNames files.win == [
            "Frank Example@three.md"
            "dave@three.md"
            "erin@four.md"
            "html"
          ]
        && lib.hasPrefix "# 登録したホストの道具\n\n🌐 [HTML 版: 登録したホストの道具](./html/hosts.html)\n" files."README.md"
        &&
          lib.hasInfix "| [`carol@three`](./nix/carol@three.md) | `company` (ホストで選んだ) | on · on · off |"
            files."README.md"
        && lib.hasInfix "| [`dave@three`](./win/dave@three.md) |" files."README.md"
        && lib.hasInfix "[`dave@three`](./win/dave@three.md) |\n" files."README.md"
        &&
          lib.hasInfix "| [`erin@four`](./win/erin@four.md) | `personal` (選んでいない。既定) | WSL の setup |"
            files."README.md"
        && lib.hasInfix "(書き方は dotfiles の `win/README.md` の「ホストの値」)" files.win."dave@three.md"
        &&
          lib.hasInfix "- sshd に入れる鍵 ([sshd] authorizedKeys): 1 本 (コメント: dave@example)\n"
            files.win."dave@three.md";
    }
    {
      name = "入口の図は Nix と Windows の 2 つで、重ねるタブは 2 台以上のときだけ";
      ok =
        map (f: f.id) indexFigs == [
          "nix"
          "win"
        ]
        && map (v: v.kind) (builtins.head indexFigs).views == [ "host" ]
        &&
          map (v: v.kind) (builtins.elemAt indexFigs 1).views == [
            "host"
            "host"
            "host"
            "overlay"
          ]
        && (builtins.elemAt indexFigs 1).order == "count";
    }
    {
      name = "名前に空白を含むホスト: md と HTML 版のリンク先は空白を %20 にし (@ はそのまま)、リンクの字は空白のまま";
      ok =
        builtins.elemAt (lines frankMd) 0 == "# `Frank Example@three`"
        &&
          builtins.elemAt (lines frankMd) 2
          == "🌐 [HTML 版: Frank Example@three の道具 (Windows)](./html/Frank%20Example@three.html)"
        && lib.hasInfix "[`win/hosts/Frank Example@three.toml`](../../../win/hosts/Frank%20Example@three.toml)" frankMd
        &&
          lib.hasInfix
            "| [`Frank Example@three`](./win/Frank%20Example@three.md) | `company` (ホストで選んだ) | WSL の setup |"
            files."README.md"
        &&
          lib.hasInfix
            "| [`Frank Example@three`](./win/Frank%20Example@three.md)・[`dave@three`](./win/dave@three.md) |\n"
            files."README.md"
        && lib.hasInfix ''<a href="https://github.com/pollenjp/dotfiles-private/blob/main/win/hosts/Frank%20Example@three.toml" target="_blank" rel="noopener"><code>win/hosts/Frank Example@three.toml</code></a>'' frankHtml
        &&
          lib.hasInfix
            ''<a href="https://github.com/pollenjp/dotfiles-private/blob/main/docs/hosts/win/Frank%20Example@three.md" target="_blank" rel="noopener"><code>Frank Example@three</code></a>''
            files.html."hosts.html";
    }
    {
      name = "files の md のリンク先と HTML 版の href に空白は無い";
      ok =
        builtins.any (f: builtins.any (lib.hasInfix "%20") (mdDests f.text)) mdFiles
        && builtins.all (f: builtins.all (u: !(lib.hasInfix " " u)) (mdDests f.text)) mdFiles
        && builtins.any (f: builtins.any (lib.hasInfix "%20") (hrefs f.text)) htmlFiles
        && builtins.all (f: builtins.all (u: !(lib.hasInfix " " u)) (hrefs f.text)) htmlFiles;
    }
    {
      name = "ホストが 0 台でも、files は README.md と html/hosts.html だけを出す (「ありません」)";
      ok =
        let
          empty = hostSummary.files {
            hosts = { };
            inherit windowsGroups;
          };
        in
        builtins.attrNames empty == [
          "README.md"
          "html"
        ]
        && lib.hasInfix "登録したホストはありません。" empty."README.md"
        && (dataOfHtml empty.html."hosts.html").figures == [ ];
    }
    {
      name = "line はグループと段を 1 行にし、text は効かない道具に off の条件を添える";
      ok =
        (hostWith { group = "client"; }).hostSummary.line
        == "client (ホストで選んだ) · ① エンジニアの道具 on · ② AI の道具 off · ③ 個人のアカウント off"
        &&
          lib.hasInfix "Windows の Claude Code: – (wsl.windowsFiles.enable が off なので効かない)"
            (hostWith { }).hostSummary.text;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "host-summary-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "host-summary-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
