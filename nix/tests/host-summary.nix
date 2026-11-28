# ホストの要約 (nix/lib/host-summary/。mkHome が hostSummary として足す) を、評価時に確かめる (ADR 057・093・109)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (host-summary-state) から呼ぶ。
# 図を描く JS (page.js) の並び・配置・囲みは、node のテスト (host-summary-page.test.mjs) が見る。
#
# ## 確かめること
#
#   - どこで決まったか: グループを書かないホストのグループは「選んでいない」(unset) で minimum。道具の値はグループの既定 (group)・
#     ホストのファイル (host)・dotfiles-private の nix/shared/ の module (shared)・従う道具 (follows。linger は herdrCore) のどれか
#   - 既定 (道具を何も書かなかったときの値。グループと環境はホストのまま): minimum のホストで足した道具の既定は off、minimum の道具は on。
#     all のホストでも、環境 (WSL か・win/ を配るか) が合わない道具の既定は off
#   - 「–」(効かない): all で環境が合わない道具 (WSL でない Linux の Windows の道具・WSL だけの道具、win/ を配る WSL の SSH の中継) と、
#     ホストで on にしたのに環境が合わない道具 (win/ を配らないホストの Windows の ntn) は「–」で、合わない条件の文を持つ。グループに入らない
#     道具の off は「–」でない
#   - 図の列: 基本の道具 (base)・minimum の道具の switch (min)・all の道具 2 列 (a1・a2)・Windows の道具 (win)。どの道具も箱に出す短い名前を
#     持つ。groups.nix の runnerTools は全部が表の道具か runner だけの道具 (runnerOnlyTools) で、runner の印と runner だけの道具の数の和
#   - pages (setup.sh が比べる 1 台ぶん) は nix/<名前>.md と nix/html/<名前>.html だけで、files (summaries が書く全部) の同じ
#     ファイルと 1 字も違わない
#   - md は h1 (code span のホスト名) から始まり、3 行目が HTML 版の跡の行 (Notion に写す道具が h1 の下に行を足せるように)、
#     ホストの値のファイルへの相対のリンク・グループと環境・ホストで決めた値・効かない道具の理由・生成物の断り (末尾) を持つ
#   - HTML 版は doctype と charset から始まる 1 ファイルで、外のファイルを読まない。#data の JSON は < を逃がしてあり、読み直すと
#     タブ (このホスト・既定・重ねて比べる)・領域 (minimum ⊂ all)・列・基本の道具と表の全部の道具・option の頭 (dotfiles.) を持つ。
#     リンクは新しいタブで開く GitHub の URL
#   - winData: グループ・[tools] の上書き (host) とグループの既定 (group)・効く条件 (opReasonSshRelay は onePassword と privateRepos) で効かない
#     道具・runner の道具だけ (runner だけが読む privateRepos の行は最後で、効く条件は無い)・図に描けない値 (受け持ち・鍵の本数とコメント
#     (鍵そのものは出さない)・ユーザー・送り元の数)。group を書かないホストは minimum で unset。やめたグループ (company など)・知らない
#     グループ・知らない道具・bool でない道具の値と、runner の止める条件 (groups.nix の runnerDeps) の要る道具が off なのにそれが要る道具が
#     on のホスト (privateRepos が off で claudePrivateSkills・opReasonSshRelay が on。all に privateRepos = false だけを書いたホストも。
#     herdrHub が on で windowsClaudeCode か windowsHerdr が off) は評価で止める。herdrHub は privateRepos が off でも、windowsClaudeCode と
#     windowsHerdr が on なら止めない。図の領域の値は、minimum がいつも on、all はグループが all のときだけ on
#   - files: 入口 (README.md と html/hosts.html)・Nix と Windows のホストのページを出し、入口の表で同じ PC (@ の後ろを小文字で比べる)
#     の Nix と Windows のホストを結ぶ。入口の図は Nix と Windows の 2 つで、重ねるタブは 2 台以上のときだけ。ホストが 0 台でも
#     README.md と html/hosts.html だけを出す (「ありません」)
#   - 名前に空白を含むホスト (Windows のユーザー名の空白が、runner の読むファイル名に入る): md のリンク先 (HTML 版の跡の行・ホストの
#     値・入口の表のホストのページ) と HTML 版の href (blob の URL) は空白を %20 にし、@ はそのまま。リンクの字 (h1・リンクの字・
#     code) は空白のまま。files の md のリンク先と HTML 版の href に空白は無い (GitHub でも Notion に写す道具でもリンクになる)
#   - line はグループと環境を 1 行にし、text は効かない道具に合わない条件を添える
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

  wslWin = {
    enable = true;
    windowsUserName = "tester";
    windowsFiles.enable = true;
  };
  unset = dataOf { };
  # all を選んだホスト (WSL で win/ を配る・WSL でない Linux)
  allWsl = dataOf {
    group = "all";
    wsl = wslWin;
    claude.notion.profile = "personal";
  };
  allLinux = dataOf {
    group = "all";
    claude.notion.profile = "personal";
  };
  # win/ を配らないのに Windows の ntn を on にしたホスト (効かない)
  winNtnNoFiles = {
    group = "minimum";
    wsl.windowsFiles.ntn.enable = true;
  };
  winNtnNoFilesData = dataOf winNtnNoFiles;

  # ホストのファイルと shared/ (fixtures/host-summary) から組み立てた、minimum に道具を足したホスト
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
      name = "グループを書かないホストのグループは「選んでいない」(unset) で minimum、line にもそう出る";
      ok =
        unset.group == {
          value = "minimum";
          source = "unset";
        }
        && lib.hasInfix "選んでいない" ((hostWith { }).hostSummary.line);
    }
    {
      name = "道具の値は、グループの既定 (group)・ホストのファイル (host)・nix/shared/ (shared)・従う道具 (follows) で決まる";
      ok =
        (rowOf unset "claude").source == "group"
        && !(rowOf unset "claude").value
        && (rowOf unset "cleanup").source == "group"
        && (rowOf unset "cleanup").value
        && carolData.group.source == "host"
        && (rowOf carolData "ntn").source == "host"
        && (rowOf carolData "ntn").value
        && (rowOf carolData "claudePrivateSkills").source == "host"
        && (rowOf carolData "cleanup").source == "shared"
        && (rowOf carolData "cleanup").value == false
        && (rowOf carolData "linger").source == "follows"
        && (rowOf carolData "linger").follows == "herdrCore.enable"
        && (rowOf allLinux "claude").source == "group"
        && (rowOf allLinux "claude").value;
    }
    {
      name = "既定: minimum のホストで足した道具の既定は off、minimum の道具は on。all でも環境が合わない道具の既定は off";
      ok =
        (rowOf carolData "ntn").default == false
        && !(rowOf carolData "ntn").defaultEffective
        && (rowOf carolData "claude").default == false
        && (rowOf carolData "windowsNtn").effective
        && (rowOf carolData "windowsNtn").default == false
        && (rowOf carolData "cleanup").default
        && (rowOf allWsl "windowsClaudeCode").default
        && (rowOf allWsl "exeExecTrace").default
        && !(rowOf allLinux "windowsClaudeCode").default
        && (rowOf allLinux "windowsClaudeCode").defaultBlocked
        && !(rowOf allLinux "exeExecTrace").default;
    }
    {
      name = "all で環境が合わない道具と、ホストで on にしたのに環境が合わない道具は「–」で、合わない条件の文を持つ";
      ok =
        (rowOf allLinux "windowsClaudeCode").blocked
        && (rowOf allLinux "windowsClaudeCode").envOff == [ "win/ を配らない" ]
        && (rowOf allLinux "exeExecTrace").blocked
        && (rowOf allLinux "exeExecTrace").envOff == [ "WSL でない" ]
        && (rowOf allWsl "opReasonSshRelay").blocked
        && (rowOf allWsl "opReasonSshRelay").envOff == [ "win/ を配る (Windows は WSL の setup)" ]
        && !(rowOf allWsl "windowsClaudeCode").blocked
        && (rowOf allWsl "windowsClaudeCode").effective
        && (rowOf winNtnNoFilesData "windowsNtn").value
        && (rowOf winNtnNoFilesData "windowsNtn").blocked
        && (rowOf winNtnNoFilesData "windowsNtn").source == "host"
        && !(rowOf unset "claude").blocked
        && !(rowOf carolData "windowsNtn").blocked;
    }
    {
      name = "図の列は base・min・a1・a2・win で、どの道具も短い名前を持つ。runnerTools は表の道具か runner だけの道具で、runner の印と runner だけの道具の数の和";
      ok =
        map (c: c.id) carolFig.columns == [
          "base"
          "min"
          "a1"
          "a2"
          "win"
        ]
        && builtins.elem "claude" (builtins.elemAt carolFig.columns 2).tools
        && builtins.elem "windowsNtn" (builtins.elemAt carolFig.columns 4).tools
        &&
          (builtins.elemAt carolFig.columns 1).tools == [
            "osCaBundle"
            "cleanup"
          ]
        && builtins.all (r: r.short != "") carolData.tools
        && builtins.all (
          k: builtins.any (t: t.key == k) (groups.tools ++ groups.runnerOnlyTools)
        ) groups.runnerTools
        &&
          builtins.length (builtins.filter (t: t.runner) groups.tools)
          + builtins.length groups.runnerOnlyTools == builtins.length groups.runnerTools;
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
      name = "md は h1 から始まり 3 行目が HTML 版の跡の行で、ホストの値へのリンク・グループと環境・ホストで決めた値・効かない理由・生成物の断りを持つ";
      ok =
        builtins.elemAt (lines carolMd) 0 == "# `carol@three`"
        && builtins.elemAt (lines carolMd) 1 == ""
        && builtins.elemAt (lines carolMd) 2 == "🌐 [HTML 版: carol@three の道具](./html/carol@three.html)"
        && lib.hasInfix "[`nix/hosts/carol@three.nix`](../../../nix/hosts/carol@three.nix)" carolMd
        && lib.hasInfix "- グループ: `minimum` (ホストで選んだ) · 環境: WSL · win/ を配る\n" carolMd
        && lib.hasInfix "- 入る道具: 5 / 31 (ほかに基本の道具 (switch なし) が 10 個いつも入る)\n" carolMd
        && lib.hasInfix "ntn (Notion の CLI) on" carolMd
        && lib.hasInfix "dotfiles-private の `nix/shared/` で決めた値: 使わない store path・mise の版の掃除 off" carolMd
        && !(lib.hasInfix "効かない道具" carolMd)
        &&
          lib.hasInfix "- 効かない道具 (値は on か、グループに入るが、そのマシンで効かない): Windows の ntn (win/ を配らない)"
            ((hostWith winNtnNoFiles).hostSummary.pages "tester@box").nix."tester@box.md"
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
      name = "#data の JSON は < を逃がしてあり、タブ・領域・基本の道具と表の全部の道具・dotfiles. の頭の option を持つ";
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
          map (r: r.id) carolFig.regions == [
            "minimum"
            "all"
          ]
        &&
          builtins.length (builtins.attrNames carolFig.tools)
          == builtins.length groups.tools + builtins.length groups.base
        && carolFig.tools.ntn.option == "dotfiles.ntn.enable"
        && carolFig.tools.ntn.region == "all"
        && carolFig.tools.git.base
        && carolFig.tools.git.region == "minimum"
        &&
          (builtins.elemAt carolFig.views 0).tools.ntn == {
            v = true;
            e = true;
            x = false;
            s = "host";
            t = "ホストのファイル";
            d = false;
            off = [ ];
          }
        && (builtins.elemAt carolFig.views 0).tools.git.s == "fixed"
        && (builtins.elemAt carolFig.views 0).regions.minimum.value
        && !(builtins.elemAt carolFig.views 0).regions.all.value
        && (builtins.elemAt carolFig.views 1).tools.ntn.e == false;
    }
    {
      name = "winData: グループ・[tools] の上書き・グループの既定・効く条件 (onePassword・privateRepos) と、runner の道具だけ (runner だけが読む privateRepos も)";
      ok =
        dave.group == {
          value = "minimum";
          source = "host";
        }
        && (rowOf dave "windowsNtn").source == "host"
        && (rowOf dave "windowsNtn").effective
        && (rowOf dave "windowsNtn").default == false
        && (rowOf dave "windowsClaudeCode").source == "group"
        && !(rowOf dave "windowsClaudeCode").effective
        && !(rowOf dave "windowsClaudeCode").blocked
        && (rowOf dave "opReasonSshRelay").blocked
        &&
          (rowOf dave "opReasonSshRelay").requires == [
            "[tools] onePassword"
            "[tools] privateRepos"
          ]
        && (rowOf dave "opReasonSshRelay").requiresOff == [ "[tools] onePassword" ]
        && (rowOf dave "windowsClaudeAccounts").requires == [ "[tools] windowsClaudeCode" ]
        && (rowOf dave "claudePrivateSkills").requires == [ "[tools] privateRepos" ]
        &&
          (rowOf dave "herdrHub").requires == [
            "[tools] windowsClaudeCode"
            "[tools] windowsHerdr"
          ]
        && (rowOf dave "privateRepos").source == "host"
        && (rowOf dave "privateRepos").effective
        && (rowOf dave "privateRepos").default == false
        && (rowOf dave "privateRepos").option == "[tools] privateRepos"
        && !(rowOf dave "privateRepos").windows
        &&
          map (r: r.key) dave.tools
          == builtins.filter (k: builtins.elem k groups.runnerTools) (map (t: t.key) groups.tools)
          ++ map (r: r.key) groups.runnerOnlyTools
        && dave.runner;
    }
    {
      name = "winData: 図に描けない値 (受け持ち・鍵の本数とコメントだけ・ユーザー・送り元の数)。group を書かなければ minimum で unset";
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
            value = "minimum";
            source = "unset";
          }
        && (rowOf erin "windowsTypeClipboard").source == "host"
        && !erin.runner;
    }
    {
      name = "Windows のホストの図の領域は、minimum がいつも on で、all はグループが all のときだけ on";
      ok =
        let
          host = builtins.head (builtins.head (dataOfHtml files.win.html."dave@three.html").figures).views;
          allHost =
            (hostSummary.winPages "x@y" (hostSummary.winData windowsGroups "x@y" { group = "all"; }))
            .win.html."x@y.html";
        in
        host.regions.minimum.value
        && !host.regions.all.value
        && host.tools.winAlways.s == "fixed"
        && (builtins.head (builtins.head (dataOfHtml allHost).figures).views).regions.all.value;
    }
    {
      name = "winData: やめたグループ・知らないグループ・知らない道具・bool でない道具の値と、止める条件の要る道具が off なのにそれが要る道具が on のホストは評価で止める";
      ok =
        throws (hostSummary.winData windowsGroups "x@y" { group = "company"; })
        && throws (hostSummary.winData windowsGroups "x@y" { group = "nope"; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.noSuchTool = true; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.windowsNtn = "yes"; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.claudePrivateSkills = true; })
        && throws (hostSummary.winData windowsGroups "x@y" { tools.herdrHub = true; })
        && throws (
          hostSummary.winData windowsGroups "x@y" {
            tools = {
              herdrHub = true;
              windowsClaudeCode = true;
            };
          }
        )
        && !(throws (
          hostSummary.winData windowsGroups "x@y" {
            tools = {
              herdrHub = true;
              windowsClaudeCode = true;
              windowsHerdr = true;
            };
          }
        ))
        && throws (
          hostSummary.winData windowsGroups "x@y" {
            group = "all";
            tools.privateRepos = false;
          }
        )
        && !(throws (
          hostSummary.winData windowsGroups "x@y" {
            tools = {
              claudePrivateSkills = true;
              privateRepos = true;
            };
          }
        ))
        && !(throws (
          hostSummary.winData windowsGroups "x@y" {
            group = "all";
            tools = {
              privateRepos = false;
              claudePrivateSkills = false;
              opReasonSshRelay = false;
            };
          }
        ));
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
          lib.hasInfix
            "| [`carol@three`](./nix/carol@three.md) | `minimum` (ホストで選んだ) | WSL · win/ を配る | 5 / 31 |"
            files."README.md"
        && lib.hasInfix "| [`dave@three`](./win/dave@three.md) |" files."README.md"
        && lib.hasInfix "[`dave@three`](./win/dave@three.md) |\n" files."README.md"
        &&
          lib.hasInfix "| [`erin@four`](./win/erin@four.md) | `minimum` (選んでいない。既定) | WSL の setup |"
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
            "| [`Frank Example@three`](./win/Frank%20Example@three.md) | `minimum` (ホストで選んだ) | WSL の setup |"
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
      name = "line はグループと環境を 1 行にし、text は効かない道具に合わない条件を添える";
      ok =
        let
          # 作り物のホストは、この check の system で組む (aarch64-darwin では macOS)
          env = if lib.hasSuffix "-darwin" system then "macOS" else "Linux (WSL でない)";
        in
        (hostWith { group = "minimum"; }).hostSummary.line == "minimum (ホストで選んだ) · 環境: ${env}"
        && lib.hasInfix "    Windows の ntn: – (win/ を配らない) (ホストのファイル) [wsl.windowsFiles.ntn.enable]" (hostWith winNtnNoFiles)
        .hostSummary.text
        && lib.hasInfix "  環境: ${env}\n" (hostWith { }).hostSummary.text;
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
