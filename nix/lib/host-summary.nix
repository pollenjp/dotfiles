# ホストの要約 (設定グループ・段・道具の on/off と、その値がどこで決まったか) を作る
# (dotfiles-private の docs/adr/057_host_setting_groups_*)。表は lib/groups.nix。
#
# mkHome (lib/mk-home.nix) が、組み立てたホストに hostSummary として足す (activationPackage は変えない):
#
#   hostSummary.data       要約の値 (JSON にできる値だけ。下の「data」)
#   hostSummary.line       グループと段の 1 行
#   hostSummary.text       端末に出す要約 (nix/scripts/private-host.sh summary)
#   hostSummary.markdown   図 (mermaid) と表 (<ホスト>.md と README のホストの節の本文)
#   hostSummary.file       name -> dotfiles-private の nix/hosts/<name>.md の全文
#
# flake の lib.hostSummary はこの関数の組で、files (dotfiles-private の nix/hosts/ に書くファイルの名前 → 中身。private-host.sh
# summaries) と groupsDoc (nix/groups.md の全文) も持つ。
#
# どこで決まったか (source):
#
#   host     優先度が option の既定 (1500) より強い定義がある (mkHome の引数・ホストのファイルの modules・ローカル flake の tmp)
#   shared   そのうち、定義が全部 dotfiles-private の nix/shared/*.nix (登録した全ホストに足す module) のもの
#   unset    グループを選んでいない (既定の personal)
#   group    段の switch がグループの既定のまま
#   tier     道具の switch が段の既定のまま
#   default  ほかの既定のまま (① の道具・既定が段によらない道具)
#
# 文は毎回同じになるようにする (並びは表の順・ホストは名前の順。日時・store のパス・dotfiles の版は書かない)。setup が
# この PC の <ホスト>.md を作り直して比べ、違えば古いと知らせるため。
{ lib }:

let
  groups = import ./groups.nix;

  tierOf = name: builtins.head (builtins.filter (t: t.name == name) groups.tiers);
  tierMarks = names: lib.concatMapStringsSep "" (n: (tierOf n).mark) names;
  # 道具の段の印 (① の道具は ①)
  toolMarks = t: if t.tiers == [ ] then "①" else tierMarks t.tiers;

  dotted = lib.concatStringsSep ".";
  onoff = b: if b then "on" else "off";

  # dotfiles-private の nix/shared/*.nix の定義か (privateHosts が path のまま足す module。定義の files がその path になる)
  isShared = f: builtins.match ".*/shared/[^/]+\\.nix" (toString f) != null;
  sourceOf =
    opt: fallback:
    if opt.highestPrio < 1500 then
      (if opt.files != [ ] && builtins.all isShared opt.files then "shared" else "host")
    else
      fallback;

  sourceLabel =
    group: row:
    {
      host = "ホストのファイル";
      shared = "dotfiles-private の nix/shared/";
      unset = "既定 (選んでいない)";
      group = "グループ (${group}) の既定";
      tier = "段 (${lib.concatStringsSep " と " (map (n: (tierOf n).mark) row.tiers)}) の既定";
      default = "既定";
    }
    .${row.source};

  isHost = row: row.source == "host" || row.source == "shared";

  data =
    hc:
    let
      cfg = hc.config.dotfiles;
      opts = hc.options.dotfiles;
      get = path: lib.getAttrFromPath path cfg;
      opt = path: lib.getAttrFromPath path opts;
      group = cfg.group;
    in
    {
      group = {
        value = group;
        source = sourceOf opts.group "unset";
      };
      tiers = map (
        t:
        if t.option == null then
          {
            inherit (t) name mark label;
            option = null;
            value = true;
            source = "default";
          }
        else
          {
            inherit (t) name mark label;
            option = dotted t.option;
            value = get t.option;
            source = sourceOf (opt t.option) "group";
          }
      ) groups.tiers;
      tools = map (
        t:
        let
          value = get t.option;
        in
        {
          inherit (t) key label tiers;
          marks = toolMarks t;
          option = dotted t.option;
          inherit value;
          # 効く条件 (requires) が全部 on のときだけ効く。値が off ならそのまま off
          effective = value && builtins.all get t.requires;
          blocked = value && !(builtins.all get t.requires);
          requires = map dotted t.requires;
          source = sourceOf (opt t.option) (if t.derived && t.tiers != [ ] then "tier" else "default");
        }
      ) groups.tools;
    };

  # 値の見え方 (on / off / –)。– は値は on だが、効く条件が off で効かない
  shown = row: if row.blocked then "–" else onoff row.value;

  groupSource =
    d:
    if d.group.source == "unset" then
      "選んでいない。既定"
    else if d.group.source == "shared" then
      "dotfiles-private の nix/shared/ で選んだ"
    else
      "ホストで選んだ";

  line =
    d:
    "${d.group.value} (${groupSource d}) · "
    + lib.concatMapStringsSep " · " (t: "${t.mark} ${t.label} ${onoff t.value}") d.tiers;

  text =
    d:
    let
      tierLine =
        t:
        "    ${t.mark} ${t.label}: ${onoff t.value}"
        + (if t.option == null then " (どのグループでも)" else " (${sourceLabel d.group.value t}) [${t.option}]");
      toolLine =
        r:
        "    ${r.marks} ${r.label}: ${shown r}"
        + lib.optionalString r.blocked " (${lib.concatStringsSep "・" r.requires} が off なので効かない)"
        + " (${sourceLabel d.group.value r}) [${r.option}]";
    in
    lib.concatStringsSep "\n" (
      [
        "  グループ: ${d.group.value} (${groupSource d})"
        "  段:"
      ]
      ++ map tierLine d.tiers
      ++ [ "  道具 (– は効かない。値はホストのファイル・shared/・既定のどれで決まったか):" ]
      ++ map toolLine d.tools
    )
    + "\n";

  # ---- Markdown ----

  # mermaid の図。node の id は作った名前 (g・t1〜t3・道具の key) で、ホスト名は使わない
  tierId = name: "t${toString (lib.lists.findFirstIndex (t: t.name == name) 0 groups.tiers + 1)}";
  nodeClass =
    row:
    let
      base =
        if row ? blocked && row.blocked then
          "na"
        else if row.value then
          "on"
        else
          "off";
    in
    base + lib.optionalString (isHost row) "Host";
  mermaid =
    d:
    let
      groupNode = "  g[\"グループ: ${d.group.value}<br/>${groupSource d}\"]";
      tierNode =
        t:
        "  ${tierId t.name}[\"${t.mark} ${t.label}<br/>${onoff t.value}"
        + (
          if t.option == null then
            "<br/>どのグループでも"
          else if isHost t then
            "<br/>ホストで決めた"
          else
            "<br/>グループの既定"
        )
        + "\"]";
      toolNode =
        r:
        "  ${r.key}[\"${r.label}<br/>${shown r}"
        + lib.optionalString (isHost r) "<br/>ホストで決めた"
        + lib.optionalString r.blocked "<br/>効かない"
        + "\"]";
      edges = lib.concatMap (
        r: map (n: "  ${tierId n} --> ${r.key}") (if r.tiers == [ ] then [ "engineer" ] else r.tiers)
      ) d.tools;
      rows = d.tiers ++ d.tools;
      idOf = r: if r ? key then r.key else tierId r.name;
      classLines = lib.concatMap (
        c:
        let
          ids = map idOf (builtins.filter (r: nodeClass r == c) rows);
        in
        lib.optional (ids != [ ]) "  class ${lib.concatStringsSep "," ids} ${c}"
      ) classNames;
      classNames = [
        "on"
        "off"
        "na"
        "onHost"
        "offHost"
        "naHost"
      ];
    in
    lib.concatStringsSep "\n" (
      [
        "```mermaid"
        "flowchart LR"
        groupNode
      ]
      ++ map tierNode d.tiers
      ++ map (t: "  g --> ${tierId t.name}") d.tiers
      ++ map toolNode d.tools
      ++ edges
      ++ [
        "  classDef on fill:#e6f4ea,stroke:#34a853,color:#0d652d"
        "  classDef off fill:#f1f3f4,stroke:#9aa0a6,color:#5f6368"
        "  classDef na fill:#ffffff,stroke:#bdc1c6,color:#9aa0a6,stroke-dasharray:4 3"
        "  classDef onHost fill:#e6f4ea,stroke:#d93025,stroke-width:3px,color:#0d652d"
        "  classDef offHost fill:#f1f3f4,stroke:#d93025,stroke-width:3px,color:#5f6368"
        "  classDef naHost fill:#ffffff,stroke:#d93025,stroke-width:3px,color:#9aa0a6,stroke-dasharray:4 3"
      ]
      ++ classLines
      ++ [ "```" ]
    );

  # 表の値。ホストで決めた値は太字
  cell = row: text: if isHost row then "**${text}**" else text;

  table =
    d:
    let
      tierRow =
        t:
        "| ${t.mark} | （段） | ${
          if t.option == null then "—" else "`${t.option}`"
        } | ${cell t (onoff t.value)} | ${
          if t.option == null then "どのグループでも" else sourceLabel d.group.value t
        } |";
      toolRow =
        r:
        "| ${r.marks} | ${r.label} | `${r.option}` | ${cell r (shown r)} | ${sourceLabel d.group.value r}${lib.optionalString r.blocked " (${lib.concatMapStringsSep "・" (o: "`${o}`") r.requires} が off なので効かない)"} |";
    in
    lib.concatStringsSep "\n" (
      [
        "| 段 | 道具 | option (`dotfiles.…`) | 値 | どこで決まったか |"
        "| --- | --- | --- | --- | --- |"
        "| — | グループ | `group` | ${cell d.group "`${d.group.value}`"} | ${sourceLabel d.group.value d.group} |"
      ]
      ++ map tierRow d.tiers
      ++ map toolRow d.tools
    );

  markdown =
    d:
    lib.concatStringsSep "\n\n" [
      "グループ: **${d.group.value}** (${groupSource d}) · ${
        lib.concatMapStringsSep " · " (t: "${t.mark} ${onoff t.value}") d.tiers
      }"
      (mermaid d)
      "**太字**と赤い枠は、ホストのファイル (か dotfiles-private の nix/shared/) で決めた値。「–」は値は on だが、効く条件 (`wsl.windowsFiles.enable` など) が off で効かない。"
      (table d)
    ]
    + "\n";

  generatedNote =
    how: "<!-- 生成物 (dotfiles の nix/lib/host-summary.nix)。手で直さない -->\n\n" + "> 生成物。手で直さない。${how}\n";
  privateHow = "出し直すのは dotfiles の `nix/scripts/private-host.sh summaries --private <dotfiles-private の作業ツリー>` (Claude Code なら skill pjp-dotfiles-register-host)。";

  file =
    name: d:
    generatedNote privateHow
    + "\n# `${name}`\n\n"
    + "ホストの設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 057)。ホストの値はこの隣の [`${name}.nix`](./${name}.nix)。\n\n"
    + markdown d;

  # README の明示の anchor (GitHub は見出しの @ と . を落とし、user@host.example を mailto のリンクにするので、見出しの id に頼らない)
  anchorOf =
    name:
    "host-"
    + lib.toLower (
      lib.concatStrings (
        map (c: if builtins.match "[A-Za-z0-9]" c != null then c else "-") (lib.stringToCharacters name)
      )
    );

  # 表の見出しのホスト名 (@ の後ろで折る)
  headOf =
    name:
    let
      parts = lib.splitString "@" name;
    in
    if builtins.length parts == 2 then
      "`${builtins.head parts}@`<br>`${builtins.elemAt parts 1}`"
    else
      "`${name}`";

  matrix =
    entries:
    let
      tierCell = e: t: cell t (onoff t.value);
      toolCell = e: r: cell r (shown r);
      rowOf = label: cells: "| ${label} | ${lib.concatStringsSep " | " cells} |";
      first = (builtins.head entries).data;
    in
    lib.concatStringsSep "\n" (
      [
        "| 道具 | ${lib.concatMapStringsSep " | " (e: headOf e.name) entries} |"
        "| --- | ${lib.concatMapStringsSep " | " (_: "---") entries} |"
        (rowOf "グループ" (map (e: cell e.data.group "`${e.data.group.value}`") entries))
      ]
      ++ lib.imap0 (
        i: t: rowOf "${t.mark} ${t.label}" (map (e: tierCell e (builtins.elemAt e.data.tiers i)) entries)
      ) first.tiers
      ++ lib.imap0 (
        i: r: rowOf "${r.marks} ${r.label}" (map (e: toolCell e (builtins.elemAt e.data.tools i)) entries)
      ) first.tools
    );

  readme =
    entries:
    let
      sorted = lib.sort (a: b: a.name < b.name) entries;
    in
    generatedNote privateHow
    + "\n# 登録したホストの要約\n\n"
    + "登録したホスト (この dir の `<ホスト>.nix`) ごとの設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 057)。"
    + "ホストごとの節は、ホストのファイルの隣の `<ホスト>.md` と同じ中身。\n\n"
    + "## 目次\n\n"
    + "- [一覧表](#一覧表)\n"
    + lib.concatMapStrings (e: "- [`${e.name}`](#${anchorOf e.name})\n") sorted
    + "\n## 一覧表\n\n"
    + "**太字**はホストのファイル (か dotfiles-private の nix/shared/) で決めた値。「–」は値は on だが、効く条件 (`wsl.windowsFiles.enable` など) が off で効かない。\n\n"
    + matrix sorted
    + "\n"
    + lib.concatMapStrings (
      e:
      "\n<a id=\"${anchorOf e.name}\"></a>\n\n## `${e.name}`\n\nホストの値: [`${e.name}.nix`](./${e.name}.nix)\n\n"
      + markdown e.data
    ) sorted;

  # dotfiles-private の nix/hosts/ に書くファイル (名前 → 中身)。hosts は privateHosts の結果 (名前 → mkHome のホスト)
  files =
    hosts:
    let
      names = builtins.attrNames hosts;
      entries = map (n: {
        name = n;
        data = hosts.${n}.hostSummary.data;
      }) names;
    in
    {
      "README.md" = readme entries;
    }
    // lib.listToAttrs (map (e: lib.nameValuePair "${e.name}.md" (file e.name e.data)) entries);

  # nix/groups.md の全文。plain はグループごとの素のホスト (グループだけを書いたもの) の data、examples は
  # [ { title; data; } ] (lib/group-examples.nix のホスト)
  groupsDoc =
    { plain, examples }:
    let
      groupRow =
        g:
        "| `${g.name}` | ${g.description} | ${
          lib.concatMapStringsSep " | " (
            t: if t.option == null then "on" else onoff (groups.groupHasTier g.name t.name)
          ) groups.tiers
        } |";
      toolRow =
        i: t:
        "| ${toolMarks t} | ${t.label} | `${dotted t.option}` | ${
          lib.concatMapStringsSep " | " (
            g: onoff (builtins.elemAt plain.${g.name}.tools i).value
          ) groups.groups
        } | ${
          if t.requires == [ ] then "" else lib.concatMapStringsSep "・" (o: "`${dotted o}`") t.requires
        } |";
    in
    generatedNote "出し直すのは dotfiles の root で `nix eval --raw ./nix#lib.groupsDoc > nix/groups.md`。古ければ CI (flake の checks の groups-doc) が落ちる。"
    + "\n# 設定グループ\n\n"
    + "ホストは設定グループを 1 つ選び (`mkHome` の `group`)、グループは「どの段の道具まで入れるか」で決まる (dotfiles-private の ADR 057)。"
    + "選び方・直し方・setup の振る舞いは [README の「設定グループ」](./README.md#設定グループ)。ここは `nix/lib/groups.nix` の表と、作り物のホストの要約から作った生成物。\n\n"
    + "## グループ\n\n"
    + "| グループ | 使う PC と何を入れるか | ${
      lib.concatMapStringsSep " | " (t: "${t.mark} ${t.label}") groups.tiers
    } |\n"
    + "| --- | --- | ${lib.concatMapStringsSep " | " (_: "---") groups.tiers} |\n"
    + lib.concatMapStrings (g: groupRow g + "\n") groups.groups
    + "\n## 道具の switch と、グループごとの既定\n\n"
    + "グループだけを書いた (ほかの値を書かない) ホストの値。Windows の道具は `wsl.windowsFiles.enable` のマシンでだけ効く (効く条件の列)。"
    + "既定が段によらない道具 (`onePassword.enable` など) は、どのグループでも off で、使うホストが入れる。\n\n"
    + "| 段 | 道具 | option (`dotfiles.…`) | ${
      lib.concatMapStringsSep " | " (g: "`${g.name}`") groups.groups
    } | 効く条件 |\n"
    + "| --- | --- | --- | ${lib.concatMapStringsSep " | " (_: "---") groups.groups} | --- |\n"
    + lib.concatImapStrings (i: t: toolRow (i - 1) t + "\n") groups.tools
    + "\n## 作り物のホストの要約\n\n"
    + "`nix/lib/group-examples.nix` のホスト (どれも WSL で `win/` を配る。値は作り物)。\n"
    + lib.concatMapStrings (e: "\n### ${e.title}\n\n" + markdown e.data) examples;
in
{
  inherit
    data
    line
    text
    markdown
    file
    readme
    files
    groupsDoc
    anchorOf
    ;
}
