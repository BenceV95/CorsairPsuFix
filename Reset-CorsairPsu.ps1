<#
.SYNOPSIS
  Detects and fixes the Corsair PSU USB state that makes iCUE sensors refresh only every 10-25 s.

.DESCRIPTION
  Normally run by the scheduled task "Corsair PSU USB reset" (see Install.ps1) at boot, logon
  and wake from sleep:
    1. Waits -Delay seconds so iCUE has opened its devices.
    2. Records a 6-second USB trace (ETW providers USBXHCI + UCX) and counts the PSU's
       interrupt-IN answers and how many of them were empty -> OK / BROKEN.
    3. Restarts the PSU's USB driver (pnputil /restart-device). The PSU keeps powering the PC;
       only its monitoring link restarts.
    4. Records a second trace and appends one line to reset.log next to this script.
  Needs administrator rights (ETW tracing and pnputil). Windows PowerShell 5.1 compatible.

.PARAMETER ProductId
  USB product ID of the PSU (vendor 1B1C). 1C05 = HX750i. Other models: Device Manager ->
  the PSU's USB device -> Details -> Hardware Ids.

.PARAMETER Delay
  Seconds to wait before the first measurement (default 20; 0 with -ProbeOnly).

.PARAMETER ProbeOnly
  Only measure and print OK / BROKEN. Restarts nothing and writes no log line.

.PARAMETER AnalyzeXml
  Only analyse an existing trace exported with tracerpt -of XML, and print the verdict.

.EXAMPLE
  .\Reset-CorsairPsu.ps1 -ProbeOnly          # is the PSU in the broken state right now?

.NOTES
  https://github.com/BenceV95/CorsairPsuFix
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9A-Fa-f]{4}$')][string]$ProductId = '1C05',
    [int]$Delay = 20,
    [switch]$ProbeOnly,
    [string]$AnalyzeXml
)
$ErrorActionPreference = 'Continue'
$VendorId = 0x1B1C
$Log = Join-Path $PSScriptRoot 'reset.log'

if (-not ('CorsairPsuProbe' -as [type])) {
    $source = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Xml;

// Streams a tracerpt XML export of a USBXHCI + UCX ETW trace and counts the transfers that
// completed on the PSU's interrupt-IN pipes, and how many of them carried no data.
public static class CorsairPsuProbe
{
    static long Num(string s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        s = s.Trim();
        if (s.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) return Convert.ToInt64(s.Substring(2), 16);
        long v;
        return long.TryParse(s, out v) ? v : 0;
    }

    static string Get(Dictionary<string, string> d, string key)
    {
        string v;
        return d.TryGetValue(key, out v) ? v : "";
    }

    // Returns { psuSeen (0 or 1), answers, emptyAnswers }
    public static long[] Count(string path, long vendorId, long productId)
    {
        HashSet<string> devices = new HashSet<string>();                                     // UsbDevice handles of the PSU
        Dictionary<string, KeyValuePair<string, bool>> pipes = new Dictionary<string, KeyValuePair<string, bool>>(); // PipeHandle -> (UsbDevice, is IN)
        List<KeyValuePair<string, long>> completions = new List<KeyValuePair<string, long>>(); // (PipeHandle, length)

        XmlReaderSettings settings = new XmlReaderSettings();
        settings.DtdProcessing = DtdProcessing.Ignore;
        settings.XmlResolver = null;
        settings.IgnoreComments = true;
        settings.IgnoreProcessingInstructions = true;

        string provider = "", eventId = "", dataName = null;
        bool inEventId = false, inEventData = false;
        Dictionary<string, string> data = new Dictionary<string, string>();
        StringBuilder text = new StringBuilder();

        using (XmlReader r = XmlReader.Create(path, settings))
        {
            while (r.Read())
            {
                if (r.NodeType == XmlNodeType.Element)
                {
                    string n = r.LocalName;
                    if (n == "Event") { provider = ""; eventId = ""; data.Clear(); inEventId = false; inEventData = false; dataName = null; }
                    else if (n == "Provider") { provider = r.GetAttribute("Name") ?? ""; }
                    else if (n == "EventID" && !r.IsEmptyElement) { inEventId = true; text.Length = 0; }
                    else if (n == "EventData" && !r.IsEmptyElement) { inEventData = true; }
                    else if (n == "Data" && inEventData)
                    {
                        string name = r.GetAttribute("Name") ?? "";
                        if (r.IsEmptyElement) { if (!data.ContainsKey(name)) data[name] = ""; }
                        else { dataName = name; text.Length = 0; }
                    }
                }
                else if (r.NodeType == XmlNodeType.Text || r.NodeType == XmlNodeType.CDATA ||
                         r.NodeType == XmlNodeType.Whitespace || r.NodeType == XmlNodeType.SignificantWhitespace)
                {
                    if (inEventId || dataName != null) text.Append(r.Value);
                }
                else if (r.NodeType == XmlNodeType.EndElement)
                {
                    string n = r.LocalName;
                    if (n == "EventID" && inEventId) { eventId = text.ToString().Trim(); inEventId = false; }
                    else if (n == "Data" && dataName != null) { if (!data.ContainsKey(dataName)) data[dataName] = text.ToString().Trim(); dataName = null; }
                    else if (n == "EventData") { inEventData = false; }
                    else if (n == "Event")
                    {
                        if (provider.EndsWith("USBXHCI", StringComparison.Ordinal) && eventId == "4")
                        {
                            // device descriptor seen: remember the PSU's device handle
                            if (Num(Get(data, "fid_idVendor")) == vendorId && Num(Get(data, "fid_idProduct")) == productId)
                                devices.Add(Get(data, "fid_UsbDevice"));
                        }
                        else if (provider.EndsWith("UCX", StringComparison.Ordinal) && eventId == "6")
                        {
                            // endpoint/pipe created: which device it belongs to and whether it is IN
                            pipes[Get(data, "fid_PipeHandle")] = new KeyValuePair<string, bool>(
                                Get(data, "fid_UsbDevice"), (Num(Get(data, "fid_bEndpointAddress")) & 0x80) != 0);
                        }
                        else if (provider.EndsWith("UCX", StringComparison.Ordinal) && eventId == "27")
                        {
                            // transfer completed
                            completions.Add(new KeyValuePair<string, long>(
                                Get(data, "fid_PipeHandle"), Num(Get(data, "fid_URB_TransferBufferLength"))));
                        }
                    }
                }
            }
        }

        long answers = 0, empty = 0;
        foreach (KeyValuePair<string, long> c in completions)
        {
            KeyValuePair<string, bool> owner;
            if (pipes.TryGetValue(c.Key, out owner) && owner.Value && devices.Contains(owner.Key))
            {
                answers++;
                if (c.Value == 0) empty++;
            }
        }
        return new long[] { devices.Count > 0 ? 1 : 0, answers, empty };
    }
}
'@
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -TypeDefinition $source }
    else { Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Xml' }
}

function Get-PsuVerdict([string]$XmlPath) {
    $r = [CorsairPsuProbe]::Count($XmlPath, $VendorId, [Convert]::ToInt64($ProductId, 16))
    if ($r[0] -eq 0) { return 'PSU not seen in trace' }
    if ($r[1] -eq 0) { return 'no PSU traffic (iCUE not polling yet)' }
    # Healthy: every answer has data. Broken: about every second answer is empty.
    $verdict = if ($r[2] -gt $r[1] * 0.2) { 'BROKEN' } else { 'OK' }
    return '{0} ({1} answers, {2} empty)' -f $verdict, $r[1], $r[2]
}

# 6-second USB trace -> verdict. Never blocks the reset if it fails.
function Measure-Psu {
    $etl = Join-Path $PSScriptRoot 'probe.etl'
    $xml = Join-Path $PSScriptRoot 'probe.xml'
    $pf  = Join-Path $PSScriptRoot 'providers.txt'
    try {
        Set-Content -Path $pf -Encoding Ascii -Value @(
            'Microsoft-Windows-USB-USBXHCI 0xffffffffffffffff 0xff',
            'Microsoft-Windows-USB-UCX 0xffffffffffffffff 0xff')
        logman stop CorsairPsuProbe -ets 2>$null | Out-Null
        logman start CorsairPsuProbe -ets -pf $pf -o $etl -bs 1024 -nb 32 256 -mode Sequential | Out-Null
        if ($LASTEXITCODE -ne 0) { return "probe failed: logman exit code $LASTEXITCODE (needs administrator rights)" }
        Start-Sleep -Seconds 6
        logman stop CorsairPsuProbe -ets | Out-Null
        tracerpt $etl -o $xml -of XML -y -lr | Out-Null
        return (Get-PsuVerdict $xml)
    } catch {
        return "probe failed: $_"
    } finally {
        logman stop CorsairPsuProbe -ets 2>$null | Out-Null
        Remove-Item $etl, $xml, $pf -Force -ErrorAction SilentlyContinue
    }
}

function Write-Log([string]$Message) {
    if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) {
        Get-Content $Log -Tail 500 | Set-Content "$Log.tmp"; Move-Item "$Log.tmp" $Log -Force
    }
    Add-Content -Path $Log -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Get-RunContext {
    $since = (Get-Date).AddMinutes(-3)
    $boot = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27; StartTime = $since} -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($boot) {
        $type = ([xml]$boot.ToXml()).Event.EventData.Data[0].'#text'
        switch ($type) { '0' { return 'cold boot' } '1' { return 'Fast Startup boot' } '2' { return 'resume from hibernate' } default { return "boot type $type" } }
    }
    $wake = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $since} -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($wake) { return 'wake from sleep' }
    return 'logon/manual'
}

if ($AnalyzeXml) { Get-PsuVerdict (Resolve-Path $AnalyzeXml).Path; return }

$psus = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "USB\VID_1B1C&PID_$ProductId\*" })

if ($ProbeOnly) {
    if ($psus.Count -eq 0) { "No Corsair USB device 1B1C:$ProductId is connected."; return }
    if ($PSBoundParameters.ContainsKey('Delay')) { Start-Sleep -Seconds $Delay }
    Measure-Psu
    return
}

Start-Sleep -Seconds $Delay   # let iCUE finish opening its devices after boot/wake/logon
$ctx = Get-RunContext
if ($psus.Count -eq 0) { Write-Log "[$ctx] PSU 1B1C:$ProductId not present - nothing to do"; exit 0 }

$before = Measure-Psu
$restart = foreach ($p in $psus) {
    $out = (pnputil /restart-device "$($p.InstanceId)" 2>&1) -join ' '
    if ($LASTEXITCODE -eq 0) { 'ok' } else { "FAILED ($LASTEXITCODE): $out" }
}
Start-Sleep -Seconds 5
$after = Measure-Psu
Write-Log ("[{0}] before: {1} | restart: {2} | after: {3}" -f $ctx, $before, ($restart -join ', '), $after)
