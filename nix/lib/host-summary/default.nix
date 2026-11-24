# ホストの要約 (設定グループ・段・道具の on/off と、その値がどこで決まったか) を作る (dotfiles-private の
# docs/adr/057_host_setting_groups_*。図の HTML にしたのは docs/adr/093_host_summary_html_*)。表は lib/groups.nix。
#
# mkHome (lib/mk-home.nix) が、組み立てたホストに hostSummary として足す (activationPackage は変えない):
#
#   hostSummary.data    要約の値 (JSON にできる値だけ。下の「data」)
#   hostSummary.line    グループと段の 1 行
#   hostSummary.text    端末に出す要約 (nix/scripts/private-host.sh summary)
#   hostSummary.pages   name -> そのホストのページ。dotfiles-private の docs/hosts/ からの path の組
#                       ({ nix = { "<name>.md" = …; html."<name>.html" = …; }; })。private-host.sh summaries が書くものと
#                       同じ関数で、setup.sh はこの PC の分を作り直して clone のものと比べる
#
# flake の lib.hostSummary はこの関数の組で、files (docs/hosts/ に書くファイルの全部。private-host.sh summaries) と
# groupsDoc (nix/groups.md の全文) も持つ。Windows のホスト (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml。Windows の runner
# が読む値) の要約の値は winData が TOML の中身から作る。
#
# ## ページ
#
#   docs/hosts/README.md               全ホストの入口 (一覧の表)。HTML 版 html/hosts.html は全ホストの図 (タブでホストを替える)
#   docs/hosts/nix/<ホスト>.md          Nix のホスト 1 台 (Notion では 1 ページ)。HTML 版は nix/html/<ホスト>.html
#   docs/hosts/win/<ホスト>.md          Windows のホスト 1 台。HTML 版は win/html/<ホスト>.html
#
# md は短くする (ホストの値へのリンク・グループ・HTML 版の跡の行・図に描けない注記)。図は HTML 版の JS (page.js) が #data の
# JSON から描く: 段を入れ子の領域、道具を箱、ホストを「入る道具だけを囲む色の線」にし、タブで見せる線を替える。HTML 版は
# 雛形 page.html に page.css・page.js・本文・JSON を差し込んだ 1 ファイル (CDN も外のファイルも読まない)。
#
# md は h1 から始め、生成物の断りは末尾に置く。Notion に写す道具 (claude-skills の pjp-docs-to-notion) は、ページを作ると
# h1 の下 (3 行目) に「📝 [Notion で開く](…)」の行と空行を書く。private-host.sh summaries はその行を残して書き、setup.sh と
# summaries --check は外して比べる。
#
# ## リンク
#
# md のリンク先 (HTML 版の跡の行・ホストの値・入口の表のホストのページ) と、HTML 版の a の href (dotfiles-private の blob の URL) は、
# path を urlPath に通して書く (空白や記号を %XX にする)。Windows のホストの名前は Windows のユーザー名を含み (runner が読む
# <ユーザー名>@<PC>.toml)、空白が入りうる。空白をそのまま書いた md のリンク先は CommonMark のリンクにならず、GitHub でも Notion に
# 写す道具 (md を markdown-it で読み、リンク先の %XX を戻してファイルと突き合わせる) でもリンクにならない (Notion ではホストの
# ページに HTML 版が埋め込まれない)。リンクの字 (h1・リンクの字・code) は名前のまま見せる。名前が英数字と - . _ ~ @ だけなら、
# リンク先も名前のまま (逃がす字が無い)。
#
# ## どこで決まったか (source)
#
#   host     優先度が option の既定 (1500) より強い定義がある (mkHome の引数・ホストのファイルの modules・ローカル flake の tmp)。
#            Windows のホストでは、TOML の [tools] (と group) に書いた値
#   shared   そのうち、定義が全部 dotfiles-private の nix/shared/*.nix (登録した全ホストに足す module) のもの
#   unset    グループを選んでいない (既定の personal)
#   group    段の switch がグループの既定のまま。Windows のホストでは、道具の switch もグループの既定 (groups.json) のまま
#   tier     道具の switch が段の既定のまま
#   default  ほかの既定のまま (① の道具・既定が段によらない道具)
#
# 「既定」(default・defaultEffective) は、ホストで何も書かなかったときの値。段の switch は option の既定 (グループで決まる)。
# 段から既定が決まる道具 (derived で段を持つもの) は、その段のどれかのグループの既定が off なら off、全部 on なら option の既定
# (ホストが段の switch を書いていなければ、ホストの文脈で読んだ option の既定がそのまま当たる。書いていれば段の既定の積で、
# herdrCore の Linux だけのような段の外の条件は読めないので on とみなす)。ほかの道具は option の既定 (段によらない)。効く条件も
# 同じ既定で見る。
#
# 文は毎回同じになるようにする (並びは表の順・ホストは名前の順。日時・store のパス・dotfiles の版は書かない)。setup が
# この PC のページを作り直して比べ、違えば古いと知らせるため。ホストのページは、そのホストの値と表だけから作る (ほかの
# ホストを読まない。setup は 1 台ぶんだけ評価する)。
{ lib }:

let
  groups = import ../groups.nix;

  tierOf = name: builtins.head (builtins.filter (t: t.name == name) groups.tiers);
  tierMarks = names: lib.concatMapStringsSep "" (n: (tierOf n).mark) names;
  # 道具の段の印 (① の道具は ①)
  toolMarks = t: if t.tiers == [ ] then "①" else tierMarks t.tiers;

  dotted = lib.concatStringsSep ".";
  onoff = b: if b then "on" else "off";

  # 図の列。段の入れ子の領域を内から外へ ① → ② → ③ と並べ、③ の領域には ② と ③ の両方が要る道具の列 (②③) と ③ の列を置く
  columnOf =
    t:
    if t.tiers == [ ] then
      "c1"
    else if t.tiers == [ "aiTools" ] then
      "c2"
    else if t.tiers == [ "personalAccounts" ] then
      "c3"
    else
      "c23";
  columnDefs = [
    {
      id = "c1";
      region = "engineer";
      head = "①";
    }
    {
      id = "c2";
      region = "aiTools";
      head = "②";
    }
    {
      id = "c23";
      region = "personalAccounts";
      head = "②③ (両方の段で入る)";
    }
    {
      id = "c3";
      region = "personalAccounts";
      head = "③";
    }
  ];

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
  # Windows のホストの道具の値の出どころ
  winSourceLabel =
    group: row:
    {
      host = "ホストの値 ([tools])";
      group = "グループ (${group}) の既定";
      unset = "既定 (選んでいない)";
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
      # option の default の式 (ホストの文脈で読む)
      optDefault = path: (opt path).default or false;
      # 段の既定 (グループで決まる) と、ホストの値がその既定のままか
      tierDefault = name: optDefault (tierOf name).option;
      tierAsDefault = name: get (tierOf name).option == tierDefault name;
      # ホストで何も書かなかったときの値 (冒頭の「既定」)。path は道具の option か、効く条件の option
      defaultOf =
        path:
        let
          found = builtins.filter (t: t.option == path) groups.tools;
          t = builtins.head found;
        in
        if found == [ ] || !(t.derived && t.tiers != [ ]) then
          optDefault path
        else if !(builtins.all tierDefault t.tiers) then
          false
        else if builtins.all tierAsDefault t.tiers then
          optDefault path
        else
          true;
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
            default = true;
            source = "default";
          }
        else
          {
            inherit (t) name mark label;
            option = dotted t.option;
            value = get t.option;
            default = optDefault t.option;
            source = sourceOf (opt t.option) "group";
          }
      ) groups.tiers;
      tools = map (
        t:
        let
          value = get t.option;
          default = defaultOf t.option;
        in
        {
          inherit (t)
            key
            label
            short
            tiers
            ;
          marks = toolMarks t;
          column = columnOf t;
          option = dotted t.option;
          inherit value default;
          # 効く条件 (requires) が全部 on のときだけ効く。値が off ならそのまま off
          effective = value && builtins.all get t.requires;
          blocked = value && !(builtins.all get t.requires);
          defaultEffective = default && builtins.all defaultOf t.requires;
          requires = map dotted t.requires;
          requiresOff = map dotted (builtins.filter (p: !(get p)) t.requires);
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

  tierLine = d: lib.concatMapStringsSep " · " (t: "${t.mark} ${onoff t.value}") d.tiers;

  line =
    d:
    "${d.group.value} (${groupSource d}) · "
    + lib.concatMapStringsSep " · " (t: "${t.mark} ${t.label} ${onoff t.value}") d.tiers;

  text =
    d:
    let
      tierLine' =
        t:
        "    ${t.mark} ${t.label}: ${onoff t.value}"
        + (if t.option == null then " (どのグループでも)" else " (${sourceLabel d.group.value t}) [${t.option}]");
      toolLine =
        r:
        "    ${r.marks} ${r.label}: ${shown r}"
        + lib.optionalString r.blocked " (${lib.concatStringsSep "・" r.requiresOff} が off なので効かない)"
        + " (${sourceLabel d.group.value r}) [${r.option}]";
    in
    lib.concatStringsSep "\n" (
      [
        "  グループ: ${d.group.value} (${groupSource d})"
        "  段:"
      ]
      ++ map tierLine' d.tiers
      ++ [ "  道具 (– は効かない。値はホストのファイル・shared/・既定のどれで決まったか):" ]
      ++ map toolLine d.tools
    )
    + "\n";

  # ---- 文の部品 (md と HTML) ----

  esc = builtins.replaceStrings [ "&" "<" ">" "\"" ] [ "&amp;" "&lt;" "&gt;" "&quot;" ];
  # <script type="application/json"> に置く JSON。< を逃がし、中身の </script> で script が閉じないようにする
  toJson = v: builtins.replaceStrings [ "<" ] [ "\\u003c" ] (builtins.toJSON v);
  # HTML 版のリンクは新しいタブで開く (Notion の埋め込みの中で、枠の中で移ろうとして壊れて見えないように)
  aTag = url: html: ''<a href="${esc url}" target="_blank" rel="noopener">${html}</a>'';
  codeTag = s: "<code>${esc s}</code>";
  # 表の中の長い名前は、. - @ / の後ろでだけ折る (語の途中で折らない)
  codeBreak =
    s:
    "<code class=\"brk\">"
    + lib.concatMapStrings (
      c:
      if
        builtins.elem c [
          "."
          "-"
          "@"
          "/"
        ]
      then
        "${esc c}<wbr>"
      else
        esc c
    ) (lib.stringToCharacters s)
    + "</code>";
  # リンク先 (md の相対パス・HTML 版の blob の URL) に書く path。空白や記号を %XX にする (冒頭の「リンク」)。lib.escapeURL は ASCII の
  # 印字できる字とタブ・LF・CR のうち、英数字と - . _ ~ の外を %XX にする (ほかの制御文字は Windows のファイル名に使えないので見ない)。
  # ASCII の外の字 (UTF-8 のバイト) はそのまま残す。そこから区切りの / と、ホストの名前の @ を戻す (lib.escapeURL の出す %XX は大文字で、
  # %2F・%40 は / と @ からしか出ない)
  urlPath = s: builtins.replaceStrings [ "%2F" "%40" ] [ "/" "@" ] (lib.escapeURL s);
  # md のリンク。字はそのまま、path (# 以降を持たない) は urlPath に通す
  mdLink = label: path: "[${label}](${urlPath path})";
  privateRepo = "https://github.com/pollenjp/dotfiles-private";
  bodyRepo = "https://github.com/pollenjp/dotfiles";
  blob = repo: path: "${repo}/blob/main/${urlPath path}";

  genWhat = "生成物 (dotfiles の nix/lib/host-summary/)。手で直さない。出し直すのは dotfiles の";
  genCmd = "nix/scripts/private-host.sh summaries --private <dotfiles-private の作業ツリー>";
  genSkill = "(Claude Code なら skill pjp-dotfiles-register-host)";
  mdGen = "> ${genWhat} `${genCmd}` ${genSkill}。\n";
  htmlGen = ''<p class="gen">${esc genWhat} ${codeTag genCmd} ${esc genSkill}。</p>'';

  # ホスト名の表の見出し (@ の後ろで折る)
  headOf =
    name:
    let
      parts = lib.splitString "@" name;
    in
    if builtins.length parts == 2 then
      "${codeBreak "${builtins.head parts}@"}<br>${codeBreak (builtins.elemAt parts 1)}"
    else
      codeBreak name;

  sortNames = attrs: lib.sort (a: b: a < b) (builtins.attrNames attrs);
  # 同じ PC か (@ の後ろを小文字にして比べる。Windows のホストの名前は hostname を小文字にしたもの)
  pcOf = name: lib.toLower (lib.last (lib.splitString "@" name));

  countOn = rows: builtins.length (builtins.filter (r: r.effective) rows);
  listOr = none: xs: if xs == [ ] then none else lib.concatStringsSep "・" xs;

  # ---- 図のデータ (page.js が読む #data) ----

  regionsData = map (t: {
    id = t.name;
    inherit (t) mark label;
  }) groups.tiers;

  columnsFor =
    rows:
    map (c: c // { tools = map (r: r.key) (builtins.filter (r: r.column == c.id) rows); }) columnDefs;

  # 図の箱の名前と option。prefix は option の頭 (Nix のホストは dotfiles.、Windows のホストは option に [tools] を持つので空)
  toolsMeta =
    prefix: rows:
    builtins.listToAttrs (
      map (
        r:
        lib.nameValuePair r.key {
          inherit (r) label short marks;
          option = prefix + r.option;
          requires = map (p: prefix + p) r.requires;
        }
      ) rows
    );

  # タブ 1 つぶんの、段と道具の値。useDefault なら、ホストで書かなかったときの値
  tierStates =
    srcLabel: d: useDefault:
    builtins.listToAttrs (
      map (
        t:
        let
          # ① は段の switch が無く、どのグループでも入る (Windows のホストは段の option を持たないので、表の段で見る)
          fixed = (tierOf t.name).option == null;
          src =
            if fixed then
              "default"
            else if useDefault then
              "group"
            else
              t.source;
        in
        lib.nameValuePair t.name {
          value = if useDefault then t.default else t.value;
          source = src;
          text = if fixed then "どのグループでも" else srcLabel d.group.value (t // { source = src; });
          inherit (t) option;
        }
      ) d.tiers
    );
  toolStates =
    prefix: srcLabel: d: useDefault:
    builtins.listToAttrs (
      map (
        r:
        lib.nameValuePair r.key (
          if useDefault then
            {
              v = r.default;
              e = r.defaultEffective;
              s = "default";
              t = "書かなかったときの既定";
              d = r.default;
            }
          else
            {
              v = r.value;
              e = r.effective;
              s = r.source;
              t = srcLabel d.group.value r;
              d = r.default;
              off = map (p: prefix + p) r.requiresOff;
            }
        )
      ) d.tools
    );
  groupState = d: {
    inherit (d.group) value source;
    text = groupSource d;
  };

  # ホストのページの 3 つのタブ (このホスト・既定・重ねて比べる) の説明
  hostNotes =
    kindLabel: d:
    [
      "グループ: ${d.group.value} (${groupSource d}) · ${tierLine d}"
      "入る道具: ${toString (countOn d.tools)} / ${toString (builtins.length d.tools)} (囲みの線の中。${kindLabel}で決めた値は箱の右上に ●)"
    ]
    ++
      lib.optional (builtins.any (r: r.blocked) d.tools)
        "効かない道具 (値は on だが効く条件が off。細かい点線の箱): ${
          lib.concatMapStringsSep "・" (r: r.short) (builtins.filter (r: r.blocked) d.tools)
        }";
  defaultNotes = d: [
    "グループ ${d.group.value} の既定のまま、ホストで何も書かなかったときの値 (option の既定)"
    "入る道具: ${
      toString (builtins.length (builtins.filter (r: r.defaultEffective) d.tools))
    } / ${toString (builtins.length d.tools)}"
  ];
  diffNotes =
    d:
    let
      added = builtins.filter (r: r.effective && !r.defaultEffective) d.tools;
      removed = builtins.filter (r: !r.effective && r.defaultEffective) d.tools;
    in
    [
      "色の線がこのホスト、灰色の線が既定。光った箱がホストで変えた道具"
      "ホストで足した (既定では入らない): ${listOr "なし" (map (r: r.short) added)}"
      "ホストで外した (既定では入る): ${listOr "なし" (map (r: r.short) removed)}"
    ];

  hostFigure =
    {
      kind,
      prefix,
      srcLabel,
      kindLabel,
      name,
      d,
    }:
    {
      id = "h";
      inherit kind;
      order = "host";
      regions = regionsData;
      columns = columnsFor d.tools;
      tools = toolsMeta prefix d.tools;
      views = [
        {
          id = "host";
          label = name;
          kind = "host";
          color = 2;
          group = groupState d;
          tiers = tierStates srcLabel d false;
          tools = toolStates prefix srcLabel d false;
          note = hostNotes kindLabel d;
        }
        {
          id = "default";
          label = "既定 (${d.group.value})";
          kind = "default";
          color = 0;
          group = groupState d;
          tiers = tierStates srcLabel d true;
          tools = toolStates prefix srcLabel d true;
          note = defaultNotes d;
        }
        {
          id = "both";
          label = "重ねて比べる";
          kind = "overlay";
          members = [
            "host"
            "default"
          ];
          note = diffNotes d;
        }
      ];
    };

  # 全ホストの図。タブはホストごとと、全部を重ねるタブ
  indexFigure =
    {
      id,
      kind,
      title,
      prefix,
      srcLabel,
      entries,
    }:
    let
      first = (builtins.head entries).d;
      views = lib.imap1 (i: e: {
        id = "h${toString i}";
        label = e.name;
        kind = "host";
        color = i;
        group = groupState e.d;
        tiers = tierStates srcLabel e.d false;
        tools = toolStates prefix srcLabel e.d false;
        note = [
          "グループ: ${e.d.group.value} (${groupSource e.d}) · ${tierLine e.d}"
          "入る道具: ${toString (countOn e.d.tools)} / ${toString (builtins.length e.d.tools)}"
        ];
      }) entries;
      everyOn = builtins.filter (r: builtins.all (e: (byKey e.d r.key).effective) entries) first.tools;
      noneOn = builtins.filter (r: !(builtins.any (e: (byKey e.d r.key).effective) entries)) first.tools;
    in
    {
      inherit id kind title;
      order = "count";
      regions = regionsData;
      columns = columnsFor first.tools;
      tools = toolsMeta prefix first.tools;
      views =
        views
        ++ lib.optional (builtins.length entries > 1) {
          id = "all";
          label = "重ねて比べる";
          kind = "overlay";
          members = map (v: v.id) views;
          note = [
            "${toString (builtins.length entries)} 台の線を重ねた (線の色はタブの色)。箱の右下の点は、ホストごとに入るか (左からタブの順)"
            "どのホストにも入る: ${listOr "なし" (map (r: r.short) everyOn)}"
            "どのホストにも入らない: ${listOr "なし" (map (r: r.short) noneOn)}"
          ];
        };
    };

  byKey = d: key: builtins.head (builtins.filter (r: r.key == key) d.tools);

  # ---- HTML 版 ----

  template = builtins.readFile ./page.html;
  page =
    {
      title,
      body,
      figures,
    }:
    builtins.replaceStrings
      [ "@@TITLE@@" "@@STYLE@@" "@@BODY@@" "@@DATA@@" "@@SCRIPT@@" ]
      [
        (esc title)
        (builtins.readFile ./page.css)
        body
        (toJson { inherit figures; })
        (builtins.readFile ./page.js)
      ]
      template;

  figureSlot = i: ''<section class="figure" data-fig="${toString i}" aria-label="図"></section>'';

  # 道具の一覧の表 (図を動かせなくても全部の値を読める)。cols は [ { head (HTML); d; } ]、optHead は option の列の見出し
  toolTable =
    optHead: cols:
    let
      first = (builtins.head cols).d;
      cell =
        c: r:
        let
          row = byKey c.d r.key;
          v = shown row;
        in
        if isHost row then "<td><b>${v}</b></td>" else "<td>${v}</td>";
    in
    ''<div class="tablewrap"><table class="tools">''
    + "<thead><tr><th>段</th><th>道具</th><th>${optHead}</th>"
    + lib.concatMapStrings (c: "<th>${c.head}</th>") cols
    + "</tr></thead><tbody>"
    + "<tr><td>—</td><td>グループ</td><td>${codeTag "group"}</td>"
    + lib.concatMapStrings (
      c:
      let
        g = codeTag c.d.group.value;
      in
      if isHost c.d.group then "<td><b>${g}</b></td>" else "<td>${g}</td>"
    ) cols
    + "</tr>"
    + lib.concatImapStrings (
      i: t:
      "<tr><td>${t.mark}</td><td>${esc t.label}</td><td>${
        if t.option == null then "—" else codeBreak t.option
      }</td>"
      + lib.concatMapStrings (c: "<td>${onoff (builtins.elemAt c.d.tiers (i - 1)).value}</td>") cols
      + "</tr>"
    ) first.tiers
    + lib.concatMapStrings (
      r:
      "<tr><td>${r.marks}</td><td>${esc r.label}</td><td>${codeBreak r.option}</td>"
      + lib.concatMapStrings (c: cell c r) cols
      + "</tr>"
    ) first.tools
    + "</tbody></table></div>";

  readingList = winNote: ''
    <ul class="reading">
    <li>灰色の入れ子の領域が段: 内から ① エンジニアの道具・② AI の道具・③ 個人のアカウント。③ の領域の「②③」の列は、② と ③ の両方の段が on のときだけ既定で入る道具</li>
    <li>箱が道具。実線の箱は on、点線の箱は off、細かい点線の箱は値は on だが効く条件が off で効かない (–)。箱の右上の ● はホストで決めた値、○ は dotfiles-private の nix/shared/ で決めた値</li>
    <li>色の線がホスト。線の中の箱が、そのホストで入る道具。段の領域の線が点線なら、その段の switch は off (道具はホストで 1 つずつ足せる)</li>
    <li>箱や段の名前を押すと、option・値・どこで決まったかが出る。タブは ← → でも替えられる</li>
    ${winNote}</ul>
  '';
  winReadingNote = "<li>Windows のホストの値 (win/hosts/ の TOML) が持つのは、グループと道具の switch の上書き ([tools]) だけ。段はグループで決まり、書いていない道具はグループの既定 (dotfiles の win/runner/groups.json)</li>\n";

  # ---- Nix のホストのページ ----

  nixFacts =
    name: d:
    let
      set = builtins.filter (r: r.source == "host") d.tools;
      shared = builtins.filter (r: r.source == "shared") d.tools;
      blocked = builtins.filter (r: r.blocked) d.tools;
      vals = rows: map (r: "${r.label} ${onoff r.value}") rows;
      reasons =
        wrap: rows:
        map (
          r: "${r.label} (${lib.concatMapStringsSep "・" (p: wrap "dotfiles.${p}") r.requiresOff} が off)"
        ) rows;
    in
    {
      inherit set shared blocked;
      setText = listOr "なし" (vals set);
      sharedText = listOr "なし" (vals shared);
      blockedText = listOr "なし" (reasons (p: p) blocked);
      blockedMd = listOr "なし" (reasons (p: "`${p}`") blocked);
    };

  nixMd =
    name: d:
    let
      f = nixFacts name d;
    in
    "# `${name}`\n\n"
    + "🌐 ${mdLink "HTML 版: ${name} の道具" "./html/${name}.html"}\n\n"
    + "設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 057・ADR 093)。図 (段の入れ子の領域・道具の箱・このホストの囲み) は HTML 版にある。\n\n"
    + "- ホストの値: ${mdLink "`nix/hosts/${name}.nix`" "../../../nix/hosts/${name}.nix"}\n"
    + "- グループ: `${d.group.value}` (${groupSource d}) · ${tierLine d}\n"
    + "- 入る道具: ${toString (countOn d.tools)} / ${toString (builtins.length d.tools)}\n"
    + "- ホストのファイルで決めた値: ${f.setText}\n"
    + lib.optionalString (f.shared != [ ]) "- dotfiles-private の `nix/shared/` で決めた値: ${f.sharedText}\n"
    + lib.optionalString (f.blocked != [ ]) "- 効かない道具 (値は on だが、効く条件が off): ${f.blockedMd}\n"
    + "\n全ホストの図と一覧は ${mdLink "入口" "../README.md"}。\n\n"
    + mdGen;

  nixBody =
    name: d:
    let
      f = nixFacts name d;
      hostFile = "nix/hosts/${name}.nix";
    in
    "<header><h1>${codeTag name} の道具</h1>"
    + ''<p class="lead">設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 057・ADR 093)。''
    + "タブで「このホスト」「既定 (ホストで何も書かなかったとき)」「重ねて比べる」を切り替える。箱を押すと option・値・どこで決まったかが出る。</p></header>\n"
    + figureSlot 0
    + "\n<h2>ホストの値</h2>\n<ul>"
    + "<li>ホストの値: ${aTag (blob privateRepo hostFile) (codeTag hostFile)}</li>"
    + "<li>グループ: ${codeTag d.group.value} (${esc (groupSource d)}) · ${esc (tierLine d)}</li>"
    + "<li>入る道具: ${toString (countOn d.tools)} / ${toString (builtins.length d.tools)}</li>"
    + "<li>ホストのファイルで決めた値: ${esc f.setText}</li>"
    + lib.optionalString (
      f.shared != [ ]
    ) "<li>dotfiles-private の nix/shared/ で決めた値: ${esc f.sharedText}</li>"
    + lib.optionalString (f.blocked != [ ]) "<li>効かない道具 (値は on だが、効く条件が off): ${esc f.blockedText}</li>"
    + "<li>全ホストの図と一覧: ${aTag (blob privateRepo "docs/hosts/README.md") "docs/hosts/ の入口"}</li>"
    + "</ul>\n<h2>道具の一覧</h2>\n"
    + "<p>太字はホストのファイル (か dotfiles-private の nix/shared/) で決めた値。「–」は値は on だが効く条件が off で効かない。</p>\n"
    + toolTable "option (dotfiles.…)" [
      {
        head = "このホスト";
        inherit d;
      }
    ]
    + "\n<h2>図の読み方</h2>\n"
    + readingList ""
    + htmlGen
    + "\n";

  pages = name: d: {
    nix = {
      "${name}.md" = nixMd name d;
      html."${name}.html" = page {
        title = "${name} の道具";
        body = nixBody name d;
        figures = [
          (hostFigure {
            kind = "nix";
            prefix = "dotfiles.";
            srcLabel = sourceLabel;
            kindLabel = "ホストのファイル";
            inherit name d;
          })
        ];
      };
    };
  };

  # ---- Windows のホスト ----

  # authorized_keys の鍵の種類 (win/runner の SSH_KEY_TYPES と同じ)
  keyTypes = [
    "ssh-ed25519"
    "ssh-rsa"
    "ecdsa-sha2-nistp256"
    "ecdsa-sha2-nistp384"
    "ecdsa-sha2-nistp521"
    "sk-ssh-ed25519@openssh.com"
    "sk-ecdsa-sha2-nistp256@openssh.com"
  ];
  # authorized_keys の 1 行のコメント (鍵の後ろの語)。鍵そのものは出さない
  keyComment =
    keyLine:
    let
      toks = builtins.filter (s: s != "") (lib.splitString " " keyLine);
      idx = lib.lists.findFirstIndex (s: builtins.elem s keyTypes) null toks;
      rest = if idx == null then [ ] else lib.drop (idx + 2) toks;
    in
    if idx == null then
      "読めない行"
    else if rest == [ ] then
      "コメントなし"
    else
      lib.concatStringsSep " " rest;

  # Windows のホストの要約の値。windowsGroups はグループごとの段と道具の既定 (win/runner/groups.json と同じ中身。flake の
  # lib.windowsGroups)、toml はホストの値のファイル (builtins.fromTOML の結果)。道具は Windows の runner が読むものだけ
  # (groups.nix の runner)。効く条件は groups.nix の requires から、WSL が win/ を配るかの条件 (windowsFiles) を外したもの
  # (runner は Windows で動くので)
  winData =
    windowsGroups: name: toml:
    let
      group = toml.group or windowsGroups.default;
      g =
        windowsGroups.groups.${group}
          or (throw "host-summary: ${name} の group が知らないグループです: ${group} (${lib.concatStringsSep "・" (builtins.attrNames windowsGroups.groups)} のどれか)");
      overrides = toml.tools or { };
      unknown = builtins.filter (k: !(g.tools ? ${k})) (builtins.attrNames overrides);
      notBool = builtins.filter (k: !(builtins.isBool overrides.${k})) (builtins.attrNames overrides);
      keyOf = path: (builtins.head (builtins.filter (t: t.option == path) groups.tools)).key;
      winReq = t: builtins.filter (k: k != "windowsFiles") (map keyOf t.requires);
      val = k: overrides.${k} or g.tools.${k};
      def = k: g.tools.${k};
      runnerRows = builtins.filter (t: t.runner) groups.tools;
      sshd = toml.sshd or { };
      notion = (toml.claude or { }).notion or { };
      listText =
        none: empty: xs:
        if xs == null then
          none
        else if xs == [ ] then
          empty
        else
          lib.concatStringsSep "・" xs;
    in
    assert lib.assertMsg (
      unknown == [ ]
    ) "host-summary: ${name} の [tools] に知らない道具があります: ${lib.concatStringsSep ", " unknown}";
    assert lib.assertMsg (
      notBool == [ ]
    ) "host-summary: ${name} の [tools] の値は true か false で書いてください: ${lib.concatStringsSep ", " notBool}";
    {
      group = {
        value = group;
        source = if toml ? group then "host" else "unset";
      };
      tiers = map (t: {
        inherit (t) name mark label;
        option = null;
        value = if t.option == null then true else g.tiers.${t.name};
        default = if t.option == null then true else g.tiers.${t.name};
        source = if t.option == null then "default" else "group";
      }) groups.tiers;
      tools = map (
        t:
        let
          req = winReq t;
          value = val t.key;
          default = def t.key;
        in
        {
          inherit (t)
            key
            label
            short
            tiers
            ;
          marks = toolMarks t;
          column = columnOf t;
          option = "[tools] ${t.key}";
          inherit value default;
          effective = value && builtins.all val req;
          blocked = value && !(builtins.all val req);
          defaultEffective = default && builtins.all def req;
          requires = map (k: "[tools] ${k}") req;
          requiresOff = map (k: "[tools] ${k}") (builtins.filter (k: !(val k)) req);
          source = if overrides ? ${t.key} then "host" else "group";
        }
      ) runnerRows;
      runner = (toml.runner or { }).enable or false;
      # 図に描けない値 (md と HTML 版の「ホストの値」の節に並べる)
      extras = [
        {
          k = "受け持ち ([runner] enable)";
          v =
            if (toml.runner or { }).enable or false then
              "runner (dotfiles apply が WSL の setup と同じ手順も書く。WSL の setup は Windows に触らない)"
            else
              "WSL の setup (runner は Windows にしか無い手順だけを流す。WSL と同じ手順の道具は Nix のホストの値で決まる)";
        }
        {
          k = "op-reason の SSH の中継のモード ([opReason] sshRelayMode)";
          v =
            if (toml.opReason or { }) ? sshRelayMode then
              "${toml.opReason.sshRelayMode} (効くのは opReasonSshRelay が効くとき)"
            else
              "per-call (書いていない。効くのは opReasonSshRelay が効くとき)";
        }
        {
          k = "sshd に入れる鍵 ([sshd] authorizedKeys)";
          v =
            if sshd ? authorizedKeys then
              "${toString (builtins.length sshd.authorizedKeys)} 本"
              +
                lib.optionalString (sshd.authorizedKeys != [ ])
                  " (コメント: ${lib.concatMapStringsSep "・" keyComment sshd.authorizedKeys})"
            else
              "書いていない (鍵を置かない)";
        }
        {
          k = "sshd に入れるユーザー ([sshd] allowUsers)";
          v = listText "書いていない (Install-Sshd を流したユーザー)" "誰も入れない" (sshd.allowUsers or null);
        }
        {
          k = "sshd に入ってよい送り元 ([sshd] allowFrom)";
          v =
            if sshd ? allowFrom then
              (if sshd.allowFrom == [ ] then "どこからも入れない" else "${toString (builtins.length sshd.allowFrom)} 個")
            else
              "書いていない (tailnet と localhost)";
        }
        {
          k = "T3 Code の Claude に CLAUDE_CODE_ENTRYPOINT を空で渡すか ([t3Code] clearClaudeEntrypoint)";
          v = if (toml.t3Code or { }).clearClaudeEntrypoint or false then "渡す" else "渡さない";
        }
        {
          k = "Notion へ書く skill の宛先 ([claude.notion])";
          v =
            "profile: ${notion.profile or "書いていない"}"
            + lib.optionalString (
              notion ? routes
            ) " · routes: ${toString (builtins.length (builtins.attrNames notion.routes))} 本"
            + lib.optionalString (
              notion ? override
            ) " · override: ${lib.concatStringsSep "・" (builtins.attrNames notion.override)}";
        }
      ]
      ++
        lib.optional
          (builtins.any (k: !(builtins.elem k groups.runnerTools)) (builtins.attrNames overrides))
          {
            k = "runner が読まない道具の上書き ([tools])";
            v = lib.concatStringsSep "・" (
              builtins.filter (k: !(builtins.elem k groups.runnerTools)) (builtins.attrNames overrides)
            );
          };
    };

  winMd =
    name: wd:
    let
      set = builtins.filter (r: r.source == "host") wd.tools;
      blocked = builtins.filter (r: r.blocked) wd.tools;
    in
    "# `${name}`\n\n"
    + "🌐 ${mdLink "HTML 版: ${name} の道具 (Windows)" "./html/${name}.html"}\n\n"
    + "Windows の runner が読むホストの値から、設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 093)。図は HTML 版にある。\n\n"
    + "- ホストの値: ${mdLink "`win/hosts/${name}.toml`" "../../../win/hosts/${name}.toml"} (書き方は dotfiles の `win/README.md` の「ホストの値」)\n"
    + "- グループ: `${wd.group.value}` (${groupSource wd}) · ${tierLine wd}\n"
    + "- 入る道具: ${toString (countOn wd.tools)} / ${toString (builtins.length wd.tools)}\n"
    + "- ホストの値 ([tools]) で決めた値: ${listOr "なし" (map (r: "${r.label} ${onoff r.value}") set)}\n"
    +
      lib.optionalString (blocked != [ ])
        "- 効かない道具 (値は on だが、効く条件が off): ${
          lib.concatMapStringsSep "・" (
            r: "${r.label} (${lib.concatMapStringsSep "・" (p: "`${p}`") r.requiresOff} が off)"
          ) blocked
        }\n"
    + lib.concatMapStrings (x: "- ${x.k}: ${x.v}\n") wd.extras
    + "\n全ホストの図と一覧は ${mdLink "入口" "../README.md"}。\n\n"
    + mdGen;

  winBody =
    name: wd:
    let
      set = builtins.filter (r: r.source == "host") wd.tools;
      blocked = builtins.filter (r: r.blocked) wd.tools;
      hostFile = "win/hosts/${name}.toml";
    in
    "<header><h1>${codeTag name} の道具 (Windows)</h1>"
    + ''<p class="lead">Windows の runner が読むホストの値から、設定グループ・段・道具の on/off と、その値がどこで決まったか (dotfiles の ADR 093)。''
    + "タブで「このホスト」「既定 (ホストの値に何も書かなかったとき)」「重ねて比べる」を切り替える。箱を押すと値とどこで決まったかが出る。</p></header>\n"
    + figureSlot 0
    + "\n<h2>ホストの値</h2>\n<ul>"
    + "<li>ホストの値: ${aTag (blob privateRepo hostFile) (codeTag hostFile)} (書き方は ${aTag "${blob bodyRepo "win/README.md"}#ホストの値" "dotfiles の win/README.md の「ホストの値」"})</li>"
    + "<li>グループ: ${codeTag wd.group.value} (${esc (groupSource wd)}) · ${esc (tierLine wd)}</li>"
    + "<li>入る道具: ${toString (countOn wd.tools)} / ${toString (builtins.length wd.tools)}</li>"
    + "<li>ホストの値 ([tools]) で決めた値: ${
      esc (listOr "なし" (map (r: "${r.label} ${onoff r.value}") set))
    }</li>"
    +
      lib.optionalString (blocked != [ ])
        "<li>効かない道具 (値は on だが、効く条件が off): ${
          esc (
            lib.concatMapStringsSep "・" (
              r: "${r.label} (${lib.concatStringsSep "・" r.requiresOff} が off)"
            ) blocked
          )
        }</li>"
    + lib.concatMapStrings (x: "<li>${esc x.k}: ${esc x.v}</li>") wd.extras
    + "<li>全ホストの図と一覧: ${aTag (blob privateRepo "docs/hosts/README.md") "docs/hosts/ の入口"}</li>"
    + "</ul>\n<h2>道具の一覧</h2>\n"
    + "<p>太字はホストの値 ([tools]) で決めた値。「–」は値は on だが効く条件が off で効かない。</p>\n"
    + toolTable "ホストの値のキー" [
      {
        head = "このホスト";
        d = wd;
      }
    ]
    + "\n<h2>図の読み方</h2>\n"
    + readingList winReadingNote
    + htmlGen
    + "\n";

  winPages = name: wd: {
    win = {
      "${name}.md" = winMd name wd;
      html."${name}.html" = page {
        title = "${name} の道具 (Windows)";
        body = winBody name wd;
        figures = [
          (hostFigure {
            kind = "win";
            prefix = "";
            srcLabel = winSourceLabel;
            kindLabel = "ホストの値 ([tools]) ";
            inherit name;
            d = wd;
          })
        ];
      };
    };
  };

  # ---- 全ホストの入口 ----

  indexMd =
    nixEntries: winEntries:
    let
      winOf = n: builtins.filter (e: pcOf e.name == pcOf n) winEntries;
      nixOf = n: builtins.filter (e: pcOf e.name == pcOf n) nixEntries;
      # ホストのページへのリンク (dir は nix か win)
      page' = dir: n: mdLink "`${n}`" "./${dir}/${n}.md";
      nixRow =
        e:
        "| ${page' "nix" e.name} | `${e.d.group.value}` (${groupSource e.d}) | ${
          lib.concatMapStringsSep " · " (t: onoff t.value) e.d.tiers
        } | ${toString (countOn e.d.tools)} / ${toString (builtins.length e.d.tools)} | ${
          listOr "—" (map (w: page' "win" w.name) (winOf e.name))
        } |\n";
      winRow =
        e:
        "| ${page' "win" e.name} | `${e.d.group.value}` (${groupSource e.d}) | ${
          if e.d.runner then "runner" else "WSL の setup"
        } | ${toString (countOn e.d.tools)} / ${toString (builtins.length e.d.tools)} | ${
          listOr "—" (map (x: page' "nix" x.name) (nixOf e.name))
        } |\n";
    in
    "# 登録したホストの道具\n\n"
    + "🌐 ${mdLink "HTML 版: 登録したホストの道具" "./html/hosts.html"}\n\n"
    + "登録したホストごとに、どの道具が入るかを見せる (dotfiles の ADR 057・ADR 093)。"
    + "段 (① エンジニアの道具 ⊂ ② AI の道具 ⊂ ③ 個人のアカウント) を入れ子の領域に、道具を箱に、ホストを「入る道具だけを囲む色の線」に描いた図は HTML 版にある "
    + "(タブでホストを切り替え、全部を重ねても比べられる。箱を押すと option・値・どこで決まったかが出る)。\n\n"
    + "## Nix のホスト (WSL・Linux)\n\n"
    + "dotfiles-private の `nix/hosts/` のホスト (home-manager の値)。\n\n"
    + (
      if nixEntries == [ ] then
        "登録したホストはありません。\n"
      else
        "| ホスト | グループ | 段 (① ② ③) | 入る道具 | 同じ PC の Windows のホスト |\n| --- | --- | --- | --- | --- |\n"
        + lib.concatMapStrings nixRow nixEntries
    )
    + "\n## Windows のホスト (runner)\n\n"
    + "dotfiles-private の `win/hosts/` のホスト (Windows の runner の値。書き方は dotfiles の `win/README.md` の「ホストの値」)。\n\n"
    + (
      if winEntries == [ ] then
        "登録したホストはありません。\n"
      else
        "| ホスト | グループ | 受け持ち | 入る道具 | 同じ PC の Nix のホスト |\n| --- | --- | --- | --- | --- |\n"
        + lib.concatMapStrings winRow winEntries
    )
    + "\n## 図の読み方\n\n"
    + "- 灰色の入れ子の領域が段。③ の領域の「②③」の列は、② と ③ の両方の段が on のときだけ既定で入る道具\n"
    + "- 箱が道具。実線の箱は on、点線の箱は off、細かい点線の箱は値は on だが効く条件が off で効かない\n"
    + "- 色の線がホスト。線の中の箱が、そのホストで入る道具\n"
    + "- 同じ PC は、ホストの名前の @ の後ろ (PC の名前) を小文字にして比べた\n\n"
    + mdGen;

  indexBody =
    nixEntries: winEntries: nixFig: winFig:
    let
      winOf = n: builtins.filter (e: pcOf e.name == pcOf n) winEntries;
      nixOf = n: builtins.filter (e: pcOf e.name == pcOf n) nixEntries;
      page' = dir: n: aTag (blob privateRepo "docs/hosts/${dir}/${n}.md") (codeTag n);
      nixRow =
        e:
        "<tr><td>${page' "nix" e.name}</td><td>${codeTag e.d.group.value} (${esc (groupSource e.d)})</td><td>${
          lib.concatMapStringsSep " · " (t: onoff t.value) e.d.tiers
        }</td><td>${toString (countOn e.d.tools)} / ${toString (builtins.length e.d.tools)}</td><td>${
          listOr "—" (map (w: page' "win" w.name) (winOf e.name))
        }</td></tr>";
      winRow =
        e:
        "<tr><td>${page' "win" e.name}</td><td>${codeTag e.d.group.value} (${esc (groupSource e.d)})</td><td>${
          if e.d.runner then "runner" else "WSL の setup"
        }</td><td>${toString (countOn e.d.tools)} / ${toString (builtins.length e.d.tools)}</td><td>${
          listOr "—" (map (x: page' "nix" x.name) (nixOf e.name))
        }</td></tr>";
      tableCols =
        entries:
        map (e: {
          head = headOf e.name;
          inherit (e) d;
        }) entries;
    in
    "<header><h1>登録したホストの道具</h1>"
    + ''<p class="lead">登録したホストごとに、どの道具が入るかを見せる (dotfiles の ADR 057・ADR 093)。''
    + "タブでホストを切り替え、「重ねて比べる」で全部の線を重ねる。箱を押すと option・値・どこで決まったかが出る。</p></header>\n"
    + "<h2>Nix のホスト (WSL・Linux)</h2>\n"
    + (if nixFig == null then "<p>登録したホストはありません。</p>\n" else figureSlot nixFig + "\n")
    + "<h2>Windows のホスト (runner)</h2>\n"
    + (if winFig == null then "<p>登録したホストはありません。</p>\n" else figureSlot winFig + "\n")
    + "<h2>ホストの一覧</h2>\n"
    + lib.optionalString (nixEntries != [ ]) (
      "<h3>Nix のホスト (dotfiles-private の nix/hosts/)</h3>\n"
      + ''<div class="tablewrap"><table><thead><tr><th>ホスト</th><th>グループ</th><th>段 (① ② ③)</th><th>入る道具</th><th>同じ PC の Windows のホスト</th></tr></thead><tbody>''
      + lib.concatMapStrings nixRow nixEntries
      + "</tbody></table></div>\n"
    )
    + lib.optionalString (winEntries != [ ]) (
      "<h3>Windows のホスト (dotfiles-private の win/hosts/)</h3>\n"
      + ''<div class="tablewrap"><table><thead><tr><th>ホスト</th><th>グループ</th><th>受け持ち</th><th>入る道具</th><th>同じ PC の Nix のホスト</th></tr></thead><tbody>''
      + lib.concatMapStrings winRow winEntries
      + "</tbody></table></div>\n"
    )
    + "<p>同じ PC は、ホストの名前の @ の後ろ (PC の名前) を小文字にして比べた。</p>\n"
    + lib.optionalString (nixEntries != [ ]) (
      "<h2>道具の一覧 (Nix のホスト)</h2>\n"
      + "<p>太字はホストのファイル (か dotfiles-private の nix/shared/) で決めた値。「–」は値は on だが効く条件が off で効かない。</p>\n"
      + toolTable "option (dotfiles.…)" (tableCols nixEntries)
      + "\n"
    )
    + lib.optionalString (winEntries != [ ]) (
      "<h2>道具の一覧 (Windows のホスト)</h2>\n"
      + "<p>太字はホストの値 ([tools]) で決めた値。</p>\n"
      + toolTable "ホストの値のキー" (tableCols winEntries)
      + "\n"
    )
    + "<h2>図の読み方</h2>\n"
    + readingList (
      lib.optionalString (winEntries != [ ]) winReadingNote
      + "<li>箱の右下の点は、ホストごとに入るか (左からタブの順。塗った点が入る)</li>\n"
    )
    + htmlGen
    + "\n";

  # docs/hosts/ に書くファイルの全部 (path の組。private-host.sh summaries が nix eval --write-to で書き出す)。
  #   hosts           privateHosts の結果 (名前 → mkHome のホスト)
  #   winHosts        名前 → Windows のホストの値 (builtins.fromTOML の結果。flake の lib.windowsHosts)
  #   windowsGroups   グループごとの段と道具の既定 (flake の lib.windowsGroups)
  files =
    {
      hosts,
      winHosts ? { },
      windowsGroups,
    }:
    let
      nixEntries = map (n: {
        name = n;
        d = hosts.${n}.hostSummary.data;
      }) (sortNames hosts);
      winEntries = map (n: {
        name = n;
        d = winData windowsGroups n winHosts.${n};
      }) (sortNames winHosts);
      nixFig = if nixEntries == [ ] then null else 0;
      winFig =
        if winEntries == [ ] then
          null
        else if nixEntries == [ ] then
          0
        else
          1;
      figures =
        lib.optional (nixEntries != [ ]) (indexFigure {
          id = "nix";
          kind = "nix";
          title = "Nix のホスト";
          prefix = "dotfiles.";
          srcLabel = sourceLabel;
          entries = nixEntries;
        })
        ++ lib.optional (winEntries != [ ]) (indexFigure {
          id = "win";
          kind = "win";
          title = "Windows のホスト";
          prefix = "";
          srcLabel = winSourceLabel;
          entries = winEntries;
        });
    in
    lib.foldl' lib.recursiveUpdate {
      "README.md" = indexMd nixEntries winEntries;
      html."hosts.html" = page {
        title = "登録したホストの道具";
        body = indexBody nixEntries winEntries nixFig winFig;
        inherit figures;
      };
    } (map (e: pages e.name e.d) nixEntries ++ map (e: winPages e.name e.d) winEntries);

  # nix/groups.md の全文。plain はグループごとの素のホスト (グループだけを書いたもの) の data、examples は
  # [ { title; head; data; } ] (lib/group-examples.nix のホスト)
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
      # 作り物のホストの値の表の升。ホストで決めた値は太字
      cell = row: text: if isHost row then "**${text}**" else text;
      first = (builtins.head examples).data;
      exampleRow = label: cells: "| ${label} | ${lib.concatStringsSep " | " cells} |";
    in
    "<!-- 生成物 (dotfiles の nix/lib/host-summary/)。手で直さない -->\n\n"
    + "> 生成物。手で直さない。出し直すのは dotfiles の root で `nix eval --raw ./nix#lib.groupsDoc > nix/groups.md`。古ければ CI (flake の checks の groups-doc) が落ちる。\n"
    + "\n# 設定グループ\n\n"
    + "ホストは設定グループを 1 つ選び (`mkHome` の `group`)、グループは「どの段の道具まで入れるか」で決まる (dotfiles-private の ADR 057)。"
    + "選び方・直し方・setup の振る舞いは [README の「設定グループ」](./README.md#設定グループ)。ここは `nix/lib/groups.nix` の表と、作り物のホストの値から作った生成物。"
    + "登録したホストごとの図 (段の入れ子の領域と、ホストごとの囲みの線) は dotfiles-private の `docs/hosts/` にある (dotfiles-private の ADR 093)。\n\n"
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
    + "\n## 作り物のホストの値\n\n"
    + "`nix/lib/group-examples.nix` のホスト (どれも WSL で `win/` を配る。値は作り物)。**太字**はホストで決めた値。"
    + "「–」は値は on だが、効く条件が off で効かない。\n\n"
    + lib.concatMapStrings (e: "- `${e.head}`: ${e.title}\n") examples
    + "\n| 道具 | ${lib.concatMapStringsSep " | " (e: "`${e.head}`") examples} |\n"
    + "| --- | ${lib.concatMapStringsSep " | " (_: "---") examples} |\n"
    + exampleRow "グループ" (map (e: cell e.data.group "`${e.data.group.value}`") examples)
    + "\n"
    + lib.concatImapStrings (
      i: t:
      exampleRow "${t.mark} ${t.label}" (
        map (
          e: cell (builtins.elemAt e.data.tiers (i - 1)) (onoff (builtins.elemAt e.data.tiers (i - 1)).value)
        ) examples
      )
      + "\n"
    ) first.tiers
    + lib.concatImapStrings (
      i: r:
      exampleRow "${r.marks} ${r.label}" (
        map (
          e: cell (builtins.elemAt e.data.tools (i - 1)) (shown (builtins.elemAt e.data.tools (i - 1)))
        ) examples
      )
      + "\n"
    ) first.tools;
in
{
  inherit
    data
    line
    text
    pages
    winData
    winPages
    files
    groupsDoc
    ;
}
