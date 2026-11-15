# ホストの要約 (nix/lib/host-summary.nix。mkHome が hostSummary として足す) を、評価時に確かめる (ADR 057)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (host-summary-state) から呼ぶ。
#
# ## 確かめること
#
#   - どこで決まったか: グループを書かないホストのグループは「選んでいない」(unset)、company の ③ の段はグループの既定 (group) で
#     off、② の道具は段の既定 (tier)、ホストのファイルで書いた道具はホスト (host)、dotfiles-private の nix/shared/ の module で
#     書いた値は shared。既定が段によらない道具と ① の道具は既定 (default)
#   - 効く条件 (wsl.windowsFiles.enable) が off の Windows の道具は、値が on でも「–」(効かない) と出す
#   - markdown は mermaid の図と表を持ち、ホストで決めた道具は図で赤い枠の class (onHost)・表で太字。node の id にホスト名を使わない
#   - file (<ホスト>.md) は生成物の印・出し直す手順・code span のホスト名の見出し・隣のホストのファイルへのリンクを持つ
#   - readme は、@ と . を含むホスト名を code span の見出しにし、明示の anchor (<a id="host-…">) と目次のリンク (#host-…) を
#     持つ。ホストは名前の順で、渡す順を変えても同じ文になる。一覧表はホストを列に並べる
#   - files は README.md と <ホスト>.md を全ホストぶん出す
#   - line は グループと段を 1 行にする
{
  lib,
  pkgs,
  mkHome,
  system,
  hostSummary,
  privateHosts,
}:

let
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

  # ホストのファイルと shared/ (fixtures/host-summary) から組み立てた、自社のホスト
  private = privateHosts ./fixtures/host-summary;
  carol = private."carol@three";
  carolData = carol.hostSummary.data;
  carolFile = carol.hostSummary.file "carol@three";

  # readme の名前 (@ と . を含む作り物)
  named = name: d: {
    inherit name;
    data = d;
  };
  readmeA = hostSummary.readme [
    (named "user@host-a.example" unset)
    (named "alice@one" carolData)
  ];
  readmeB = hostSummary.readme [
    (named "alice@one" carolData)
    (named "user@host-a.example" unset)
  ];
  files = hostSummary.files private;

  # 表の行 (道具の label で始まる行)
  tableRow =
    text: label:
    lib.findFirst (l: lib.hasPrefix "| " l && lib.hasInfix "| ${label} |" l) "" (
      lib.splitString "\n" text
    );

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
      name = "windowsFiles が off の Windows の道具は、値が on でも「–」(効かない)";
      ok =
        (rowOf unset "windowsClaudeCode").value
        && (rowOf unset "windowsClaudeCode").blocked
        && lib.hasInfix "| – |" (tableRow ((hostWith { }).hostSummary.markdown) "Windows の Claude Code");
    }
    {
      name = "windowsFiles が on のホストでは Windows の道具が効く (carol の Windows の ntn は on)";
      ok = !(rowOf carolData "windowsNtn").blocked && (rowOf carolData "windowsClaudeCode").effective;
    }
    {
      name = "markdown は mermaid の図と表を持ち、ホストで決めた道具は onHost の class・表で太字";
      ok =
        let
          md = carol.hostSummary.markdown;
        in
        lib.hasInfix "```mermaid\nflowchart LR\n" md
        && lib.hasInfix "| 段 | 道具 | option (`dotfiles.…`) | 値 | どこで決まったか |" md
        && builtins.match "(.*\n)?  class [^\n]*ntn[^\n]* onHost\n.*" md != null
        && lib.hasInfix "| **on** |" (tableRow md "ntn (Notion の CLI)")
        && !(lib.hasInfix "carol" md);
    }
    {
      name = "file は生成物の印・出し直す手順・code span の見出し・隣のホストのファイルへのリンクを持つ";
      ok =
        lib.hasPrefix "<!-- 生成物" carolFile
        && lib.hasInfix "private-host.sh summaries --private" carolFile
        && lib.hasInfix "\n# `carol@three`\n" carolFile
        && lib.hasInfix "[`carol@three.nix`](./carol@three.nix)" carolFile;
    }
    {
      name = "readme は code span の見出し・明示の anchor・目次のリンクを持ち、名前の順で、渡す順によらず同じ";
      ok =
        readmeA == readmeB
        && lib.hasInfix "\n<a id=\"host-user-host-a-example\"></a>\n\n## `user@host-a.example`\n" readmeA
        && lib.hasInfix "- [`user@host-a.example`](#host-user-host-a-example)\n" readmeA
        && lib.hasInfix "- [`alice@one`](#host-alice-one)\n- [`user@host-a.example`]" readmeA
        && lib.hasInfix "| 道具 | `alice@`<br>`one` | `user@`<br>`host-a.example` |" readmeA;
    }
    {
      name = "files は README.md と <ホスト>.md を全ホストぶん出す";
      ok =
        builtins.attrNames files == [
          "README.md"
          "carol@three.md"
        ]
        && files."carol@three.md" == carolFile;
    }
    {
      name = "line はグループと段を 1 行にする";
      ok =
        (hostWith { group = "client"; }).hostSummary.line
        == "client (ホストで選んだ) · ① エンジニアの道具 on · ② AI の道具 off · ③ 個人のアカウント off";
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
