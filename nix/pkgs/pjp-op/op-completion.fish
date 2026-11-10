# WSL の op (dotfiles の pjp-op。理由 (--reason) が必須の 1Password CLI の wrapper) の、fish の補完。
#
# home/modules/op-reason.nix が、wrapper を入れるマシンにだけ ~/.config/fish/completions/op.fish として置く
# (programs.fish.completions)。fish は fish_complete_path の頭から op.fish を探して見つけた 1 つだけを読み、どの置き場にも
# 無いときに限って fish に同梱の (binary に埋め込んだ) completions/op.fish を読む。同梱のものは op completion fish | source の
# 1 行で、補完を初めて使うとき (Tab・自動補完の候補) に op completion fish を打つ。wrapper は理由が無いので断り、使い方と
# 断りの文を stderr に出して、fish はそれを端末にそのまま出していた (pjp-op-log にも refused が残る)。本物の op の補完は候補の
# たびに op __complete を打つが、wrapper を通すと補完のたびに powershell と op.exe が起き、承認の画面も出うる。
#
# ここでは op を呼ばずに、--reason と op のコマンド (2 段目まで)・global の flag・よく使うコマンドの flag を出す。item や vault
# の名前のように、op に聞かないと分からない値は出さない。-- の後ろ (op run の子のコマンド) は、そのコマンドの補完に任せる。
#
# 一覧は op 2.41.0 の op __complete から写した。op を上げてコマンドや flag が変わったら写し直す。手元の op は wrapper なので、
# Linux の op (unfree) を借り、HOME を一時の場所にして打つ (手元の op の設定に触れない)。dotfiles の直下で、bash で:
#
#   bin=$(NIXPKGS_ALLOW_UNFREE=1 nix build --impure --no-link --print-out-paths --inputs-from ./nix nixpkgs#_1password-cli)/bin
#   HOME=$(mktemp -d) "$bin/op" __complete ""            # トップのコマンド
#   HOME=$(mktemp -d) "$bin/op" __complete item ""       # 2 段目
#   HOME=$(mktemp -d) "$bin/op" __complete item get -    # flag (- なら短い形も出る。-- では長い形だけ)

# --- 今の行を読む

# __pjp_op_words: 今の行の op より後ろ (カーソルのある語の前まで) の語から、flag とその値を除いたもの (コマンドの並び) を
# 1 行に 1 つ出す。-- があれば -- を出して終える (後ろは op run などの子のコマンド)。値を空白で区切って取る flag は値を読み
# 飛ばす (--reason "<理由>" の理由をコマンドと読まない)。下で -r・-x を付けた flag (短い形も) と揃える。fish の echo は -- を
# option の終わりと読んで空行を出すので、printf で出す
function __pjp_op_words
    set -l skip 0
    for w in (commandline -xpc)[2..]
        if test $skip = 1
            set skip 0
            continue
        end
        switch $w
            case --
                printf '%s\n' --
                return
            case --reason --account --config --encoding --format --session --vault --fields --categories --tags \
                --category --title --url --template --out-file --in-file --file-mode --env-file --environment --file-name \
                -o -i
                set skip 1
            case '-*'
            case '*'
                printf '%s\n' $w
        end
    end
end

# __pjp_op_at <語>…: コマンドの並びがちょうど <語>… のとき (語を渡さなければ、コマンドがまだ無いとき)
function __pjp_op_at
    test "$(__pjp_op_words | string join ' ')" = "$argv"
end

# __pjp_op_in <語>…: コマンドの並びが <語>… で始まり、-- がまだ無いとき
function __pjp_op_in
    set -l words (__pjp_op_words)
    set -l n (count $argv)
    not contains -- -- $words
    and test (count $words) -ge $n
    and test "$words[1..$n]" = "$argv"
end

# __pjp_op_opts: op の flag を出してよいとき (-- がまだ無い)
function __pjp_op_opts
    not contains -- -- (commandline -xpc)
end

# __pjp_op_no_reason: --reason をまだ書いていないとき (wrapper は -- より前の最初の 1 つだけを読み、2 つ目は op に渡る)。
# --reason の値を書いているところ (前の語が --reason) も通す。fish は、この条件が通る -l reason の行があるときだけ今の語を
# --reason の値と読み、コマンドの候補を出さない
function __pjp_op_no_reason
    set -l tokens (commandline -xpc)[2..]
    test "$tokens[-1]" = --reason; and return 0
    for w in $tokens
        switch $w
            case --
                break
            case --reason '--reason=*'
                return 1
        end
    end
    return 0
end

# __pjp_op_child: -- の後ろ (op run・op plugin run の子のコマンド) を、そのコマンドの補完に任せる
function __pjp_op_child
    set -l tokens (commandline -xpc)
    set -l i (contains -i -- -- $tokens)
    complete -C (string join ' ' -- (string escape -- $tokens[(math $i + 1)..]) (commandline -ct))
end

# op の引数はほとんどがファイルでないので、ファイルは flag ごとに -F で足す
complete -c op -f

# --- wrapper (pjp-op) の flag。op <Tab> でも出し、要ることが分かるようにする

complete -c op -n '__pjp_op_opts; and __pjp_op_no_reason' -l reason -x -d '呼ぶ理由 (pjp-op。必須。何のために何を読む・書くか)'
complete -c op -n '__pjp_op_at; and __pjp_op_no_reason' -a --reason -d '呼ぶ理由 (pjp-op。必須。何のために何を読む・書くか)'

# --- global の flag

complete -c op -n __pjp_op_opts -l account -x -d 'Select the account to execute the command'
complete -c op -n __pjp_op_opts -l cache -d 'Store and use cached information'
complete -c op -n __pjp_op_opts -l config -x -a '(__fish_complete_directories)' -d 'Use this configuration directory'
complete -c op -n __pjp_op_opts -l debug -d 'Enable debug mode'
complete -c op -n __pjp_op_opts -l encoding -x -a 'SHIFT_JIS gbk' -d 'Use this character encoding type'
complete -c op -n __pjp_op_opts -l format -x -a 'human-readable json' -d 'Use this output format'
complete -c op -n __pjp_op_opts -s h -l help -d 'Get help for op'
complete -c op -n __pjp_op_opts -l iso-timestamps -d 'Format timestamps according to ISO 8601 / RFC 3339'
complete -c op -n __pjp_op_opts -l no-color -d 'Print output without color'
complete -c op -n __pjp_op_opts -l session -x -d 'Authenticate with this session token'
complete -c op -n __pjp_op_at -s v -l version -d 'version for op'

# --- コマンド

function __pjp_op_commands
    printf '%s\t%s\n' \
        account 'Manage your locally configured 1Password accounts' \
        completion 'Generate shell completion information' \
        connect 'Manage Connect server instances and tokens in your 1Password account' \
        document 'Perform CRUD operations on Document items in your vaults' \
        events-api 'Manage Events API integrations in your 1Password account' \
        group 'Manage the groups in your 1Password account' \
        help 'Get help for a command' \
        inject 'Inject secrets into a config file' \
        item 'Perform CRUD operations on the 1Password items in your vaults' \
        plugin 'Manage the shell plugins you use to authenticate third-party CLIs' \
        provisioning 'Manage provisioning integration settings' \
        read 'Read a secret reference' \
        run 'Pass secrets as environment variables to a process' \
        service-account 'Manage service accounts' \
        signin 'Sign in to a 1Password account' \
        signout 'Sign out of a 1Password account' \
        update 'Check for and download updates' \
        user 'Manage users within this 1Password account' \
        vault 'Manage permissions and perform CRUD operations on your 1Password vaults' \
        whoami 'Get information about a signed-in account'
end

# __pjp_op_subcommands <コマンド>: そのコマンドの 2 段目
function __pjp_op_subcommands
    switch $argv[1]
        case account
            printf '%s\t%s\n' \
                add 'Add an account to sign in to for the first time' \
                forget 'Remove a 1Password account from this device' \
                get 'Get details about your account' \
                list 'List users and accounts set up on this device'
        case connect
            printf '%s\t%s\n' \
                group 'Manage group access to Secrets Automation' \
                server 'Manage Connect servers' \
                token 'Manage Connect server tokens' \
                vault 'Manage Connect server vault access'
        case document
            printf '%s\t%s\n' \
                create 'Create a document item' \
                delete 'Delete or archive a document item' \
                edit 'Edit a document item' \
                get 'Download a document' \
                list 'Get a list of documents'
        case events-api
            printf '%s\t%s\n' \
                create 'Set up an integration with the Events API'
        case group
            printf '%s\t%s\n' \
                create 'Create a group' \
                delete 'Remove a group' \
                edit "Edit a group's name or description" \
                get 'Get details about a group' \
                list 'List groups' \
                user 'Manage group membership'
        case item
            printf '%s\t%s\n' \
                create 'Create an item' \
                delete 'Delete or archive an item' \
                edit "Edit an item's details" \
                get "Get an item's details" \
                list 'List items' \
                move 'Move an item between vaults' \
                share 'Share an item' \
                template 'Manage templates'
        case plugin
            printf '%s\t%s\n' \
                clear 'Clear shell plugin configuration' \
                credential 'Manage credentials for shell plugins' \
                init 'Configure a shell plugin' \
                inspect 'Inspect your existing shell plugin configurations' \
                list 'List all available shell plugins' \
                run 'Provision credentials from 1Password and run this command'
        case provisioning
            printf '%s\t%s\n' \
                google 'Manage Google Workspace provisioning for your 1Password account'
        case service-account
            printf '%s\t%s\n' \
                create 'Create a service account' \
                ratelimit 'Retrieve rate limit usage for a service account'
        case user
            printf '%s\t%s\n' \
                confirm 'Confirm a user' \
                delete 'Remove a user and all their data from the account' \
                edit "Edit a user's name or Travel Mode status" \
                get 'Get details about a user' \
                list 'List users' \
                provision 'Provision a user in the authenticated account' \
                reactivate 'Reactivate a suspended user' \
                recovery 'Manage user recovery in your 1Password account' \
                suspend 'Suspend a user'
        case vault
            printf '%s\t%s\n' \
                create 'Create a new vault' \
                delete 'Remove a vault' \
                edit "Edit a vault's name, description, icon, or Travel Mode status" \
                get 'Get details about a vault' \
                group 'Manage group vault access' \
                list 'List all vaults in the account' \
                user 'Manage user vault access'
    end
end

complete -c op -n __pjp_op_at -a '(__pjp_op_commands)'
complete -c op -n '__pjp_op_at help' -a '(__pjp_op_commands)'
for c in account connect document events-api group item plugin provisioning service-account user vault
    complete -c op -n "__pjp_op_at $c" -a "(__pjp_op_subcommands $c)"
end

# --- よく使うコマンドの flag

complete -c op -n '__pjp_op_in read' -s o -l out-file -r -F -d 'Write the secret to a file instead of stdout'
complete -c op -n '__pjp_op_in read' -l file-mode -x -d 'Set filemode for the output file'
complete -c op -n '__pjp_op_in read' -s f -l force -d 'Do not prompt for confirmation'
complete -c op -n '__pjp_op_in read' -s n -l no-newline -d 'Do not print a new line after the secret'

complete -c op -n '__pjp_op_in inject' -s i -l in-file -r -F -d 'The filename of a template file to inject'
complete -c op -n '__pjp_op_in inject' -s o -l out-file -r -F -d 'Write the injected template to a file instead of stdout'
complete -c op -n '__pjp_op_in inject' -l file-mode -x -d 'Set filemode for the output file'
complete -c op -n '__pjp_op_in inject' -s f -l force -d 'Do not prompt for confirmation'

complete -c op -n '__pjp_op_in run' -l env-file -r -F -d 'Enable Dotenv integration with specific Dotenv files to parse'
complete -c op -n '__pjp_op_in run' -l environment -x -d 'Load environment variables from 1Password Environments by ID'
complete -c op -n '__pjp_op_in run' -l no-masking -d 'Disable masking of secrets on stdout and stderr'

complete -c op -n '__pjp_op_in signin' -s f -l force -d 'Ignore warnings and print raw output from this command'
complete -c op -n '__pjp_op_in signin' -l raw -d 'Only return the session token'
complete -c op -n '__pjp_op_in signout' -l all -d 'Sign out of all signed-in accounts'
complete -c op -n '__pjp_op_in signout' -l forget -d 'Remove the details for a 1Password account from this device'

complete -c op -n '__pjp_op_in item get' -l vault -x -d 'Look for the item in this vault'
complete -c op -n '__pjp_op_in item get' -l fields -x -d 'Return data from specific fields'
complete -c op -n '__pjp_op_in item get' -l include-archive -d 'Include items in the Archive'
complete -c op -n '__pjp_op_in item get' -l otp -d 'Output the primary one-time password for this item'
complete -c op -n '__pjp_op_in item get' -l reveal -d "Don't conceal sensitive fields"
complete -c op -n '__pjp_op_in item get' -l share-link -d 'Get a shareable link for the item'

complete -c op -n '__pjp_op_in item list' -l vault -x -d 'Only list items in this vault'
complete -c op -n '__pjp_op_in item list' -l categories -x -d 'Only list items in these categories (comma-separated)'
complete -c op -n '__pjp_op_in item list' -l tags -x -d 'Only list items with these tags (comma-separated)'
complete -c op -n '__pjp_op_in item list' -l favorite -d 'Only list favorite items'
complete -c op -n '__pjp_op_in item list' -l include-archive -d 'Include items in the Archive'
complete -c op -n '__pjp_op_in item list' -l long -d 'Output a more detailed item list'

complete -c op -n '__pjp_op_in item create' -l vault -x -d 'Save the item in this vault'
complete -c op -n '__pjp_op_in item create' -l category -x -d "Set the item's category"
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l title -x -d "Set the item's title"
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l url -x -d 'Set the URL associated with the item'
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l tags -x -d 'Set the tags to the specified (comma-separated) values'
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l template -r -F -d 'Specify the file path to read an item template from'
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l generate-password -d 'Add a randomly-generated password'
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l dry-run -d 'Output a preview of the resulting item'
complete -c op -n '__pjp_op_in item create; or __pjp_op_in item edit' -l reveal -d "Don't conceal sensitive fields"
complete -c op -n '__pjp_op_in item create' -l favorite -d 'Add item to favorites'
complete -c op -n '__pjp_op_in item edit' -l favorite -d 'Whether this item is a favorite item (true, false)'
complete -c op -n '__pjp_op_in item edit' -l vault -x -d 'Edit the item in this vault'

complete -c op -n '__pjp_op_in item delete' -l vault -x -d 'Look for the item in this vault'
complete -c op -n '__pjp_op_in item delete' -l archive -d 'Move the item to the Archive'

complete -c op -n '__pjp_op_in document get' -l vault -x -d 'Look for the document in this vault'
complete -c op -n '__pjp_op_in document get' -s o -l out-file -r -F -d 'Save the document to the file instead of stdout'
complete -c op -n '__pjp_op_in document get' -l file-mode -x -d 'Set filemode for the output file'
complete -c op -n '__pjp_op_in document get' -l force -d 'Save or print the document without prompting'
complete -c op -n '__pjp_op_in document get; or __pjp_op_in document list' -l include-archive -d 'Include document items in the Archive'
complete -c op -n '__pjp_op_in document list' -l vault -x -d 'Only list documents in this vault'

# op document create <ファイル> と op document edit <item> <ファイル> はファイルを取る
complete -c op -n '__pjp_op_in document create; or __pjp_op_in document edit' -F
complete -c op -n '__pjp_op_in document create' -l vault -x -d 'Save the document in this vault'
complete -c op -n '__pjp_op_in document edit' -l vault -x -d 'Look up document in this vault'
complete -c op -n '__pjp_op_in document create; or __pjp_op_in document edit' -l title -x -d "Set the document item's title"
complete -c op -n '__pjp_op_in document create; or __pjp_op_in document edit' -l file-name -x -d "Set the file's name"
complete -c op -n '__pjp_op_in document create; or __pjp_op_in document edit' -l tags -x -d 'Set the tags to the specified (comma-separated) values'

# --- -- の後ろ (op run・op plugin run の子のコマンド)

complete -c op -n 'not __pjp_op_opts' -a '(__pjp_op_child)'
