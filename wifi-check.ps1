# Wi-Fi diagnostic for Windows.
# Read-only: it measures and reports, it changes no settings.
# Usage: powershell -ExecutionPolicy Bypass -File wifi-check.ps1
# Note: Wi-Fi details are read from "netsh wlan", whose labels are English;
# on a non-English Windows that section may show "unknown".

$ErrorActionPreference = 'SilentlyContinue'
$findings = New-Object System.Collections.Generic.List[string]
function Section($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

function Get-PingStats($target, $count = 20) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    for ($i = 0; $i -lt $count; $i++) {
        try { $r = $p.Send($target, 1000); if ($r.Status -eq 'Success') { $times += [double]$r.RoundtripTime } } catch {}
        Start-Sleep -Milliseconds 200
    }
    $loss = [math]::Round(100 * ($count - $times.Count) / $count, 1)
    $avg = 0; $jit = 0
    if ($times.Count -gt 0) { $avg = [math]::Round(($times | Measure-Object -Average).Average, 1) }
    if ($times.Count -gt 1) {
        $d = for ($i = 1; $i -lt $times.Count; $i++) { [math]::Abs($times[$i] - $times[$i - 1]) }
        $jit = [math]::Round(($d | Measure-Object -Average).Average, 1)
    }
    [pscustomobject]@{ Loss = $loss; Avg = $avg; Jitter = $jit }
}

# ---------- Router ----------
Section 'Router'
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
$devices = @(Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe' }).Count
Write-Host "Router address: $gw"
Write-Host "Devices seen on the network: $devices"

# ---------- Latency ----------
Section 'Latency (20 pings each)'
if ($gw) {
    $g = Get-PingStats $gw
    Write-Host ("To router:   avg {0} ms, jitter {1} ms, loss {2}%" -f $g.Avg, $g.Jitter, $g.Loss)
    if ($g.Avg -gt 10) { $findings.Add("Slow link to the router (avg $($g.Avg) ms; should be under 5 ms). The problem is between this PC and the router: weak signal or interference.") }
    if ($g.Loss -gt 1) { $findings.Add("Packet loss to the router ($($g.Loss)%). Usually weak signal or interference. Move closer or reduce obstacles.") }
    if ($g.Jitter -gt 15) { $findings.Add("Unstable link to the router (jitter $($g.Jitter) ms). Usually a crowded channel or interference.") }
}
$n = Get-PingStats '1.1.1.1'
Write-Host ("To internet: avg {0} ms, jitter {1} ms, loss {2}%" -f $n.Avg, $n.Jitter, $n.Loss)
if ($n.Avg -gt 60) { $findings.Add("High internet latency ($($n.Avg) ms). If the router link above is fine, the delay is on the modem/ISP side.") }
if ($n.Loss -gt 1) { $findings.Add("Packet loss to the internet ($($n.Loss)%). If the router link has none, contact your ISP or reboot the modem.") }

# ---------- Wi-Fi radio ----------
Section 'Wi-Fi radio'
$wi = netsh wlan show interfaces | Out-String
function Field($text, $name) { if ($text -match "(?m)^\s*$name\s*:\s*(.+?)\s*$") { $Matches[1] } }
$sigPct = Field $wi 'Signal'
$chan = Field $wi 'Channel'
$radio = Field $wi 'Radio type'
$band = Field $wi 'Band'
$rate = Field $wi 'Receive rate \(Mbps\)'
$sigDbm = $null
if ($sigPct -match '(\d+)') { $sigDbm = [int]$Matches[1] / 2 - 100 }
if (-not $band -and $chan -match '^\d+$') { $band = if ([int]$chan -le 14) { '2.4 GHz' } else { '5 GHz' } }

$nets = netsh wlan show networks mode=bssid | Out-String
$chans = [regex]::Matches($nets, '(?m)^\s*Channel\s*:\s*(\d+)') | ForEach-Object { $_.Groups[1].Value }
$nearby = [math]::Max(0, @($chans).Count - 1)
$same = [math]::Max(0, @($chans | Where-Object { $_ -eq $chan }).Count - 1)
Write-Host "Signal: $sigPct (~$sigDbm dBm)   Band: $band   Channel: $chan   Radio: $radio   Link rate: $rate Mbps"
Write-Host "Other access points nearby: $nearby   On your channel: $same"

if ($sigDbm -ne $null) {
    if ($sigDbm -lt -70) { $findings.Add("Weak signal ($sigPct). Move the router to a central, raised, open spot, away from walls, metal, microwaves and fish tanks, or add a mesh node / access point.") }
    elseif ($sigDbm -lt -60) { $findings.Add("Fair signal ($sigPct). Moving the router to a more central spot would help.") }
}
if ($band -like '2.4*') {
    $findings.Add('You are on 2.4 GHz, which is slower and more crowded. If the router also broadcasts 5 GHz, connect to that one (give the bands separate names in the router settings if they are merged).')
    if ($chan -and $chan -notin '1', '6', '11') { $findings.Add("2.4 GHz channel $chan overlaps its neighbours. In the router settings, set the 2.4 GHz channel to 1, 6 or 11, whichever has fewest networks.") }
}
if ($radio -match '802\.11[bg]$') { $findings.Add("This PC is connecting with old $radio. Update the Wi-Fi driver, or check the router isn't set to a legacy-only mode.") }
if ($same -ge 3) { $findings.Add("$same other access points share your channel $chan. In the router settings, pick a less crowded channel (or set it to Auto and reboot the router).") }

# ---------- Speed and bufferbloat ----------
Section 'Speed test (Cloudflare)'
$wc = New-Object System.Net.WebClient
$sw = [Diagnostics.Stopwatch]::StartNew()
try { $bytes = $wc.DownloadData('https://speed.cloudflare.com/__down?bytes=25000000').Length } catch { $bytes = 0 }
$dl = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($bytes * 8 / 1e6 / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
$payload = New-Object byte[] 10000000
$sw.Restart()
try { [void]$wc.UploadData('https://speed.cloudflare.com/__up', 'POST', $payload); $ul = [math]::Round(80 / $sw.Elapsed.TotalSeconds, 1) } catch { $ul = 0 }
Write-Host "Download: $dl Mbps   Upload: $ul Mbps"
Write-Host '(Compare with the speed on your internet plan.)'

Write-Host 'Measuring latency while the line is busy...'
$wc2 = New-Object System.Net.WebClient
$task = $wc2.DownloadDataTaskAsync('https://speed.cloudflare.com/__down?bytes=100000000')
Start-Sleep -Milliseconds 500
$loaded = Get-PingStats '1.1.1.1' 15
$wc2.CancelAsync()
Write-Host "Latency idle: $($n.Avg) ms   while downloading: $($loaded.Avg) ms"
if (($loaded.Avg - $n.Avg) -gt 100) {
    $findings.Add("Bufferbloat: latency jumps by $([int]($loaded.Avg - $n.Avg)) ms when the line is busy, so calls/games lag whenever someone downloads. Turn on SQM / Smart Queue / QoS in the router settings.")
}

# ---------- Summary ----------
Section "What's slowing you down"
if ($findings.Count -eq 0) {
    Write-Host "No clear problems found. If it still feels slow, run this again while it's slow, and compare the speed above with your plan."
} else {
    $i = 1; foreach ($f in $findings) { Write-Host "$i. $f"; $i++ }
}
Write-Host ''
Write-Host "Also worth doing: reboot the router and modem, update the router firmware, and check the router's device list for devices you don't recognise."
