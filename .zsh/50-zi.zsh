source <(curl -sL https://git.io/zi-loader)
zzinit
zi load z-shell/H-S-MW
zi light zsh-users/zsh-syntax-highlighting
zi light zsh-users/zsh-autosuggestions
zi light z-shell/F-Sy-H
zi light zsh-users/zsh-completions

###############
# ohmyzsh lib #
###############

# <https://z.digitalclouds.dev/docs/getting_started/migration>
zi snippet OMZ::lib/clipboard.zsh
zi snippet OMZ::lib/termsupport.zsh

#################
# ohmyzsh theme #
#################

zi snippet OMZL::git.zsh
zi snippet OMZP::git

# zi snippet OMZL::theme-and-appearance.zsh
# zi snippet OMZL::prompt_info_functions.zsh

# Other libraries that might be needed
zi cdclear -q

setopt promptsubst

# theme
# zi snippet OMZT::agnoster

# zi snippet OMZP::gpg-agent
