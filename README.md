# Corsair PSU USB fix for slow iCUE sensors

A scheduled task that detects and fixes a Corsair PSU USB problem. While it lasts, iCUE refreshes
the PSU's sensors only every **10-25 seconds** instead of every ~1.5 s, and the sensors of other
Corsair devices slow down with it.

## Symptoms

- In iCUE, PSU readings (power, voltages, temperatures, fan) update only every 10-25 s.
- Other Corsair USB devices polled by iCUE, such as an AIO cooler, slow down too.
- CPU, motherboard and GPU sensors still update every second.
- Unplugging and replugging the PSU's internal USB cable fixes it until the next power-on.

## Cause

I found this with USB ETW traces of the PSU's traffic:

- **Broken state:** the PSU answers every second request with an **empty (zero-length) packet**.
  In a 25 s trace it sent 98 answers and 49 were empty, strictly alternating. iCUE then waits
  about 500 ms for the missing answer each time.
- **Shared polling:** iCUE polls the Corsair devices in one shared loop, so the cooler on the same
  machine got one sensor read in those 25 s.
- **The fix:** restarting the PSU's USB driver (`pnputil /restart-device`) clears it without
  cutting the PSU's power. A 40 s trace afterwards had 2538 answers, 0 empty, and both devices
  were back to a sensor update every ~1.5 s.

It happens at power-on, after both Fast Startup and real cold boots. In the one logged wake from
sleep, the PSU stayed healthy. The PSU uses Microsoft's standard HID driver, so this isn't a
Corsair driver bug.

It isn't settled whether the board's USB path or the PSU's firmware is at fault. Two things are
known. The same PSU worked on an older PC. On this board, both internal USB 2.0 headers sit
behind an onboard Genesys Logic hub chip (`05E3:0608`) on the chipset's USB controller. One way
to test it: connect the PSU to a rear USB port with a 9-pin header to USB-A adapter, then check
whether `before:` in the log stays `OK`.

## What the fix does

The task runs as SYSTEM at boot, at logon and on every wake from sleep. Each time it:

1. waits 20 s so iCUE has opened its devices;
2. records a 6 s USB trace and counts the PSU's answers and how many were empty. More than 20 %
   empty counts as `BROKEN`;
3. restarts the PSU's USB driver. The PSU keeps powering the PC; only its monitoring link restarts;
4. records a second trace and appends one line to `C:\ProgramData\CorsairPsuFix\reset.log`.

Real log from the tested PC:

```
2026-11-02 18:05:52  [cold boot] before: BROKEN (24 answers, 12 empty) | restart: ok | after: OK (376 answers, 0 empty)
2026-11-02 21:01:09  [wake from sleep] before: OK (376 answers, 0 empty) | restart: ok | after: OK (376 answers, 0 empty)
2026-11-05 18:58:00  [cold boot] before: BROKEN (21 answers, 12 empty) | restart: ok | after: OK (376 answers, 0 empty)
2026-11-06 16:54:00  [cold boot] before: BROKEN (22 answers, 11 empty) | restart: ok | after: OK (376 answers, 0 empty)
```

## Install

Download the repo, then in an **elevated** PowerShell (Run as administrator) in its folder:

```powershell
Get-ChildItem *.ps1 | Unblock-File      # files downloaded from GitHub are blocked by default
.\Install.ps1                           # HX750i
.\Install.ps1 -ProductId 1C06           # another model, see below
```

The installer copies `Reset-CorsairPsu.ps1` and `Uninstall.ps1` to `C:\ProgramData\CorsairPsuFix`
and registers the task **Corsair PSU USB reset**. Because the task runs as SYSTEM, the folder is
locked so that only SYSTEM and Administrators can change the files. Running the installer again
updates the install and keeps the log.

**Other Corsair PSUs:** the default product ID `1C05` is the HX750i. For another USB-monitored
Corsair PSU (HXi / RMi series), find its ID in Device Manager: the PSU's USB device → Properties →
Details → Hardware Ids, e.g. `USB\VID_1B1C&PID_1C06`. Only the HX750i is tested.

## Check and uninstall

```powershell
# Is the PSU in the broken state right now? Measures only, changes nothing.
& 'C:\ProgramData\CorsairPsuFix\Reset-CorsairPsu.ps1' -ProbeOnly

# Run the fix now and read the result after ~45 s
Start-ScheduledTask -TaskName 'Corsair PSU USB reset'
Get-Content 'C:\ProgramData\CorsairPsuFix\reset.log' -Tail 1

# Remove the task and the folder
& 'C:\ProgramData\CorsairPsuFix\Uninstall.ps1'
```

All of these need an elevated PowerShell. `Reset-CorsairPsu.ps1 -AnalyzeXml trace.xml` analyses a
trace you recorded yourself with the providers `Microsoft-Windows-USB-USBXHCI` and
`Microsoft-Windows-USB-UCX`, exported with `tracerpt -of XML`.

## Tested on

- Corsair HX750i (USB `1B1C:1C05`) and H115i PRO (`1B1C:0C13`)
- MSI MAG B650 TOMAHAWK WIFI, BIOS 1.P0, Ryzen 7 7800X3D
- iCUE 5.52, Windows 11 (build 26200)

## Requirements

Windows with its built-in Windows PowerShell 5.1. `logman`, `tracerpt` and `pnputil` are part of
Windows, so nothing else is needed. Tested on Windows 11 only; on Windows 10, `pnputil` must
support `/restart-device`.
