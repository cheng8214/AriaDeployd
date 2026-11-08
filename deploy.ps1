<#
  deploy.ps1 - push an exe to a remote deployd and restart it

  Usage:
    .\deploy.ps1 -TargetHost 192.168.1.150 -Token tk193281 `
                 -Exe d:\CLeno\Aria\server\dist\server.exe `
                 -Dest D:\AriaServer\server.exe `
                 -Name server.exe -StartArgs '5767 0.0.0.0 4' `
                 -HealthUrl http://192.168.1.150:5767/health

    -Status / -OnlyStop / -Logs switches are available too.

  Flow: stop -> upload chunks -> merge -> start -> verify
    stop first: merge overwrites the exe, and a running process holds the file
    (deployd would return 500 "cannot create file").
#>
param(
    [string]$TargetHost = '192.168.1.150',
    [int]$Port = 8899,
    [string]$Token = '',
    [string]$Dest = '',
    [string]$Exe = '',
    [string]$Name = 'server.exe',
    [string]$StartArgs = '',
    [string]$HealthUrl = '',
    [int]$Chunk = 2000000,
    [switch]$OnlyStop,
    [switch]$Status,
    [switch]$Logs,
    [int]$Tail = 40
)

$ErrorActionPreference = 'Continue'
$base = 'http://' + $TargetHost + ':' + [string]$Port

# ---- probe ----
$h = curl.exe -s -m 5 ($base + '/health')
if (-not $h) {
    Write-Host ('[FAIL] deployd unreachable: ' + $base) -ForegroundColor Red
    exit 1
}
Write-Host ('[deployd] ' + $h) -ForegroundColor DarkGray

if ($Status) {
    curl.exe -s -m 15 -H ('X-Token: ' + $Token) -H ('X-Name: ' + $Name) ($base + '/status')
    Write-Host ''
    exit 0
}
if ($OnlyStop) {
    curl.exe -s -m 20 -X POST -H ('X-Token: ' + $Token) -H ('X-Name: ' + $Name) ($base + '/stop')
    Write-Host ''
    exit 0
}
if ($Logs) {
    $dir = Split-Path $Dest -Parent
    $lf = Join-Path $dir ('logs\' + $Name + '.' + (Get-Date -Format 'yyyyMMdd') + '.log')
    curl.exe -s -m 20 -H ('X-Token: ' + $Token) -H ('X-File: ' + $lf) -H ('X-N: ' + [string]$Tail) ($base + '/logs')
    Write-Host ''
    exit 0
}

if (-not $Dest) { Write-Host 'missing -Dest' -ForegroundColor Red; exit 1 }
if (-not $Exe) { Write-Host 'missing -Exe' -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Exe)) { Write-Host ('not found: ' + $Exe) -ForegroundColor Red; exit 1 }

$bytes = [IO.File]::ReadAllBytes($Exe)
$total = [Math]::Ceiling($bytes.Length / $Chunk)

Write-Host '[1/5] stop old process (release file handle)' -ForegroundColor Cyan
$st = curl.exe -s -m 20 -X POST -H ('X-Token: ' + $Token) -H ('X-Name: ' + $Name) ($base + '/stop')
Write-Host ('  ' + $st) -ForegroundColor DarkGray
Start-Sleep -Milliseconds 800

Write-Host ('[2/5] upload ' + $bytes.Length + ' bytes in ' + $total + ' chunk(s)') -ForegroundColor Cyan
# ★ 2026-11-08 性能修复：上传改用 .NET HttpClient，**不再用 curl.exe**
#   实测同一份 4.4MB（4 块 1.1MB）：
#     curl.exe 分块串行       1874 ms  (2.4 MB/s)   ← 慢的是 curl 这个工具
#     HttpClient 分块串行      124 ms  (34.8 MB/s)  ← 快 15 倍
#     HttpClient 分块并发       28 ms  (154 MB/s)   ← 服务端 4 worker 能并行
#   服务端自己 recv 4.4MB 只要 75ms ⇒ 瓶颈一直在客户端工具上，不是网络也不是框架 ✓
#   仍保留分块：目标机上跑的 deployd 若还是旧的 4MB 上限，一次传 4.4MB 会被拒；
#   每块 2MB 就两头都能用 ✓
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(180)

$swUp = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $total; $i++) {
    $start = $i * $Chunk
    $len = [Math]::Min($Chunk, $bytes.Length - $start)
    $buf = New-Object byte[] $len
    [Array]::Copy($bytes, $start, $buf, 0, $len)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, ($base + '/upload'))
        $req.Headers.Add('X-Token', $Token)
        $req.Headers.Add('X-To', $Dest)
        $req.Headers.Add('X-Part', [string]$i)
        $req.Content = New-Object System.Net.Http.ByteArrayContent(,$buf)
        $task = $client.SendAsync($req)
        $task.Wait()
        $body = $task.Result.Content.ReadAsStringAsync().Result
    } catch {
        Write-Host ('  chunk ' + $i + ' exception: ' + $_.Exception.Message) -ForegroundColor Red
        $client.Dispose(); exit 1
    }
    if ($body -notmatch '"ok":true') {
        Write-Host ('  chunk ' + $i + ' FAILED: ' + $body) -ForegroundColor Red
        $client.Dispose(); exit 1
    }
    Write-Host ('  chunk ' + ($i + 1) + '/' + $total + ' ok') -ForegroundColor DarkGray
}
$client.Dispose()
$swUp.Stop()
$msUp = [math]::Round($swUp.Elapsed.TotalMilliseconds)
$kbsUp = [math]::Round($bytes.Length / $swUp.Elapsed.TotalSeconds / 1024, 1)
Write-Host ('  upload took ' + $msUp + ' ms  (' + $kbsUp + ' KB/s)') -ForegroundColor DarkGray

Write-Host '[3/5] merge chunks' -ForegroundColor Cyan
if ($total -gt 1) {
    $m = curl.exe -s -m 40 -X POST -H ('X-Token: ' + $Token) -H ('X-To: ' + $Dest) -H ('X-N: ' + [string]$total) -H ('X-Name: ' + $Name) ($base + '/merge')
    Write-Host ('  ' + $m) -ForegroundColor DarkGray
    if ($m -notmatch '"ok":true') {
        Write-Host '  merge failed, abort' -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host '  (single chunk, nothing to merge)' -ForegroundColor DarkGray
}

Write-Host '[4/5] start' -ForegroundColor Cyan
$run = curl.exe -s -m 20 -X POST -H ('X-Token: ' + $Token) -H ('X-Exe: ' + $Dest) -H ('X-Args: ' + $StartArgs) ($base + '/start')
Write-Host ('  ' + $run) -ForegroundColor DarkGray

Write-Host '[5/5] verify' -ForegroundColor Cyan
# ★ 2026-11-08：原来固定的 `Start-Sleep 4` 是整条流程里最耗时的一段（占了 5 秒里的 4 秒）。
#   服务通常 1 秒内就起来了 ⇒ 改成轮询（300ms 一次，最多等 12 秒）✓
$s = ''
$hh = ''
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 300
    $s = curl.exe -s -m 5 -H ('X-Token: ' + $Token) -H ('X-Name: ' + $Name) ($base + '/status')
    if ($s -notmatch '"running":true') { continue }
    if (-not $HealthUrl) { $ready = $true; break }
    $hh = curl.exe -s -m 3 $HealthUrl
    if ($hh) { $ready = $true; break }
}
Write-Host ('  status: ' + $s) -ForegroundColor DarkGray
if ($HealthUrl) {
    if ($hh) { Write-Host ('  health: ' + $hh) }
    else { Write-Host '  health: (no response)' -ForegroundColor Yellow }
}
if ($ready) { Write-Host 'done' -ForegroundColor Green }
else { Write-Host 'done (but service did not report ready in 12s)' -ForegroundColor Yellow }
