<#
.SYNOPSIS
    Builds the two self-contained BAT files from these source parts.

.DESCRIPTION
    aiznm_CLEANER.bat (Personal edition) and aiznm_CLEANER_Universal.bat are
    generated from the same code. Edit the parts in this folder, then run:

        powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Build-AiznmCleaner.ps1

    The output is plain ASCII with Windows (CRLF) line endings, which batch
    files require. Runs on Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [ValidateSet('all', 'personal', 'universal')][string]$Edition = 'all',
    [string]$OutDir = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$editions = @{
    personal  = @{ File = 'aiznm_CLEANER.bat'; TITLE = 'aiznm CLEANER'; TARGET = 'Personal edition for one documented Windows 10 Home 22H2 PC, Windows PowerShell 5.1' }
    universal = @{ File = 'aiznm_CLEANER_Universal.bat'; TITLE = 'aiznm CLEANER Universal'; TARGET = 'Universal edition for any Windows 10 or 11 PC, Windows PowerShell 5.1 (built in)' }
}
$parts = @('00-launcher.cmd.template', '01-core.ps1', '02-edition-{0}.ps1', '03-env.ps1', '04-engine.ps1', '05-categories.ps1', '06-flows.ps1', '07-info.ps1')
$names = @('personal', 'universal')
if ($Edition -ne 'all') { $names = @($Edition) }
foreach ($e in $names) {
    $meta = $editions[$e]
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $parts) {
        $name = $p -f $e
        $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)).Replace("`r`n", "`n")
        if ($name -like '00-*') { foreach ($k in @('TITLE', 'TARGET')) { $t = $t.Replace('{{' + $k + '}}', $meta[$k]) } }
        if (-not $t.EndsWith("`n")) { $t += "`n" }
        [void]$sb.Append($t)
    }
    $text = $sb.ToString()
    if ($text -match '[^\x09\x0A\x20-\x7E]') { throw "Non-ASCII character found while building $($meta.File). Batch files must stay plain ASCII." }
    if ($text.IndexOf('{{') -ge 0 -and $text.IndexOf('{{') -lt $text.IndexOf('##AIZNM_PS_BEGIN##')) { throw 'A launcher placeholder was not replaced.' }
    $out = Join-Path $OutDir $meta.File
    [IO.File]::WriteAllBytes($out, [Text.Encoding]::ASCII.GetBytes($text.Replace("`n", "`r`n")))
    Write-Host ('Built {0} ({1:N0} bytes)' -f $out, (Get-Item -LiteralPath $out).Length)
}
