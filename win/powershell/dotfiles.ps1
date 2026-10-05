# dotfiles の win/powershell/dotfiles.ps1 から配る、PowerShell の共有設定。
# $PROFILE から dot-source で読む (読み込み方は win/README.md の「PowerShell」)。
#
# BOM 付きの UTF-8 で保存すること。Windows PowerShell 5.1 は BOM の無い UTF-8 を
# CP932 として読み、日本語コメントの次の行を黙って読み飛ばすことがある。

# herdr。WSL の fish の abbr (nix/home/modules/fish.nix) と同じ名前・同じ中身にそろえる。
#
# PowerShell の alias は引数を持てないので、h 以外は function にする。
# h は PowerShell 既定の alias (Get-History) と重なり、alias は function より先に
# 引かれるので Set-Alias で上書きする (履歴は ghy / history で引ける)。5.1 の既定の
# h には AllScope が付いていて、-Option AllScope を付けないと上書きできない。
Set-Alias -Name h -Value herdr -Option AllScope -Force
function hss { herdr --session @args }
function hls { herdr session list @args }
function ha { herdr session attach @args }
function hkill { herdr session stop @args }
function hdel { herdr session delete @args }
function hst { herdr status @args }
function hreload { herdr server reload-config @args }
function hsvstop { herdr server stop @args }
