# NT PS8's own original dark purple theme. Pure appearance; no system theme changes.
Set-StrictMode -Version Latest
function Set-NTPS8PurpleTheme {
    [CmdletBinding()]
    param()
    try {
        $esc = [char]27
        $bel = [char]7
        # OSC 11 is supported by modern terminal hosts, including Windows Terminal.
        # Older hosts simply ignore it and retain normal console colors.
        [Console]::Write("$esc]11;#170D2A$bel")
        $Host.UI.RawUI.ForegroundColor = 'Gray'
    } catch { }
}
Export-ModuleMember -Function Set-NTPS8PurpleTheme
