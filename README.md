# SSTP-Fix

One-click repair for a common Windows 11 problem: **the built-in VPN connects, then the internet drops for ~60 seconds and the tray shows "No Internet".**

Built with **AutoClaw**: the diagnosis came from AutoClaw reading the RAS and NCSI logs.

## What the diagnosis found
- VPN profiles use `TunnelType = Automatic`, so Windows tries IKEv2 → SSTP → PPTP → L2TP one after another (about 83 s, error 800).
- `SplitTunneling = False`: every attempt changes the default route and DNS, so NCSI reports "No Internet".
- Large HTTPS pages can stall because of the tunnel MTU.

## What the script does
- Pins VPN profiles to **SSTP** (optional, `-KeepFallback` to skip)
- Sets the tunnel MTU to **1400**
- Disables IPv6 on the VPN adapter only
- Registers a task that repairs the tunnel right after it connects
- **Backs up** the registry, VPN profiles and task before any change

## Usage (run as Administrator)
| Command | What it does |
|---|---|
| `SSTP-Fix.bat` | apply the fix |
| `SSTP-Fix.bat dryrun` | preview only, changes nothing |
| `SSTP-Fix.bat status` | show current state |
| `SSTP-Fix.bat diag` | record a 90 s timeline while you connect |
| `SSTP-Fix.bat restore` | undo everything from the latest backup |

Keep `SSTP-Fix.bat` and `SSTP-Fix.ps1` in the same folder.

## Notes
- Backups and logs are written to `C:\ProgramData\SSTP-Fix`. They contain your VPN server and adapter names, so do not share them publicly.
- `restore` does not remove PMTU values that did not exist before (harmless).
- Status: diagnosis-based; not yet tested before/after on the author's machine.

## License
MIT
