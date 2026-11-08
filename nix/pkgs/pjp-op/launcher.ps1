# pjp-op launcher. The WSL `op` wrapper (nix/pkgs/pjp-op/op.sh) starts a fresh Windows PowerShell 5.1 for each call.
# A short bootstrap passed with -EncodedCommand reads this script from $env:PJP_OP_SCRIPT (base64 of UTF-8) and runs it in
# the same scope (pkgs/pjp-op/default.nix): this script itself as -EncodedCommand would exceed the 32767-character
# command line of Windows. The 1Password CLI approval of the desktop app is bound to the process
# that starts op.exe, so binding it to this short-lived process keeps one approval from reaching later calls or other
# panes (the approval would otherwise be bound to the wsl.exe that every pane shares).
#
# ASCII only: the build fails on any other character. Every Japanese text (the window, the toast) comes from the
# payload, which op.sh builds.
#
# Input: $env:PJP_OP_PAYLOAD (JSON), removed from the environment before op.exe starts.
#   mode     desktop | help | service | notify
#   op       Windows path of op.exe
#   args64   op's arguments, each one UTF-8 then base64 (PowerShell 7's ConvertFrom-Json turns date-like strings into
#            DateTime, so plain strings would not round-trip in the tests on pwsh)
#   status   path of the status JSON written at the end (optional)
#   ui       desktop and notify only: title, lines ([label, value]...), footer, others, toast (texts)
#
# Modes:
#   desktop  show the window and the toast, run op.exe, then close this process's CLI sessions (whoami, then
#            signout --all only when signed in: whoami does not prompt without a session)
#   help     calls that need no reason (--version, --help): run op.exe without the window, then close the session if any
#   service  service account or Connect token (the desktop app is not involved): run op.exe only
#   notify   show the toast only
#
# op.exe inherits stdin, stdout and stderr of this process as they are (ProcessStartInfo without redirection, so no
# PowerShell pipeline touches the bytes). CreateNoWindow must stay false: with true the child gets no stdin.
# This script writes nothing to stdout or stderr except one "pjp-op: ..." line when it cannot start op.exe.
# The bootstrap sets $ProgressPreference before anything else (the first line below repeats it for the tests), or
# PowerShell writes CLIXML progress records to stderr.
#
# Exit code: op's exit code. 127 when op.exe is missing, 1 for other failures before op.exe starts. notify exits 0.
# Write it for Windows PowerShell 5.1 (no ??, ?., ternary, pipeline chains, $IsWindows). The tests run it on pwsh 7.
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

$script:status = [ordered]@{
  started = $false
  exit    = $null
  error   = ''
  window  = 'skipped'
  toast   = 'skipped'
  others  = 0
  signout = 'skipped'
}
$script:statusPath = $null
$script:onWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)

# Quote one argument the way Go's syscall.EscapeArg does, so op.exe (a Go program) and .NET split it back unchanged.
function Format-WinArg([string]$s) {
  if ($s.Length -eq 0) { return '""' }
  if ($s.IndexOfAny([char[]]@([char]34, [char]92, [char]32, [char]9)) -lt 0) { return $s }
  $hasSpace = $s.IndexOfAny([char[]]@([char]32, [char]9)) -ge 0
  if ($s.IndexOfAny([char[]]@([char]34, [char]92)) -lt 0) { return '"' + $s + '"' }
  $sb = New-Object System.Text.StringBuilder
  if ($hasSpace) { [void]$sb.Append('"') }
  $slashes = 0
  foreach ($c in $s.ToCharArray()) {
    if ($c -eq [char]92) { $slashes++ }
    elseif ($c -eq [char]34) { [void]$sb.Append([char]92, $slashes + 1); $slashes = 0 }
    else { $slashes = 0 }
    [void]$sb.Append($c)
  }
  if ($hasSpace) { [void]$sb.Append([char]92, $slashes); [void]$sb.Append('"') }
  return $sb.ToString()
}

function Get-Short([string]$s, [int]$n) {
  $t = ($s -replace '\s+', ' ').Trim()
  if ($t.Length -gt $n) { $t = $t.Substring(0, $n) + '...' }
  return $t
}

function Write-Status {
  if (-not $script:statusPath) { return }
  try {
    $json = $script:status | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:statusPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# Run op.exe with redirected I/O (whoami, signout): nothing reaches the caller's stdout or stderr.
function Invoke-Quiet([string]$exe, [string]$argLine) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.StandardInput.Close()
  $out = $proc.StandardOutput.ReadToEndAsync()
  $err = $proc.StandardError.ReadToEndAsync()
  $proc.WaitForExit()
  [void]$out.Result
  return @{ code = $proc.ExitCode; err = $err.Result }
}

# Close the CLI sessions of this process: whoami first (it does not prompt without a session), then signout --all only
# when signed in (plain signout closes only the most recently used account).
function Close-Session([string]$op) {
  try {
    $who = Invoke-Quiet $op 'whoami'
    if ($who.code -ne 0) {
      $script:status.signout = 'not-signed-in'
      return
    }
    $out = Invoke-Quiet $op 'signout --all'
    if ($out.code -eq 0) { $script:status.signout = 'ok' }
    else { $script:status.signout = 'failed: exit ' + $out.code + ': ' + (Get-Short $out.err 120) }
  } catch {
    $script:status.signout = 'failed: ' + (Get-Short $_.Exception.Message 120)
  }
}

function Start-Op([string]$op, $argList) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $op
  $psi.Arguments = @($argList | ForEach-Object { Format-WinArg ([string]$_) }) -join ' '
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $false
  $proc = [System.Diagnostics.Process]::Start($psi)
  $script:status.started = $true
  return $proc
}

function Get-OtherCount([string]$name, [int]$selfId) {
  try {
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $selfId }).Count
  } catch {
    return 0
  }
}

function Show-Toast($texts) {
  if (-not $script:onWindows) { return 'skipped' }
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<toast><visual><binding template="ToastGeneric">')
    foreach ($t in @($texts)) {
      [void]$sb.Append('<text>' + [System.Security.SecurityElement]::Escape([string]$t) + '</text>')
    }
    [void]$sb.Append('</binding></visual></toast>')
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($sb.ToString())
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    # The AppUserModelID that Windows PowerShell registers for itself (no registration of our own).
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    return 'shown'
  } catch {
    return 'failed: ' + (Get-Short $_.Exception.Message 120)
  }
}

function New-TextLine([string]$text, [double]$size, [bool]$bold, $brush) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tb.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
  if ($size -gt 0) { $tb.FontSize = $size }
  if ($bold) { $tb.FontWeight = [System.Windows.FontWeights]::Bold }
  if ($null -ne $brush) { $tb.Foreground = $brush }
  return $tb
}

# The window: on top of other windows without taking the focus (ShowActivated), at the top right of the work area so
# that it does not cover the 1Password prompt in the middle of the screen. It asks nothing; the decision is made in
# the 1Password prompt only.
function New-ApprovalWindow($ui) {
  Add-Type -AssemblyName PresentationFramework
  $win = New-Object System.Windows.Window
  $win.Title = [string]$ui.title
  $win.Width = 520
  $win.SizeToContent = [System.Windows.SizeToContent]::Height
  $win.WindowStyle = [System.Windows.WindowStyle]::ToolWindow
  $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $win.Topmost = $true
  $win.ShowActivated = $false
  $win.ShowInTaskbar = $false
  $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $area = [System.Windows.SystemParameters]::WorkArea
  $win.Left = $area.Right - $win.Width - 16
  $win.Top = $area.Top + 16
  $win.Background = [System.Windows.Media.Brushes]::LightYellow

  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.Margin = New-Object System.Windows.Thickness(14, 10, 14, 12)
  [void]$panel.Children.Add((New-TextLine ([string]$ui.title) 16 $true $null))
  foreach ($line in @($ui.lines)) {
    $tb = New-TextLine '' 0 $false $null
    $label = New-Object System.Windows.Documents.Run ([string]$line[0] + ': ')
    $label.FontWeight = [System.Windows.FontWeights]::Bold
    [void]$tb.Inlines.Add($label)
    [void]$tb.Inlines.Add((New-Object System.Windows.Documents.Run ([string]$line[1])))
    [void]$panel.Children.Add($tb)
  }
  $others = New-TextLine ([string]$ui.others) 0 $true ([System.Windows.Media.Brushes]::DarkOrange)
  $others.Visibility = [System.Windows.Visibility]::Collapsed
  [void]$panel.Children.Add($others)
  [void]$panel.Children.Add((New-TextLine ([string]$ui.footer) 0 $true ([System.Windows.Media.Brushes]::Firebrick)))
  $win.Content = $panel
  return @{ window = $win; others = $others }
}

# Keep the window responsive until op.exe exits. Every 250 ms: count op.exe processes other than ours (a prompt
# without this window may be one of them) and leave the frame when ours has exited.
function Wait-WithWindow($proc, $view, [string]$procName) {
  $script:waitProc = $proc
  $script:waitView = $view
  $script:waitName = $procName
  $script:waitFrame = New-Object System.Windows.Threading.DispatcherFrame
  $script:waitTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:waitTimer.Interval = [TimeSpan]::FromMilliseconds(250)
  $script:waitTimer.Add_Tick({
      $n = Get-OtherCount $script:waitName $script:waitProc.Id
      if ($n -gt $script:status.others) { $script:status.others = $n }
      if ($n -gt 0) { $script:waitView.others.Visibility = [System.Windows.Visibility]::Visible }
      if ($script:waitProc.HasExited) {
        $script:waitTimer.Stop()
        $script:waitFrame.Continue = $false
      }
    })
  $script:waitTimer.Start()
  [System.Windows.Threading.Dispatcher]::PushFrame($script:waitFrame)
}

function Invoke-Desktop([string]$op, $argList, $ui) {
  $view = $null
  if ($script:onWindows -and $null -ne $ui) {
    try {
      $view = New-ApprovalWindow $ui
      $procName = [System.IO.Path]::GetFileNameWithoutExtension($op)
      $n = Get-OtherCount $procName -1
      if ($n -gt 0) {
        $script:status.others = $n
        $view.others.Visibility = [System.Windows.Visibility]::Visible
      }
      $view.window.Show()
      $script:status.window = 'shown'
    } catch {
      $script:status.window = 'failed: ' + (Get-Short $_.Exception.Message 120)
      $view = $null
    }
    $script:status.toast = Show-Toast $ui.toast
  }
  $proc = Start-Op $op $argList
  if ($null -ne $view) {
    try {
      Wait-WithWindow $proc $view ([System.IO.Path]::GetFileNameWithoutExtension($op))
    } catch {
      $script:status.window = 'failed: ' + (Get-Short $_.Exception.Message 120)
    }
  }
  $proc.WaitForExit()
  if ($null -ne $view) {
    try { $view.window.Close() } catch { }
  }
  return $proc.ExitCode
}

$exitCode = 1
try {
  $raw = $env:PJP_OP_PAYLOAD
  Remove-Item Env:PJP_OP_PAYLOAD -ErrorAction SilentlyContinue
  if (-not $raw) { throw 'PJP_OP_PAYLOAD is empty' }
  $payload = $raw | ConvertFrom-Json
  $mode = [string]$payload.mode
  if ($payload.status) { $script:statusPath = [string]$payload.status }

  if ($mode -eq 'notify') {
    if ($null -ne $payload.ui) { $script:status.toast = Show-Toast $payload.ui.toast }
    $exitCode = 0
  } elseif (@('desktop', 'help', 'service') -notcontains $mode) {
    throw ('unknown mode: ' + $mode)
  } else {
    $op = [string]$payload.op
    $argList = @()
    foreach ($a in @($payload.args64)) {
      if ($null -ne $a) { $argList += [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$a)) }
    }
    if (-not $op -or -not (Test-Path -LiteralPath $op -PathType Leaf)) {
      $script:status.error = 'op.exe not found: ' + $op
      [Console]::Error.WriteLine('pjp-op: launcher: op.exe not found: ' + $op)
      $exitCode = 127
    } elseif ($mode -eq 'desktop') {
      $exitCode = Invoke-Desktop $op $argList $payload.ui
      $script:status.exit = $exitCode
      Close-Session $op
    } else {
      $proc = Start-Op $op $argList
      $proc.WaitForExit()
      $exitCode = $proc.ExitCode
      $script:status.exit = $exitCode
      if ($mode -eq 'help') { Close-Session $op }
    }
  }
} catch {
  $script:status.error = Get-Short $_.Exception.Message 300
  if ($script:status.started) {
    if ($null -ne $script:status.exit) { $exitCode = [int]$script:status.exit }
  } else {
    [Console]::Error.WriteLine('pjp-op: launcher: ' + $script:status.error)
    $exitCode = 1
  }
}
Write-Status
exit $exitCode
