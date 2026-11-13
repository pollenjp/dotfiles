#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/install-iac-guard.sh の振る舞いを、合成した hook の入力で確かめる。
#
#   bash nix/tests/install-iac-guard.test.sh [<install-iac-guard.sh のパス>]
#
# flake の checks (install-iac-guard-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils と stdenv の awk
# だけ。hook はコマンドを打たずに止めるか通すかを決めるだけなので、何も入れず、terraform も呼ばない。HOME は使い捨ての
# dir にし (IaC の guard を外す ~/.local/state/dotfiles/claude-iac-guard.json を置き換える)、流す人の VIRTUAL_ENV は外す。
#
# ## 確かめること
#
#   install (venv・project の外へ入れるもの):
#   - venv の印の無い pip・pip3・python -m pip・python3 -m pip の install、sudo 付き・--user・--break-system-packages
#     (venv の中のパスでも)・uv pip install --system を止める (/usr/bin/python3 -m pip もパスの interpreter だが venv で
#     ない)
#   - venv の印 (venv の中のパスの interpreter・root に pyvenv.cfg がある・同じコマンドで作った venv・同じコマンドの先の
#     activate・uv run などの後ろ・hook の env の VIRTUAL_ENV) があれば通す。--system の無い uv pip install・-t (dir を
#     指して入れる)・--help も通す
#   - npm install -g・npm i -g・--global・npm -g install・pnpm add -g・yarn global add・bun add -g を止め、npm install
#     (引数なし・project へ)・pnpm add (project へ)・pipx install・cargo install・uv tool install・go install は通す
#   - apt install・apt-get install (sudo・-y を前に置いたものも)・brew install を止める
#   - cd・bash -c・env・mise exec -- の中と、sudo・time の後ろの VAR=値 の後ろも読む。cat <<EOF | bash・echo … | bash で渡した
#     中身も読む。commit の message・echo・heredoc の本文に書いた pip install は止めない
#   - パスで呼ぶ interpreter はパスで決める ($HOME/.local/bin/pip・activate の後の /usr/bin/python3 -m pip は止める)。
#     UV_SYSTEM_PYTHON=1・--python <venv でないパス> の uv pip install と、値を取る global の flag の後ろの uv pip install
#     --system も止める
#   - 確かめるだけの形 (pip install --dry-run・apt-get install -s・brew install --dry-run・npm install -g --dry-run・
#     terraform state rm -dry-run) は通す
#   - 通す口 PJP_ALLOW_INSTALL=1 (頭の代入と env の引数) で通す。PJP_ALLOW_IAC=1 では install を通さない
#
#   IaC (terraform・tofu・terragrunt で実物を変えるもの):
#   - apply・destroy・import・state rm・mv・push・replace-provider・taint・untaint・force-unlock・refresh・workspace delete・
#     -migrate-state・-force-copy 付きの init を止める (-chdir=… を前に置いたもの・cd・代入・timeout の後ろも)
#   - terragrunt の apply・run --all apply・run -- apply・stack run apply・run-all destroy・apply-all・
#     --log-level debug apply・backend delete を止める
#   - plan (-destroy も)・validate・fmt・init (-upgrade も)・output・show・state list・show・pull・graph・providers・test・
#     workspace select・-help、terragrunt の run --all plan・stack generate・hcl fmt は通す。包み (make apply・mise run
#     apply・repo の script) と git apply・kubectl apply は通す
#   - 通す口 PJP_ALLOW_IAC=1 で通す。PJP_ALLOW_INSTALL=1 では IaC を通さない
#   - ~/.local/state/dotfiles/claude-iac-guard.json の enable が false なら IaC は通す (install は止める)。ファイルが
#     無い・壊れているときは止める
#
#   そのほか:
#   - 止めるときは exit 0 で 1 行の JSON (PreToolUse の deny と理由) を出し、理由に止めたコマンドと通す口を書く
#   - 読む長さ (64 KB) を超えたコマンドは、行に install・IaC の形があれば止め (理由に「長すぎて」)、無ければ通す。区切りの
#     多い 80 KB の 1 行も 20 秒のうちに読み終える。sudo -E pip install・FOO="a b" terraform apply・bash -c 'terraform apply'
#     は止め、npm ls -g・init -migrate-state=false・activate の後の素の pip・terraform plan・npm install foo は通す
#   - lexer の本文は xref-guard.sh と同じ (hook-lexer-copy.test.sh が確かめる)。IaC を止めた理由に --no-iac-guard も書く
#   - Bash でない tool・壊れた入力・どのコマンドにも当たらない入力は黙って exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/install-iac-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/install-iac-guard-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

unset VIRTUAL_ENV
export HOME="${work}/home"
mkdir -p "${HOME}"
state_dir="${HOME}/.local/state/dotfiles"

# 作業する dir。box/ は pyvenv.cfg のある venv (名前に venv の語が無い)
repo="${work}/repo"
mkdir -p "${repo}/box/bin" "${repo}/plain/bin"
printf 'home = /usr/bin\n' >"${repo}/box/pyvenv.cfg"

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

# run_input <JSON>: hook に入力を渡して流す (環境の VAR=値 は呼び元で前に付ける)
run_input() {
  printf '%s' "$1" >"${work}/in"
  bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
# pre_json <コマンド>: PreToolUse (Bash) の入力
pre_json() {
  jq -cn --arg c "$1" --arg d "${repo}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "d"}, cwd: $d}'
}
pre() {
  run_input "$(pre_json "$1")"
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
# expect_deny <コマンド> <理由に含む文字>: 止め、理由に止めたものを書く
expect_deny() {
  local r
  pre "$1"
  r=$(reason)
  if denied && [[ ${r} == *"$2"* ]]; then
    ok "止める: $(show "$1")"
  else
    ng "止める: $(show "$1") (理由に「$2」)" "$(detail)"
  fi
}
# expect_allow <コマンド>: 黙って通す
expect_allow() {
  pre "$1"
  if silent; then
    ok "通す: $(show "$1")"
  else
    ng "通す: $(show "$1")" "$(detail)"
  fi
}

echo "== install-iac-guard.sh"

echo "-- install: 止める"
expect_deny 'pip install requests' 'pip install'
expect_deny 'pip3 install --user foo' '--user'
expect_deny 'python3 -m pip install foo' 'pip install'
expect_deny 'python -m pip install -r requirements.txt' 'pip install'
expect_deny '/usr/bin/python3 -m pip install foo' 'pip install'
expect_deny 'sudo pip install foo' 'sudo'
expect_deny 'sudo -H pip3 install foo' 'sudo'
expect_deny '.venv/bin/pip install --break-system-packages foo' '--break-system-packages'
expect_deny 'uv pip install --system foo' 'uv pip install --system'
expect_deny 'npm install -g foo' 'npm install -g'
expect_deny 'npm i -g foo' 'npm i -g'
expect_deny 'npm install --global foo' 'npm install -g'
expect_deny 'npm -g install foo' 'npm install -g'
expect_deny 'pnpm add -g foo' 'pnpm add -g'
expect_deny 'yarn global add foo' 'yarn global add'
expect_deny 'bun add -g foo' 'bun add -g'
expect_deny 'sudo apt install -y foo' 'apt install'
expect_deny 'apt-get install foo' 'apt-get install'
expect_deny 'sudo apt-get -y install foo' 'apt-get install'
expect_deny 'DEBIAN_FRONTEND=noninteractive apt-get install -y foo' 'apt-get install'
expect_deny 'brew install foo' 'brew install'
expect_deny 'cd sub && pip install foo' 'pip install'
expect_deny "bash -c 'pip install foo'" 'pip install'
expect_deny 'env A=1 pip install foo' 'pip install'
expect_deny 'mise exec -- pip install foo' 'pip install'
expect_deny 'plain/bin/pip install foo' 'pip install'
expect_deny 'pip install --prefix /usr/local foo' 'pip install'
expect_deny 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y foo' 'apt-get install'
expect_deny 'sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y foo' 'apt-get install'
expect_deny 'sudo PIP_BREAK_SYSTEM_PACKAGES=1 pip install foo' 'sudo'
# shellcheck disable=SC2016 # $HOME を文字のまま渡す
expect_deny '$HOME/.local/bin/pip install foo' 'pip install'
expect_deny 'source .venv/bin/activate && /usr/bin/python3 -m pip install foo' 'pip install'
expect_deny 'UV_SYSTEM_PYTHON=1 uv pip install foo' 'uv pip install'
expect_deny 'uv pip install --python /usr/bin/python3 foo' 'uv pip install --python'
expect_deny 'uv --directory app pip install --system foo' 'uv pip install --system'
expect_deny "cat <<'EOF' | bash
pip install foo
EOF" 'pip install'
expect_deny "echo 'npm install -g foo' | sh" 'npm install -g'

echo "-- install: 通す"
expect_allow '.venv/bin/pip install foo'
expect_allow 'venv/bin/python -m pip install foo'
expect_allow '/home/u/proj/.venv/bin/python3 -m pip install -e .'
expect_allow 'source .venv/bin/activate && pip install -r requirements.txt'
expect_allow '. venv/bin/activate; pip install foo'
expect_allow 'uv run pip install foo'
expect_allow 'uv run --with x -- python -m pip install foo'
expect_allow 'poetry run pip install foo'
expect_allow 'pdm run pip install foo'
expect_allow 'hatch run pip install foo'
expect_allow 'uv pip install foo'
expect_allow 'uv pip install -r requirements.txt'
expect_allow 'python3 -m venv /tmp/x && /tmp/x/bin/pip install foo'
expect_allow 'uv venv /tmp/y && /tmp/y/bin/python -m pip install foo'
expect_allow 'virtualenv /tmp/z; /tmp/z/bin/pip install foo'
expect_allow './box/bin/pip install foo'
# shellcheck disable=SC2016 # 変数を含むパスを文字のまま渡す
expect_allow '"${VENV_DIR}/bin/pip" install foo'
expect_allow 'pip install -t ./vendor foo'
expect_allow 'pip install --target=./vendor foo'
expect_allow 'pip install --help'
expect_allow 'pip install --dry-run foo'
expect_allow 'sudo apt-get install -s foo'
expect_allow 'apt-get install --simulate foo'
expect_allow 'brew install --dry-run foo'
expect_allow 'npm install -g --dry-run foo'
expect_allow 'sudo PJP_ALLOW_INSTALL=1 apt install foo'
expect_allow 'uv pip install --python .venv/bin/python foo'
expect_allow 'python3 -m virtualenv /tmp/q && /tmp/q/bin/pip install foo'
# shellcheck disable=SC2016 # $HOME を文字のまま渡す
expect_allow '"$HOME/proj/.venv/bin/pip" install foo'
expect_allow "cat <<'EOF' | bash
ls -la
EOF"
expect_allow 'pip download foo'
expect_allow 'pip list'
expect_allow 'npm install foo'
expect_allow 'npm install'
expect_allow 'npm ci'
expect_allow 'pnpm add foo'
expect_allow 'pnpm install'
expect_allow 'yarn add foo'
expect_allow 'bun add foo'
expect_allow 'pipx install foo'
expect_allow 'cargo install foo'
expect_allow 'uv tool install foo'
expect_allow 'go install example.com/x@latest'
expect_allow 'apt list --installed'
expect_allow 'brew list'
expect_allow 'git commit -m "pip install foo"'
expect_allow 'echo pip install foo'
expect_allow "cat <<'EOF' >README.md
pip install foo
sudo apt install bar
npm install -g baz
terraform apply
EOF"
expect_allow 'PJP_ALLOW_INSTALL=1 sudo apt install foo'
expect_allow 'env PJP_ALLOW_INSTALL=1 pip install foo'
expect_allow "PJP_ALLOW_INSTALL=1 bash -c 'pip install foo'"

# hook の env の VIRTUAL_ENV (Claude Code を venv の中で起こした)
VIRTUAL_ENV="${repo}/box" run_input "$(pre_json 'pip install foo')"
if silent; then
  ok "hook の env に VIRTUAL_ENV があれば、素の pip install を通す"
else
  ng "hook の env に VIRTUAL_ENV があれば、素の pip install を通す" "$(detail)"
fi
VIRTUAL_ENV="${repo}/box" run_input "$(pre_json 'pip install --user foo')"
if denied; then
  ok "hook の env に VIRTUAL_ENV があっても、--user は止める"
else
  ng "hook の env に VIRTUAL_ENV があっても、--user は止める" "$(detail)"
fi

# PJP_ALLOW_IAC=1 では install を通さない
pre 'PJP_ALLOW_IAC=1 pip install foo'
if denied && [[ $(reason) == *'PJP_ALLOW_INSTALL=1'* ]]; then
  ok "PJP_ALLOW_IAC=1 では install を通さず、理由に PJP_ALLOW_INSTALL=1 を書く"
else
  ng "PJP_ALLOW_IAC=1 では install を通さない" "$(detail)"
fi

echo "-- IaC: 止める"
expect_deny 'terraform apply' 'terraform apply'
expect_deny 'terraform apply -auto-approve' 'terraform apply'
expect_deny 'terraform apply plan.tfplan' 'terraform apply'
expect_deny 'tofu destroy' 'tofu destroy'
expect_deny 'terraform -chdir=infra apply' 'terraform apply'
expect_deny 'terraform import aws_s3_bucket.b my-bucket' 'terraform import'
expect_deny 'terraform state rm a.b' 'terraform state rm'
expect_deny 'terraform state mv a.b a.c' 'terraform state mv'
expect_deny 'terraform state push errored.tfstate' 'terraform state push'
expect_deny 'terraform state replace-provider a b' 'terraform state replace-provider'
expect_deny 'terraform taint a.b' 'terraform taint'
expect_deny 'terraform untaint a.b' 'terraform untaint'
expect_deny 'terraform force-unlock 1234' 'terraform force-unlock'
expect_deny 'terraform refresh' 'terraform refresh'
expect_deny 'terraform workspace delete dev' 'terraform workspace delete'
expect_deny 'terraform init -migrate-state' 'terraform init -migrate-state'
expect_deny 'tofu init -force-copy' 'tofu init -force-copy'
expect_deny 'terragrunt apply' 'terragrunt apply'
expect_deny 'terragrunt run --all apply' 'terragrunt apply'
expect_deny 'terragrunt run --all --non-interactive -- apply' 'terragrunt apply'
expect_deny 'terragrunt run -- apply' 'terragrunt apply'
expect_deny 'terragrunt stack run apply' 'terragrunt apply'
expect_deny 'terragrunt run-all destroy' 'terragrunt destroy'
expect_deny 'terragrunt apply-all' 'terragrunt apply-all'
expect_deny 'terragrunt --log-level debug apply' 'terragrunt apply'
expect_deny 'terragrunt state rm a.b' 'terragrunt state rm'
expect_deny 'terragrunt backend delete' 'terragrunt backend delete'
expect_deny 'cd live && TF_LOG=debug terraform apply' 'terraform apply'
expect_deny 'timeout 600 terraform apply' 'terraform apply'
expect_deny 'time TF_LOG=debug terraform apply' 'terraform apply'
expect_deny "echo 'terraform apply -auto-approve' | bash" 'terraform apply'
expect_deny "bash -c 'cd infra && terraform destroy -auto-approve'" 'terraform destroy'

echo "-- IaC: 通す"
expect_allow 'terraform plan'
expect_allow 'terraform plan -destroy -out=apply.tfplan'
expect_allow 'terraform validate'
expect_allow 'terraform fmt -check -recursive'
expect_allow 'terraform init'
expect_allow 'terraform init -upgrade -backend=false'
expect_allow 'terraform output -json'
expect_allow 'terraform show'
expect_allow 'terraform state list'
expect_allow 'terraform state show a.b'
expect_allow 'terraform state pull'
expect_allow 'terraform graph'
expect_allow 'terraform providers'
expect_allow 'terraform test'
expect_allow 'terraform workspace select dev'
expect_allow 'terraform apply -help'
expect_allow 'terraform state rm -dry-run a.b'
expect_allow 'terraform init -migrate-state=false'
expect_allow 'terraform -chdir=infra plan'
expect_allow 'terragrunt run --all plan'
expect_allow 'terragrunt plan'
expect_allow 'terragrunt stack generate'
expect_allow 'terragrunt hcl fmt'
expect_allow 'make apply'
expect_allow 'mise run apply'
expect_allow './scripts/tf.sh apply'
expect_allow 'git apply x.patch'
expect_allow 'kubectl apply -f x.yaml'
expect_allow 'git commit -m "terraform apply"'
expect_allow 'PJP_ALLOW_IAC=1 terraform apply'
expect_allow 'env PJP_ALLOW_IAC=1 terragrunt run --all apply'

pre 'PJP_ALLOW_INSTALL=1 terraform apply'
if denied && [[ $(reason) == *'PJP_ALLOW_IAC=1'* ]]; then
  ok "PJP_ALLOW_INSTALL=1 では IaC を通さず、理由に PJP_ALLOW_IAC=1 を書く"
else
  ng "PJP_ALLOW_INSTALL=1 では IaC を通さない" "$(detail)"
fi

echo "-- IaC の guard を外したマシン (claude-iac-guard.json)"
mkdir -p "${state_dir}"
printf '{"enable":false}\n' >"${state_dir}/claude-iac-guard.json"
expect_allow 'terraform apply'
expect_allow 'terragrunt run --all destroy'
pre 'terraform apply && pip install foo'
if denied && [[ $(reason) == *'pip install'* && $(reason) != *'terraform apply'* ]]; then
  ok "enable が false でも install は止め、IaC は理由に書かない"
else
  ng "enable が false でも install は止める" "$(detail)"
fi
printf '{"enable":' >"${state_dir}/claude-iac-guard.json"
expect_deny 'terraform apply' 'terraform apply'
printf '{"enable":true}\n' >"${state_dir}/claude-iac-guard.json"
expect_deny 'terraform apply' 'terraform apply'
rm -f "${state_dir}/claude-iac-guard.json"
expect_deny 'terraform destroy' 'terraform destroy'

echo "-- そのほか"
# 止めた理由: 止めたものを並べ、代わりの手と通す口を書く (自分の判断では付けない)
pre 'pip install foo && terraform apply'
r=$(reason)
if denied && [[ ${r} == "[install-iac-guard] "* && ${r} == *'pip install'* && ${r} == *'terraform apply'* ]] \
  && [[ ${r} == *'PJP_ALLOW_INSTALL=1'* && ${r} == *'PJP_ALLOW_IAC=1'* && ${r} == *'自分の判断では付けない'* ]] \
  && [[ ${r} == *venv* && ${r} == *plan* && ${r} == *'--no-iac-guard'* ]]; then
  ok "理由に止めたものを並べ、代わりの手と通す口を書く"
else
  ng "理由に止めたものを並べ、代わりの手と通す口を書く" "$(detail)"
fi

# 読む長さを超えたコマンド。long_cmd <後ろの行>: 70 KB の heredoc の後ろに行を足した、読む長さを超えるコマンド
filler=$(printf '%070000d' 0)
long_cmd() {
  printf "cat <<'EOF' >notes.txt\n%s\nEOF\n%s" "${filler}" "$1"
}
# expect_long_deny <後ろの行> <理由に含む文字>・expect_long_allow <後ろの行>
expect_long_deny() {
  local r
  pre "$(long_cmd "$1")"
  r=$(reason)
  if denied && [[ ${r} == *'長すぎて'* && ${r} == *"$2"* ]]; then
    ok "長いコマンドでも止める: $(show "$1")"
  else
    ng "長いコマンドでも止める: $(show "$1") (理由に「$2」)" "$(detail)"
  fi
}
expect_long_allow() {
  pre "$(long_cmd "$1")"
  if silent; then
    ok "長いコマンドでも通す: $(show "$1")"
  else
    ng "長いコマンドでも通す: $(show "$1")" "$(detail)"
  fi
}
expect_long_deny 'terraform apply' 'terraform'
expect_long_deny 'cd infra && TF_LOG=debug terraform destroy -auto-approve' 'terraform'
expect_long_deny 'sudo -E pip install foo' 'pip install'
expect_long_deny 'FOO="a b" terraform apply' 'terraform'
expect_long_deny "bash -c 'terraform apply'" 'terraform'
expect_long_deny 'sudo apt-get -y install foo' 'apt-get install'
expect_long_deny 'npm install -g foo' 'npm'
expect_long_allow 'ls'
expect_long_allow 'terraform plan -out=apply.tfplan && npm install foo'
expect_long_allow 'npm ls -g && npm uninstall -g foo'
expect_long_allow 'terraform init -migrate-state=false'
expect_long_allow 'source .venv/bin/activate && pip install -r requirements.txt'
expect_long_allow 'PJP_ALLOW_IAC=1 terraform apply'

# 区切り (; | & ( )) の多い 80 KB の 1 行 (minified の JS を書くようなもの) を、20 秒のうちに読み終える
mini=$(for ((k = 0; k < 8000; k++)); do printf 'a;b|c&d(e)'; done)
start=${SECONDS}
run_input "$(pre_json "printf '%s' '${mini}' >min.js && terraform plan")"
took=$((SECONDS - start))
if silent && ((took < 20)); then
  ok "区切りの多い 80 KB の 1 行も ${took} 秒で読み終え、terraform plan は通す"
else
  ng "区切りの多い 80 KB の 1 行も 20 秒のうちに読み終える (${took} 秒)" "$(detail)"
fi

# Bash でない tool・壊れた入力・当たらない入力
run_input "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "pip install foo"}, cwd: "/tmp"}')"
if silent; then ok "Bash でない tool は黙る"; else ng "Bash でない tool は黙る" "$(detail)"; fi
run_input '{"tool_name": "Bash", "tool_input": {"command": "pip install'
if silent; then ok "壊れた入力は黙る"; else ng "壊れた入力は黙る" "$(detail)"; fi
expect_allow 'ls -la && git status'

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
