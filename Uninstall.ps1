<#
.SYNOPSIS
  Removes the Corsair PSU USB reset: the scheduled task and C:\ProgramData\CorsairPsuFix
  (including reset.log). Run from an elevated PowerShell.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$InstallDir = 'C:\ProgramData\CorsairPsuFix')
$ErrorActionPreference = 'Stop'

foreach ($name in 'Corsair PSU USB reset', 'Corsair HX750i USB reset') {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        "Removed the scheduled task '$name'."
    }
}
logman stop CorsairPsuProbe -ets 2>$null | Out-Null

if (Test-Path (Join-Path $InstallDir 'Reset-CorsairPsu.ps1')) {
    Remove-Item $InstallDir -Recurse -Force
    "Removed $InstallDir."
} elseif (Test-Path $InstallDir) {
    "Left $InstallDir alone: it doesn't contain Reset-CorsairPsu.ps1."
}
