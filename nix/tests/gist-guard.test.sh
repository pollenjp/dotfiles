#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/gist-guard.sh の振る舞いを、合成した hook の入力と使い捨ての git の repo で確かめる。
#
#   bash nix/tests/gist-guard.test.sh [<gist-guard.sh のパス>]
#
# flake の checks (gist-guard-test) が Nix のサンドボックスで流す。使うのは bash・jq・git・coreutils と stdenv の awk
# だけ。hook はコマンドを打たずに止めるか通すかを決めるだけなので、gist にもペースト共有のサービスにも送らない
# (ネットワークに出ない。repo の remote の URL は gist.github.com などにするが push はしない)。
#
# ## 確かめること
#
#   gist を作る・書き換えるもの:
#   - gh gist create・new・edit・rename と知らない subcommand を止め、list・ls・view・clone・delete・--help は通す
#     (hub gist create と、GitLab の glab snippet create・new も止める)
#   - gh api の gists への書き込み (-f・-F・--input で POST になるもの・-X POST・PATCH・PUT・full URL) を止め、GET・DELETE と
#     gists でない endpoint は通す
#   - curl・wget・HTTPie (http・https・xh) での gist の API への書き込みを止め、GET は通す
#   - git push の先が gist (remote の URL・push の URL (複数のときはどれか)・git -c の push の URL・引数の URL・同じコマンドの
#     git remote add・set-url・GHES の …/gist/… と gist.<host>) なら止め、github.com の repo への push と gist の clone・fetch
#     は通す
#
#   ペースト共有のサービス:
#   - curl の -F・-d・--upload-file (-G でも)、wget の --post-file、HTTPie の本文・stdin での送信と、nc・socat・telnet での
#     termbin への送信、/dev/tcp への書き込み (> f・exec 3<> f・{ } > f・( ) > f) を止め、GET・DELETE と /dev/tcp から読む
#     だけのものは通す。"$URL" に入れておいた URL も読む
#   - pastebinit・gist (gem)・haste などの専用のコマンドを止め、--help・--version は通す
#   - python などの -c の中・引数・stdin・同じコマンドで書いた .py に gist の API かペースト共有のサービスの URL か、gist を
#     作る呼び出し (create_gist) があれば止める
#
#   読み方:
#   - 包むコマンド (timeout・env・env -S・sudo・bash -c・eval・nix develop -c・mise exec --・ssh <host> <コマンド>)・cd・
#     パイプの先・find -exec の中も見る
#   - commit の message・grep の引数・echo・heredoc の本文に書いただけでは止めない
#   - 同じコマンドで書いた script のファイルを bash・source・. で流すと、書いた中身を読む
#   - 64 KB を超えるコマンドは中を読まず、上げる形の文字 (nc の宛先・push の先が gist の git push も) があれば止めてコマンドを
#     分けるよう返し、無ければ黙る
#
#   MCP の tool:
#   - 名前に gist と書き込みの語を含む tool (create_gist・update_gist。server の名前の gists も語に数える) を止め、
#     get_gist・list_gists は通す
#
#   返す文と黙るとき:
#   - 止めた文に、止めたもの・わけ・回り込まないこと・ユーザーが ! で打つこと・Notion の HTML ブロックを書き、通す口を書かない
#   - Bash と MCP の tool 以外・PreToolUse でない event・壊れた入力・空の入力は黙り、いつも exit 0。止める出力は
#     permissionDecision が deny の 1 行の JSON だけ

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/gist-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/gist-guard-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# compgen は readline の無い bash (Nix のサンドボックスの bash) に無いので、名前の頭で引く形を使う
for v in ${!GIT_CONFIG_@}; do
  unset "${v}"
done
export HOME="${work}/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${work}/empty.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "${HOME}"
: >"${GIT_CONFIG_GLOBAL}"

# 作業する repo (origin は github.com の repo。push はしない)
repo="${work}/repo"
git init -q -b main "${repo}"
git -C "${repo}" remote add origin https://github.com/pollenjp/dotfiles.git
git -C "${repo}" commit -q --allow-empty -m "init"
mkdir -p "${repo}/sub"
printf 'hello\n' >"${repo}/a.txt"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# run_input <JSON>: hook に入力を渡して流す
run_input() {
  printf '%s' "$1" >"${work}/in"
  bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
# pre <コマンド> [<cwd>]: PreToolUse (Bash) の入力で流す
pre() {
  run_input "$(jq -cn --arg c "$1" --arg d "${2:-${repo}}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "d"}, cwd: $d}')"
}
# mcp <tool の名前>: PreToolUse (MCP の tool) の入力で流す
mcp() {
  run_input "$(jq -cn --arg t "$1" --arg d "${repo}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: $t, tool_input: {description: "d", files: {"a.txt": {content: "x"}}}, cwd: $d}')"
}
silent() {
  [[ ! -s ${work}/stdout && $(cat "${work}/rc") == 0 ]]
}
# 止めたか: exit 0・1 行の JSON・PreToolUse の deny と理由だけ
denied_shape='[["hookSpecificOutput"],["hookEventName","permissionDecision","permissionDecisionReason"],"PreToolUse","deny"]'
denied() {
  local got
  got=$(jq -c '[keys, (.hookSpecificOutput | keys), .hookSpecificOutput.hookEventName, .hookSpecificOutput.permissionDecision]' \
    "${work}/stdout" 2>/dev/null)
  [[ $(cat "${work}/rc") == 0 && $(wc -l <"${work}/stdout") == 1 && ${got} == "${denied_shape}" ]]
}
reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "${work}/stdout" 2>/dev/null
}
detail() {
  echo "rc=$(cat "${work}/rc") stdout=$(cat "${work}/stdout") stderr=$(cat "${work}/stderr")"
}
show() {
  local s=${1//$'\n'/⏎}
  printf '%s' "${s:0:100}"
}

# expect_deny <コマンド> [<cwd>]: 止める
expect_deny() {
  pre "$@"
  if denied; then
    ok "止める: $(show "$1")"
  else
    ng "止める: $(show "$1")" "$(detail)"
  fi
}
# expect_allow <コマンド> [<cwd>]: 黙って通す
expect_allow() {
  pre "$@"
  if silent; then
    ok "通す: $(show "$1")"
  else
    ng "通す: $(show "$1")" "$(detail)"
  fi
}
# expect_reason <説明> <コマンド> <cwd> <理由に含む文>…: 止めて、理由にどの文も含む
expect_reason() {
  local what=$1 cmd=$2 cwd=$3 r s missing=""
  shift 3
  pre "${cmd}" "${cwd}"
  r=$(reason)
  for s in "$@"; do
    [[ ${r} == *"${s}"* ]] || missing+="「${s}」"
  done
  if denied && [[ -z ${missing} ]]; then
    ok "${what}"
  else
    ng "${what}" "無い: ${missing} / $(detail)"
  fi
}

echo "== gist-guard.sh: gh gist"

for cmd in "gh gist create a.txt" "gh gist create --public a.txt" "gh gist new a.txt" "gh gist create -d x -" \
  "gh gist edit 0123abcd --add a.txt" "gh gist rename 0123abcd a.txt b.txt" "gh gist fork 0123abcd" \
  "/usr/bin/gh gist create a.txt" "gh.exe gist create a.txt"; do
  expect_deny "${cmd}"
done
for cmd in "gh gist list" "gh gist ls --public" "gh gist view 0123abcd" "gh gist view 0123abcd --raw" \
  "gh gist clone 0123abcd" "gh gist delete 0123abcd --yes" "gh gist" "gh gist create --help" "gh gist --help" \
  "gh help gist" "gh pr create --title x --body y" "gh repo view"; do
  expect_allow "${cmd}"
done
for cmd in "hub gist create a.txt" "glab snippet create a.txt --title x" "glab snippet new a.txt"; do
  expect_deny "${cmd}"
done
for cmd in "hub gist show 0123abcd" "glab snippet list" "glab snippet create --help"; do
  expect_allow "${cmd}"
done

echo "== gist-guard.sh: gh api"

for cmd in "gh api gists -f description=x -f 'files[a.txt][content]=hello'" "gh api /gists --input body.json" \
  "gh api -X POST gists" "gh api --method PATCH gists/0123abcd -f description=x" "gh api -XPUT gists/0123abcd/star" \
  "gh api gists/0123abcd/comments -f body=x" "gh api --method=post /gists --input -" \
  "gh api https://api.github.com/gists -F 'files[a.txt][content]=@a.txt'" \
  "gh api --hostname ghes.example.com https://ghes.example.com/api/v3/gists --input body.json" \
  "hub api gists -F 'files[a.txt][content]=@a.txt'"; do
  expect_deny "${cmd}"
done
for cmd in "gh api gists" "gh api gists/0123abcd" "gh api /gists/0123abcd --jq .files" "gh api -X DELETE gists/0123abcd" \
  "gh api --method GET gists -f per_page=100" "gh api users/pollenjp/gists" "gh api repos/pollenjp/dotfiles/issues -f title=x" \
  "gh api graphql -f query='{ viewer { login } }'"; do
  expect_allow "${cmd}"
done

echo "== gist-guard.sh: curl・wget と gist の API"

for cmd in "curl -X POST https://api.github.com/gists -d @body.json" "curl -sS -d @body.json https://api.github.com/gists" \
  "curl --request PATCH https://api.github.com/gists/0123abcd --data '{}'" "curl -fsSL --json @body.json api.github.com/gists" \
  "curl -H 'Authorization: token x' -X POST https://ghes.example.com/api/v3/gists -d @b.json" \
  "wget --post-file=body.json https://api.github.com/gists" "wget --method=PATCH --body-file=b.json https://api.github.com/gists/1" \
  "http POST https://api.github.com/gists description=x" "xh api.github.com/gists description=x"; do
  expect_deny "${cmd}"
done
for cmd in "http GET https://api.github.com/gists" "https api.github.com/gists/0123abcd"; do
  expect_allow "${cmd}"
done
for cmd in "curl -s https://api.github.com/gists/0123abcd" "curl -sI https://api.github.com/gists" \
  "curl -G -d per_page=5 https://api.github.com/gists" "curl -X DELETE https://api.github.com/gists/0123abcd" \
  "curl -s https://gist.githubusercontent.com/u/0123abcd/raw/a.txt" "wget -q https://api.github.com/gists/0123abcd" \
  "curl -sS -d @body.json https://api.github.com/repos/pollenjp/dotfiles/issues"; do
  expect_allow "${cmd}"
done

echo "== gist-guard.sh: git push と gist"

# new_repo <名前> <origin の URL>: init の commit がある repo を作る
new_repo() {
  local r="${work}/$1"
  git init -q -b main "${r}"
  git -C "${r}" remote add origin "$2"
  git -C "${r}" commit -q --allow-empty -m "init"
  printf '%s' "${r}"
}
g1=$(new_repo g1 https://gist.github.com/0123abcd.git)
g2=$(new_repo g2 git@gist.github.com:0123abcd.git)
for cmd in "git push" "git push origin main" "git push -f origin HEAD" "git -C ${g1} push" "cd ${g1} && git push" \
  "timeout 60 git push" "git gh push"; do
  expect_deny "${cmd}" "${g1}"
done
expect_deny "git push" "${g2}"
expect_deny "git push https://gist.github.com/0123abcd.git main"
expect_deny "git remote add gist https://gist.github.com/0123abcd.git && git push gist main"
r=$(new_repo g3 https://github.com/pollenjp/dotfiles.git)
git -C "${r}" config remote.origin.pushurl git@gist.github.com:0123abcd.git
expect_deny "git push" "${r}"
expect_deny "git push origin main" "${r}"
# push の URL が複数なら、どれかが gist なら止める
r=$(new_repo g4 https://github.com/pollenjp/dotfiles.git)
git -C "${r}" config --add remote.origin.pushurl https://github.com/pollenjp/dotfiles.git
git -C "${r}" config --add remote.origin.pushurl https://gist.github.com/0123abcd.git
expect_deny "git push" "${r}"
for cmd in "git push https://ghes.example.com/gist/0123abcd.git main" "git push git@ghes.example.com:gist/0123abcd.git main" \
  "git push https://gist.ghes.example.com/0123abcd.git main" \
  "git -c remote.origin.pushurl=https://gist.github.com/0123abcd.git push origin main" \
  "git remote set-url --push origin https://gist.github.com/0123abcd.git && git push"; do
  expect_deny "${cmd}"
done
for cmd in "git push" "git push origin main" "git push --dry-run" "git clone https://gist.github.com/0123abcd.git" \
  "git fetch https://gist.github.com/0123abcd.git" "git remote add gist https://gist.github.com/0123abcd.git"; do
  expect_allow "${cmd}"
done
for cmd in "git push --dry-run" "git push -n origin main" "git push --help" "git fetch" "git pull"; do
  expect_allow "${cmd}" "${g1}"
done

echo "== gist-guard.sh: ペースト共有のサービス"

for cmd in "curl -F 'file=@a.txt' https://0x0.st" "curl -sF file=@a.txt 0x0.st" "curl --upload-file a.txt https://transfer.sh/a.txt" \
  "curl -T a.txt https://temp.sh" "curl --data-binary @a.txt https://paste.rs" "curl -d 'api_paste_code=x' https://pastebin.com/api/api_post.php" \
  "curl -X POST https://dpaste.com/api/v2/ -F content=x" "curl -sS -F 'sprunge=<-' http://sprunge.us < a.txt" \
  "wget --post-file=a.txt https://paste.rs" "nc termbin.com 9999 < a.txt" "cat a.txt | nc termbin.com 9999" \
  "cat a.txt > /dev/tcp/termbin.com/9999" "curl -F 'file=@a.txt' https://litterbox.catbox.moe/resources/internals/api.php"; do
  expect_deny "${cmd}"
done
for cmd in "socat - TCP:termbin.com:9999 < a.txt" "telnet termbin.com 9999 < a.txt" "exec 3<>/dev/tcp/termbin.com/9999" \
  "{ cat a.txt; } > /dev/tcp/termbin.com/9999" "(cat a.txt) >/dev/tcp/termbin.com/9999" \
  "URL=https://0x0.st; curl -F file=@a.txt \"\$URL\"" "export U=https://paste.rs && curl --data-binary @a.txt \$U" \
  "curl -G -d @a.txt https://0x0.st" "http -f POST https://0x0.st file@a.txt" "http https://paste.rs < a.txt" \
  "echo x | xh 0x0.st"; do
  expect_deny "${cmd}"
done
for cmd in "curl -s https://0x0.st/abcd.txt" "curl -sO https://paste.rs/abcd" "wget https://transfer.sh/abcd/a.txt" \
  "curl -s https://example.com/0x0.st" "nc -z example.com 443" "cat < /dev/tcp/termbin.com/9999" \
  "curl -X DELETE https://0x0.st/abcd" "http https://0x0.st/abcd.txt"; do
  expect_allow "${cmd}"
done
for cmd in "pastebinit a.txt" "pastebinit -i a.txt -b paste.ubuntu.com" "cat a.txt | pastebinit" "wgetpaste a.txt" \
  "fpaste a.txt" "gist a.txt" "haste < a.txt"; do
  expect_deny "${cmd}"
done
for cmd in "pastebinit --help" "pastebinit -h" "pastebinit -l" "wgetpaste --version" "which pastebinit" "man pastebinit" \
  "gist --help"; do
  expect_allow "${cmd}"
done
for cmd in "python3 -c 'import requests; requests.post(\"https://0x0.st\", files={\"file\": open(\"a.txt\")})'" \
  "node -e 'fetch(\"https://api.github.com/gists\", {method: \"POST\", body: \"{}\"})'" \
  "python3 - <<'EOF'
import urllib.request
urllib.request.urlopen(urllib.request.Request('https://paste.rs', data=b'x'))
EOF" "python3 upload.py https://0x0.st a.txt" "cat > up.py <<'EOF'
import requests
requests.post('https://0x0.st', files={'file': open('a.txt', 'rb')})
EOF
python3 up.py" "python3 -c 'from github import Github; Github(\"t\").get_user().create_gist(True, {})'" \
  "ruby -e 'Octokit::Client.new.create_gist(files: {})'" \
  "perl -e 'use LWP::UserAgent; LWP::UserAgent->new->post(\"https://paste.rs\", Content => \"x\")'"; do
  expect_deny "${cmd}"
done
expect_allow "python3 -c 'print(1 + 1)'"
expect_allow "python3 -c 'import urllib.request; urllib.request.urlopen(\"https://example.com/0x0.st\")'"

echo "== gist-guard.sh: 包むコマンド・cd・パイプ"

for cmd in "timeout 30 gh gist create a.txt" "env GH_HOST=github.com gh gist create a.txt" "GH_HOST=github.com gh gist create a.txt" \
  "sudo -u nobody gh gist create a.txt" "bash -c 'gh gist create a.txt'" "sh -lc \"gh gist new a.txt\"" "eval 'gh gist create a.txt'" \
  "nix develop -c gh gist create a.txt" "cd sub && gh gist create ../a.txt" "echo hi | gh gist create -" \
  "find . -name '*.txt' -exec gh gist create {} \\;" "ls *.txt | xargs gh gist create" "URL=\$(gh gist create a.txt)" \
  "if true; then gh gist create a.txt; fi" "bash <<'EOF'
gh gist create a.txt
EOF" "ssh host.example.com 'gh gist create a.txt'" "ssh -p 2222 host.example.com gh gist create a.txt" \
  "mise exec node@20 -- gh gist create a.txt" "env -S 'gh gist create a.txt'"; do
  expect_deny "${cmd}"
done
expect_allow "ssh host.example.com 'gh gist view 0123abcd'"

echo "== gist-guard.sh: 書いただけでは止めない"

for cmd in "git commit -m 'feat: gh gist create を止める hook を足す'" "grep -rn 'gh gist create' ." "rg 'curl.*0x0.st' nix" \
  "echo gh gist create a.txt" "printf '%s\\n' 'gh gist create a.txt'" "gh pr create --title x --body 'gh gist create を止める'" \
  "cat > notes.md <<'EOF'
gh gist create a.txt
curl -F file=@a.txt https://0x0.st
EOF" "jq -n '\"gh gist create\"'" "ls gist-guard.sh"; do
  expect_allow "${cmd}"
done

echo "== gist-guard.sh: 同じコマンドで書いた script"

expect_deny "cat > up.sh <<'EOF'
gh gist create a.txt
EOF
bash up.sh"
expect_deny "printf 'curl -F file=@a.txt https://0x0.st\\n' > up.sh && sh up.sh"
expect_deny "cat > up.sh <<'EOF'
gh gist create a.txt
EOF
source up.sh"
expect_deny "echo 'curl -F file=@a.txt https://0x0.st' > up.sh; . ./up.sh"
expect_allow "cat > up.sh <<'EOF'
gh gist view 0123abcd
EOF
bash up.sh"

echo "== gist-guard.sh: 長いコマンド"

# 64 KB (Nix のサンドボックスの stdenv には gawk がある) を超えるコマンドは中を読まない
long=$(printf 'あいうえおかきくけこ%.0s' $(seq 1 2500))
expect_reason "長いコマンドに gh gist create があれば、分けるよう返して止める" "cat > notes.md <<'EOF'
${long}
EOF
gh gist create notes.md" "${repo}" "コマンドが長すぎて" "分けて"
expect_deny "cat > notes.md <<'EOF'
${long}
EOF
curl -F file=@notes.md https://0x0.st"
expect_allow "cat > notes.md <<'EOF'
${long}
EOF
gh gist view 0123abcd"
expect_deny "cat > notes.md <<'EOF'
${long}
EOF
nc termbin.com 9999 < notes.md"
# 長いコマンドの git push は、今の dir の push の先で決める
expect_deny "cat > notes.md <<'EOF'
${long}
EOF
git push" "${g1}"
expect_allow "cat > notes.md <<'EOF'
${long}
EOF
git push" "${repo}"

echo "== gist-guard.sh: MCP の tool"

for t in mcp__github__create_gist mcp__github__update_gist mcp__claude_ai_GitHub__create_gist mcp__gists__createGist \
  mcp__gists__create; do
  mcp "${t}"
  if denied && [[ $(reason) == *"${t}"* ]]; then ok "止める: ${t}"; else ng "止める: ${t}" "$(detail)"; fi
done
for t in mcp__github__get_gist mcp__github__list_gists mcp__github__delete_gist mcp__logistics__create_order; do
  mcp "${t}"
  if silent; then ok "通す: ${t}"; else ng "通す: ${t}" "$(detail)"; fi
done

echo "== gist-guard.sh: 返す文"

expect_reason "止めたもの・わけ・回り込まないこと・! で打つこと・Notion の HTML ブロックを書く" "gh gist create a.txt" "${repo}" \
  "[gist-guard]" "gh gist create" "private な中身" "回り込まない" "script のファイル" "! gh gist create" \
  "Notion の HTML ブロック" "embed.file_upload"
expect_reason "ペースト共有のサービスの名前を書く" "curl -F 'file=@a.txt' https://0x0.st" "${repo}" "0x0.st" "ペースト共有のサービス"
expect_reason "gist への push の先を書く" "git push" "${g1}" "gist.github.com"
pre "gh gist create a.txt"
r=$(reason)
if [[ ${r} != *PJP_ALLOW* && ${r} != *"=1"* ]]; then
  ok "通す口を書かない"
else
  ng "通す口を書かない" "${r}"
fi

echo "== gist-guard.sh: 黙るとき"

for in in '' 'not json' '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"gh gist create a.txt"}}' \
  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/gist.txt"}}' '{"tool_name":"Bash","tool_input":{}}' \
  '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh gist create a.txt"}}'; do
  run_input "${in}"
  if silent; then
    ok "黙る: $(show "${in:-(空)}")"
  else
    ng "黙る: $(show "${in:-(空)}")" "$(detail)"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
