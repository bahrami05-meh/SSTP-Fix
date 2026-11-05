<#
  SSTP-Fix.ps1  --  engine for SSTP-Fix.bat
  Repairs the "VPN connects, internet dies for ~60 s, tray says No Internet" cycle
  on Windows 11 with Windows-native (RRAS/SSTP) VPN profiles.

  Modes:  Fix | Restore | Diag | Status | OnConnect | DryRun
#>
[CmdletBinding()]
param(
    [ValidateSet('Fix','Restore','Diag','Status','OnConnect','DryRun')]
    [string]$Mode = 'Fix',
    [switch]$KeepFallback,     # do not pin profiles to SSTP
    [switch]$ForceNcsi,        # also restart NlaSvc after connect (forces a fresh probe)
    [switch]$ForcePin,         # pin to SSTP even if port 443 does not answer
    [int]$DiagSeconds = 90
)

$ErrorActionPreference = 'Continue'
$script:Root    = 'C:\ProgramData\SSTP-Fix'
$script:LogDir  = Join-Path $script:Root 'logs'
$script:TaskName = 'SSTP-Fix-OnConnect'
$script:TargetMtu = 1400          # PPP/SSTP payload MTU (1500 - 100 bytes overhead)
$script:DryRun  = ($Mode -eq 'DryRun')
$script:Changes = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- logging ----
function Initialize-Log {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $script:LogDir ("{0}-{1}.log" -f $Mode.ToLower(), $stamp)
}
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','FAIL','STEP')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    switch ($Level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'STEP' { Write-Host ''; Write-Host $line -ForegroundColor Cyan }
        default{ Write-Host $line }
    }
}
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ state ----
function Get-VpnProfiles {
    @(Get-VpnConnection -ErrorAction SilentlyContinue)
}
function Get-TunnelAdapter {
    # A dial-up/VPN adapter that is up and has a usable unicast IPv4 address.
    $cands = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'WAN Miniport|SSTP|PPP|IKEv2|L2TP|PPTP'
    })
    foreach ($c in $cands) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $c.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' })
        if ($ip.Count -gt 0) { return $c }
    }
    return $null
}
function Get-TunnelMtu {
    param([int]$IfIndex)
    $i = Get-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($i) { return [int]$i.NlMtu }
    return 0
}

# ------------------------------------------------------------- backup/undo ---
function New-Backup {
    if ($script:DryRun) {
        $stamp = 'preview-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    }
    $dir    = Join-Path $script:Root "backup\$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' (Join-Path $dir 'tcpip-parameters.reg') /y | Out-Null

    $profiles = Get-VpnProfiles
    $profiles | Select-Object Name,ServerAddress,TunnelType,SplitTunneling,EncryptionLevel,ConnectionStatus |
        Export-Csv -LiteralPath (Join-Path $dir 'vpn-profiles.csv') -NoTypeInformation -Encoding UTF8

    $adp = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $adp | Select-Object Name,InterfaceDescription,Status,InterfaceIndex |
        Export-Csv -LiteralPath (Join-Path $dir 'adapters.csv') -NoTypeInformation -Encoding UTF8

    Get-NetAdapterAdvancedProperty -Name 'Wi-Fi' -ErrorAction SilentlyContinue |
        Export-Csv -LiteralPath (Join-Path $dir 'wifi-advanced.csv') -NoTypeInformation -Encoding UTF8

    netsh int tcp show global > (Join-Path $dir 'tcp-global.txt')

    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task) { $task | Export-Clixml -LiteralPath (Join-Path $dir 'task.xml') }

    Write-Log "Backup written to $dir" OK
    return $dir
}
function Restore-Backup {
    param([string]$Dir)

    Write-Log 'Reverting VPN profile tunnel types' STEP
    $csv = Join-Path $Dir 'vpn-profiles.csv'
    if (Test-Path $csv) {
        foreach ($p in (Import-Csv -LiteralPath $csv)) {
            try {
                $cur = Get-VpnConnection -Name $p.Name -ErrorAction Stop
                if ($cur.TunnelType -ne $p.TunnelType) {
                    if (-not $script:DryRun) { Set-VpnConnection -Name $p.Name -TunnelType $p.TunnelType -Force -ErrorAction Stop }
                    Write-Log ("  {0}: {1} -> {2}" -f $p.Name, $cur.TunnelType, $p.TunnelType) OK
                }
            } catch { Write-Log ("  {0}: {1}" -f $p.Name, $_.Exception.Message) WARN }
        }
    } else { Write-Log '  no vpn-profiles.csv in backup' WARN }

    Write-Log 'Reverting TCP/IP registry values' STEP
    $reg = Join-Path $Dir 'tcpip-parameters.reg'
    if (Test-Path $reg) {
        if (-not $script:DryRun) { reg.exe import $reg | Out-Null }
        Write-Log '  tcpip\Parameters restored' OK
    } else { Write-Log '  no tcpip-parameters.reg in backup' WARN }

    Write-Log 'Removing scheduled task' STEP
    if (-not $script:DryRun) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Log ("  {0} removed (if it existed)" -f $script:TaskName) OK
}

# ------------------------------------------------------------------- fixes ---
function Test-TcpPort {
    param([string]$Target, [int]$Port = 443, [int]$TimeoutMs = 3000)
    if (-not $Target) { return $false }
    $h = $Target -replace ':\d+$', ''
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($h, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch { return $false } finally { $client.Close() }
}

function Set-TunnelTypeSstp {
    if ($KeepFallback) {
        Write-Log 'Step skipped (-KeepFallback): automatic IKEv2/SSTP/PPTP/L2TP ladder left intact' WARN
        return
    }
    Write-Log 'Pinning VPN profiles to SSTP (removes the 4-protocol fallback ladder)' STEP
    $profiles = Get-VpnProfiles
    if ($profiles.Count -eq 0) { Write-Log '  no VPN profiles found' WARN; return }
    foreach ($p in $profiles) {
        if ($p.TunnelType -eq 'Sstp') { Write-Log ("  {0}: already SSTP" -f $p.Name); continue }
        if ($p.ConnectionStatus -eq 'Connected') { Write-Log ("  {0}: connected - disconnect it first, skipped" -f $p.Name) WARN; continue }

        # Only pin when the SSTP endpoint actually answers; otherwise keep the fallback
        # ladder, so a blocked 443 does not leave the user without any working tunnel.
        if (-not $ForcePin) {
            if (Test-TcpPort -Target $p.ServerAddress -Port 443) {
                Write-Log ("  {0}: endpoint {1}:443 answers" -f $p.Name, $p.ServerAddress) INFO
            } else {
                Write-Log ("  {0}: {1}:443 unreachable - left on {2} (fallback kept)" -f $p.Name, $p.ServerAddress, $p.TunnelType) WARN
                continue
            }
        }

        try {
            if (-not $script:DryRun) { Set-VpnConnection -Name $p.Name -TunnelType Sstp -Force -ErrorAction Stop }
            [void]$script:Changes.Add("profile '$($p.Name)': $($p.TunnelType) -> Sstp")
            Write-Log ("  {0}: {1} -> Sstp" -f $p.Name, $p.TunnelType) OK
        } catch {
            Write-Log ("  {0}: FAILED - {1}" -f $p.Name, $_.Exception.Message) FAIL
        }
    }
}

function Set-TcpHardening {
    Write-Log 'Enabling path-MTU black-hole detection' STEP
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $want = @{ EnablePMTUDiscovery = 1; EnablePMTUBHDetect = 1 }
    foreach ($name in $want.Keys) {
        $cur = (Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -eq $cur) { $cur = '(not set)' } else { $cur = [int]$cur }
        if ($cur -ne $want[$name]) {
            if (-not $script:DryRun) { New-ItemProperty -Path $key -Name $name -Value $want[$name] -PropertyType DWord -Force | Out-Null }
            [void]$script:Changes.Add("registry $name : $cur -> $($want[$name])")
            Write-Log ("  {0}: {1} -> {2}" -f $name, $cur, $want[$name]) OK
        } else {
            Write-Log ("  {0}: already {1}" -f $name, $cur)
        }
    }
}

function Install-OnConnectTask {
    Write-Log 'Installing post-connect repair task' STEP

    $self = $PSCommandPath
    if (-not $self) { $self = (Get-Process -Id $PID).Path }
    $installed = Join-Path $script:Root 'SSTP-Fix.ps1'
    if (-not $script:DryRun) {
        if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
        Copy-Item -LiteralPath $self -Destination $installed -Force
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>SSTP-Fix</Author>
    <Description>Repairs the VPN tunnel right after it comes up (MTU, IPv6, DNS, probe warm-up).</Description>
    <URI>\$script:TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription><![CDATA[*[System[Provider[@Name='RasClient'] and (EventID=20224 or EventID=20225)]]]></Subscription>
      <Delay>PT0S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$installed" -Mode OnConnect</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    try { [void][xml]$xml } catch { throw "generated task XML is not well formed: $($_.Exception.Message)" }

    if (-not $script:DryRun) {
        Register-ScheduledTask -TaskName $script:TaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        [void]$script:Changes.Add("scheduled task $script:TaskName installed")
    }
    Write-Log ("  task '{0}' registered (trigger: RasClient 20224/20225)" -f $script:TaskName) OK
}

function Invoke-TunnelRepair {
    # Runs at every VPN connect: make the tunnel usable immediately.
    $adapter = $null
    for ($i = 0; $i -lt 15 -and -not $adapter; $i++) {
        $adapter = Get-TunnelAdapter
        if (-not $adapter) { Start-Sleep -Seconds 1 }
    }
    if (-not $adapter) { Write-Log 'no tunnel adapter came up; nothing to repair' WARN; return }

    Write-Log ("tunnel adapter: {0} (ifIndex {1}, {2})" -f $adapter.Name, $adapter.ifIndex, $adapter.InterfaceDescription) INFO

    $mtu = Get-TunnelMtu -IfIndex $adapter.ifIndex
    if ($mtu -ne $script:TargetMtu) {
        netsh interface ipv4 set subinterface "$($adapter.Name)" mtu=$script:TargetMtu store=active | Out-Null
        $mtu = Get-TunnelMtu -IfIndex $adapter.ifIndex
        Write-Log ("MTU set to {0}" -f $mtu) OK
    } else {
        Write-Log ("MTU already {0}" -f $mtu) INFO
    }

    try {
        $b = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
        if ($b.Enabled) {
            Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            Write-Log 'IPv6 unbound on tunnel (server advertises IPv6 but never routes it)' OK
        }
    } catch { Write-Log ("IPv6 unbind skipped: {0}" -f $_.Exception.Message) WARN }

    ipconfig /flushdns | Out-Null
    Write-Log 'DNS cache flushed' INFO

    # Warm the tunnel and give NCSI a successful HTTP probe to latch onto.
    for ($try = 1; $try -le 2; $try++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8
            $sw.Stop()
            $ok = ($r.Content -match 'Microsoft Connect Test')
            Write-Log ("probe {0}: HTTP {1} in {2} ms (content {3})" -f $try, $r.StatusCode, $sw.ElapsedMilliseconds, $(if($ok){'valid'}else{'unexpected'})) $(if($ok){'OK'}else{'WARN'})
            if ($ok) { break }
        } catch {
            $sw.Stop()
            Write-Log ("probe {0}: failed after {1} ms - {2}" -f $try, $sw.ElapsedMilliseconds, $_.Exception.Message) WARN
            Start-Sleep -Seconds 2
        }
    }

    $prof = Get-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
    if ($prof) { Write-Log ("NCSI view of tunnel: IPv4={0} IPv6={1}" -f $prof.IPv4Connectivity, $prof.IPv6Connectivity) INFO }

    if ($ForceNcsi) {
        Restart-Service -Name NlaSvc -Force -ErrorAction SilentlyContinue
        Write-Log 'NlaSvc restarted (forced re-evaluation)' WARN
    }
}

# -------------------------------------------------------------------- diag ---
function Invoke-Diag {
    $out = Join-Path $script:LogDir ("diag-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Log ("sampling for {0} s -> {1}" -f $DiagSeconds, $out) STEP
    Write-Log 'connect the VPN now' WARN
    $rows = @()
    $end = (Get-Date).AddSeconds($DiagSeconds)
    while ((Get-Date) -lt $end) {
        $a = Get-TunnelAdapter
        $def = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Sort-Object RouteMetric | Select-Object -First 1
        $prof = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1

        $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue

        $dnsOk = $false
        try { Resolve-DnsName -Name 'www.msftconnecttest.com' -Type A -QuickTimeout -ErrorAction Stop | Out-Null; $dnsOk = $true } catch { }

        $http = 'FAIL'; $ms = ''
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8
            $sw.Stop(); $ms = $sw.ElapsedMilliseconds
            $http = if ($r.Content -match 'Microsoft Connect Test') { 'OK' } else { 'BAD_CONTENT' }
        } catch { $sw.Stop(); $ms = $sw.ElapsedMilliseconds }

        $row = [pscustomobject]@{
            Time        = (Get-Date -Format 'HH:mm:ss')
            Tunnel      = if ($a) { $a.Name } else { '-' }
            TunnelMtu   = if ($a) { Get-TunnelMtu -IfIndex $a.ifIndex } else { '' }
            DefaultIf   = if ($def) { $def.InterfaceAlias } else { '-' }
            NcsiV4      = if ($prof) { $prof.IPv4Connectivity } else { '-' }
            Ping8888    = $ping
            DnsResolve  = $dnsOk
            HttpProbe   = $http
            HttpMs      = $ms
        }
        $rows += $row
        Write-Host ("{0}  tunnel={1,-12} mtu={2,-5} default={3,-10} ncsi={4,-10} ping={5,-5} dns={6,-5} http={7} ({8} ms)" -f `
            $row.Time, $row.Tunnel, $row.TunnelMtu, $row.DefaultIf, $row.NcsiV4, $row.Ping8888, $row.DnsResolve, $row.HttpProbe, $row.HttpMs)
        Start-Sleep -Seconds 2
    }
    $rows | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
    Write-Log ("diag written to {0}" -f $out) OK
}

# ------------------------------------------------------------------ status ---
function Show-Status {
    Write-Log 'CURRENT STATE' STEP
    $profiles = Get-VpnProfiles
    Write-Log ("VPN profiles: {0}" -f $profiles.Count)
    $profiles | Select-Object Name,ServerAddress,TunnelType,SplitTunneling,ConnectionStatus | Format-Table -AutoSize | Out-String | Write-Host

    $a = Get-TunnelAdapter
    if ($a) {
        Write-Log ("active tunnel: {0}  MTU={1}" -f $a.Name, (Get-TunnelMtu -IfIndex $a.ifIndex))
    } else {
        Write-Log 'no active tunnel adapter'
    }

    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $v = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    Write-Log ("EnablePMTUDiscovery={0}  EnablePMTUBHDetect={1}" -f $v.EnablePMTUDiscovery, $v.EnablePMTUBHDetect)

    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Log ("repair task installed: {0}" -f [bool]$t)

    $last = Get-ChildItem $script:LogDir -Filter 'onconnect-*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last) { Write-Log ("last on-connect log: {0}" -f $last.FullName) }
}

# -------------------------------------------------------------------- main ---
Initialize-Log

switch ($Mode) {

    'OnConnect' {
        $guard = Join-Path $script:Root '.onconnect-last'
        $skip = $false
        if (Test-Path $guard) {
            $age = (Get-Date) - (Get-Item $guard).LastWriteTime
            if ($age.TotalSeconds -lt 15) { $skip = $true }
        }
        if (-not $skip) {
            Set-Content -LiteralPath $guard -Value (Get-Date -Format o) -Encoding ASCII
            Invoke-TunnelRepair
        }
        break
    }

    'Status' {
        Show-Status
        break
    }

    'Diag' {
        Invoke-Diag
        break
    }

    'Restore' {
        if (-not (Test-Admin)) { Write-Log 'run as Administrator' FAIL; exit 5 }
        $dirs = @(Get-ChildItem (Join-Path $script:Root 'backup') -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
                  Sort-Object Name -Descending)
        if ($dirs.Count -eq 0) { Write-Log 'no backup found - nothing to restore' FAIL; exit 4 }
        Restore-Backup -Dir $dirs[0].FullName
        Write-Log 'restore finished. Reboot not required; reconnect the VPN.' OK
        break
    }

    { $_ -in 'Fix','DryRun' } {
        if (-not $script:DryRun -and -not (Test-Admin)) { Write-Log 'run as Administrator' FAIL; exit 5 }
        if ($script:DryRun) { Write-Log 'DRY RUN - nothing will be changed' WARN }

        Write-Log ("mode={0} root={1}" -f $Mode, $script:Root) INFO
        $backup = New-Backup
        Set-TunnelTypeSstp
        Set-TcpHardening
        Install-OnConnectTask

        if (Get-TunnelAdapter) {
            Write-Log 'a tunnel is up - repairing it now' STEP
            if (-not $script:DryRun) { Invoke-TunnelRepair }
        }

        Write-Log 'SUMMARY' STEP
        if ($script:Changes.Count -eq 0) {
            Write-Log 'nothing needed changing' OK
        } else {
            foreach ($c in $script:Changes) { Write-Log ("  changed: {0}" -f $c) OK }
        }
        Write-Log ("backup: {0}" -f $backup) INFO
        Write-Log 'next: connect the VPN and watch the tray icon; run "SSTP-Fix.bat diag" if it still stalls.' INFO
        break
    }
}
