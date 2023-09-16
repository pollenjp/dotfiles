HISTFILE=~/.zsh_history

setopt histignorealldups sharehistory

# for preexec, precmd
GLOBAL_CMD_STR=" "

###############
# Utils Funcs #
###############

function padding_right_left_alignment() {
    local left_str=${1:-""}
    local right_str=${2:-""}
    local pad="${3:-" "}"
    local -i rightwidth=$(($COLUMNS-${#left_str}))
    echo ${left_str}${(pl:$rightwidth::$pad:)right_str}
}


function padding_center_alignment() {
    local text="${1:-hellworld}"
    local pad="${2:-=}"
    local -i columns=${COLUMNS:-$(tput cols)}
    columns=$(( columns/2 ))
    echo ${(pl:${columns}::${pad}:::r:${columns}::${pad}:::)text}
}

function update_GLOBAL_CMD_STR() {
    local cmd_str=${1:-""}
    if [ ${#cmd_str} -gt 40 ]; then;
        GLOBAL_CMD_STR=$(echo ${cmd_str[1,37]}"..." )
    else
        GLOBAL_CMD_STR=${cmd_str[1,40]}
    fi
}

function get_formatted_cwd() {
    local cwd_str=$(pwd)
    if [ ${#cwd_str} -gt 40 ]; then
        cwd_str=$(echo "..."${cwd_str[-37,-1]} )
    fi
    printf "%s" "${cwd_str}"
}

function format_string_for_terminal_mux() {
    local hostname_str=${1}
    local cmd_str=${2}
    local cwd_str=${3}
    printf '%s [%-30s] %s' \
        "${hostname_str}" \
        "${cmd_str}" \
        "${cwd_str}"
}

function update_screen_page_title() {
    if [[ -n "$STY" ]]; then
        printf \
            "$(format_string_for_terminal_mux \
                    "$(hostname)" \
                    "${GLOBAL_CMD_STR}" \
                    "$(get_formatted_cwd)" \
            )"
    fi
}

function update_tmux_page_title() {
    if [[ -n "$TMUX" ]]; then
        local cwd_str=$(get_formatted_cwd)
        tmux rename-window \
            "$(format_string_for_terminal_mux \
                    "$(hostname)" \
                    "${GLOBAL_CMD_STR}" \
                    "$(get_formatted_cwd)" \
            )"
    fi
}


###########
# preexec #
###########

# 第一引数: 直前で実行されたコマンド全体が入る
preexec () {
    local cmd_str="$1"
    update_GLOBAL_CMD_STR "${cmd_str}"
    update_tmux_page_title
    update_screen_page_title
}

##########
# precmd #
##########

function print_rgb() {
    local sentense=$1
    if [ -z "${sentense}" ]; then
        print "Failed to print_rgb: 'sentense' argument is null.\n"
        return
    fi
    local -i br=${2:-  0}
    local -i bg=${3:-  0}
    local -i bb=${4:-238}
    local -i fr=${5:-255}
    local -i fg=${6:-255}
    local -i fb=${7:-255}
    printf "\033[48;2;%d;%d;%dm" \
        "${br}" \
        "${bg}" \
        "${bb}"
    printf "\033[38;2;%d;%d;%dm" \
        "${fr}" \
        "${fg}" \
        "${fb}"

    printf "${sentense}"
    # NOTE: bellow doesn't show emoji
    # printf "%s" "${sentense}"

    printf "\e[0m"
}

PRECMD_SEGMENT_SEPARATOR="\ue0b0"
EMOJI_CLOCK="\U23F2"
EMOJI_DIRECTORY="\uf4d4"
EMOJI_SNAKE="\U1F40D"
EMOJI_GIT="\ue725"
EMOJI_RUBY="\U1F496"
EMOJI_TERMINAL="\uf489"


typeset PRECMD_CURRENT_BG_R=''
typeset PRECMD_CURRENT_BG_G=''
typeset PRECMD_CURRENT_BG_B=''


function precmd_segment() {
    if [[ -n "$PRECMD_CURRENT_BG_R" ]]; then
        # separater の右側の領域の背景色を指定
        local -i br=$1
        local -i bg=$2
        local -i bb=$3
        if [ -z "${br}" ] \
        || [ -z "${bg}" ] \
        || [ -z "${bb}" ]; then
            echo "Parsing arguments error."
            return
        fi

        print_rgb \
            "${PRECMD_SEGMENT_SEPARATOR}" \
            "${br}" \
            "${bg}" \
            "${bb}" \
            "${PRECMD_CURRENT_BG_R}" \
            "${PRECMD_CURRENT_BG_G}" \
            "${PRECMD_CURRENT_BG_B}"
    fi
}

function precmd_segment_end() {
    printf "\033[38;2;%d;%d;%dm" \
        "${PRECMD_CURRENT_BG_R}" \
        "${PRECMD_CURRENT_BG_G}" \
        "${PRECMD_CURRENT_BG_B}"
    printf "${PRECMD_SEGMENT_SEPARATOR}"
    printf "\e[0m"
    printf "\n"
    PRECMD_CURRENT_BG_R=''
    PRECMD_CURRENT_BG_G=''
    PRECMD_CURRENT_BG_B=''
}

typeset -a SEGMENT_COLORS=(
    # br bg bb fr fg fb
    "0 55 218 255 255 255"
    "100 100 230 255 255 255"
    "0 0 0 255 255 255"
)

# return "br bg bb fr fg fb"
function get_color_by_idx() {
    # 1 origin index
    local -i idx=$1
    if [[ ${idx} -gt ${#SEGMENT_COLORS[@]} ]]; then
        # 配列サイズを超えた場合は最後の要素を指す
        idx=${#SEGMENT_COLORS[@]}
    fi
    echo ${SEGMENT_COLORS[${idx}]}
}

function precmd_section() {
    local index=$1
    local sentense=$2
    if [ -z "${index}" ] \
    || [ -z "${sentense}" ]; then \
        echo "Parsing arguments error."
        return
    fi


    local bg_fg_color=$(get_color_by_idx $index)
    typeset -a col=(${(@s: :)bg_fg_color})
    if [[ -n "$PRECMD_CURRENT_BG_R" ]]; then
        precmd_segment \
            "${col[1]}" \
            "${col[2]}" \
            "${col[3]}"
    fi
    print_rgb \
        "${sentense}" \
        "${col[1]}" \
        "${col[2]}" \
        "${col[3]}" \
        "${col[4]}" \
        "${col[5]}" \
        "${col[6]}"
    PRECMD_CURRENT_BG_R="${col[1]}"
    PRECMD_CURRENT_BG_G="${col[2]}"
    PRECMD_CURRENT_BG_B="${col[3]}"
}

function precmd_datetime () {
    local var_datetime=$(LC_TIME=en_US.UTF-8 date)
    precmd_section 1 " ${EMOJI_CLOCK} Time"
    precmd_section 2 "${var_datetime}"
    precmd_segment_end
}


function precmd_pip() {
    if ! command -v pip 2>&1 > /dev/null; then
        return
    fi
    local pip_v
    if ! pip_path=${(@)$(pip -V 2> /dev/null)[4]}; then
        return
    fi
    precmd_section 1 " ${EMOJI_SNAKE} pip"
    precmd_section 2 "$pip_path"
    precmd_segment_end
}

function precmd_pyenv() {
    if [[ -n $PYENV_SHELL ]]; then
        local old_ifs=$IFS
        local pyenv_version
        if ! IFS=$'\n' pyenv_version=("$(pyenv version 2> /dev/null )"); then
            IFS=$old_ifs
            return
        fi
        IFS=$old_ifs
        for pv in $pyenv_version; do
            pv=$(printf $pv | cut -d ' ' -f 1)
            precmd_section 1 " ${EMOJI_SNAKE} pyenv"
            precmd_section 2 "${pv}"
            precmd_segment_end
        done
    fi
}


function precmd_rbenv () {
    # <https://stackoverflow.com/a/7522866>
    if command -v rbenv 2>&1 > /dev/null; then
        precmd_section 1 " ${EMOJI_RUBY} rbenv"
        precmd_section 2 ${(@)$(rbenv version)[1]}
        precmd_segment_end
    fi
}

function precmd_git() {
    local git_branch_name
    git_branch_name=`git rev-parse --abbrev-ref HEAD 2>/dev/null`
    if [[ -n ${git_branch_name} ]]; then
        precmd_section 1 " ${EMOJI_GIT} git"
        precmd_section 2 "${git_branch_name}"
        precmd_segment_end
    fi
}

# prent tmux session name
function precmd_tmux() {
    if [[ -n "$TMUX" ]]; then
        precmd_section 1 " ${EMOJI_TERMINAL} tmux"
        precmd_section 2 "$(tmux display-message -p '#S')"
        precmd_segment_end
    fi
}

function precmd_pwd() {
    precmd_section 1 " ${EMOJI_DIRECTORY} dir"
    precmd_section 2 "$(pwd)"
    precmd_segment_end
}

precmd () {
    # https://superuser.com/questions/974908/multiline-rprompt-in-zsh

    precmd_datetime
    precmd_pip
    # precmd_pyenv
    # precmd_rbenv
    precmd_git
    precmd_pwd
    precmd_tmux

    ###############################
    # Update Screen Terminal Name #
    ###############################

    # reset command string
    GLOBAL_CMD_STR=" "
    update_tmux_page_title
    update_screen_page_title
}
