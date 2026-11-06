<#
.SYNOPSIS
  Installs the Corsair PSU USB reset: copies the scripts to C:\ProgramData\CorsairPsuFix and
  registers the scheduled task "Corsair PSU USB reset". Run from an elevated PowerShell.

.DESCRIPTION
  The task runs Reset-CorsairPsu.ps1 as SYSTEM at boot, at logon and on every wake from sleep
  (System log, Power-Troubleshooter event 1). Because it runs as SYSTEM, the install folder is
  locked so only SYSTEM and Administrators can change the script. Running Install.ps1 again
  updates an existing install and keeps reset.log.

.PARAMETER ProductId
  USB product ID of the PSU (vendor 1B1C). 1C05 = HX750i (tested). Other models: Device Manager
  -> the PSU's USB device -> Details -> Hardware Ids (untested).

.EXAMPLE
  .\Install.ps1
.EXAMPLE
  .\Install.ps1 -ProductId 1C06
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9A-Fa-f]{4}$')][string]$ProductId = '1C05',
    [string]$InstallDir = 'C:\ProgramData\CorsairPsuFix'
)
$ErrorActionPreference = 'Stop'
$TaskName = 'Corsair PSU USB reset'
$ProductId = $ProductId.ToUpper()

foreach ($f in 'Reset-CorsairPsu.ps1', 'Uninstall.ps1') {
    if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { throw "$f is missing next to Install.ps1." }
}
if (-not (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "USB\VID_1B1C&PID_$ProductId\*" })) {
    Write-Warning "No Corsair USB device 1B1C:$ProductId is connected right now. Installing anyway."
}

# Folder: owned by Administrators, writable only by SYSTEM and Administrators, readable by Users.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
icacls $InstallDir /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
icacls $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Setting permissions on $InstallDir failed." }

Copy-Item (Join-Path $PSScriptRoot 'Reset-CorsairPsu.ps1'), (Join-Path $PSScriptRoot 'Uninstall.ps1') $InstallDir -Force
# files from older versions of this fix
Remove-Item (Join-Path $InstallDir 'probe.py'), (Join-Path $InstallDir 'providers.txt'), (Join-Path $InstallDir 'README.txt') -Force -ErrorAction SilentlyContinue
# older task name
if (Get-ScheduledTask -TaskName 'Corsair HX750i USB reset' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'Corsair HX750i USB reset' -Confirm:$false
}

$script = Join-Path $InstallDir 'Reset-CorsairPsu.ps1'
$arguments = [Security.SecurityElement]::Escape("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -ProductId $ProductId")
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Restarts the Corsair PSU (USB 1B1C:$ProductId) monitoring link after boot, logon and wake so iCUE sensor polling is not stalled. Log: $([Security.SecurityElement]::Escape($InstallDir))\reset.log</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <EventTrigger>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <BootTrigger />
    <LogonTrigger />
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null

"Installed to $InstallDir and registered the task '$TaskName' for PSU 1B1C:$ProductId."
"Test it now:   Start-ScheduledTask -TaskName '$TaskName'   then after ~45 s:"
"               Get-Content '$InstallDir\reset.log' -Tail 1"
