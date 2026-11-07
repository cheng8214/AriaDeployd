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
    [int]$Chunk = 900000,
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

Write-Host ('[2/5] upload ' + $bytes.Length + ' bytes in ' + $total + ' chunks') -ForegroundColor Cyan
$seg = Join-Path $env:TEMP 'deployd_seg.bin'
for ($i = 0; $i -lt $total; $i++) {
    $start = $i * $Chunk
    $len = [Math]::Min($Chunk, $bytes.Length - $start)
    $buf = New-Object byte[] $len
    [Array]::Copy($bytes, $start, $buf, 0, $len)
    [IO.File]::WriteAllBytes($seg, $buf)
    $r = curl.exe -s -m 60 -X POST -H ('X-Token: ' + $Token) -H ('X-To: ' + $Dest) -H ('X-Part: ' + [string]$i) --data-binary ('@' + $seg) ($base + '/upload')
    if ($r -notmatch '"ok":true') {
        Write-Host ('  chunk ' + $i + ' FAILED: ' + $r) -ForegroundColor Red
        exit 1
    }
    Write-Host ('  chunk ' + ($i + 1) + '/' + $total + ' ok') -ForegroundColor DarkGray
}
Remove-Item $seg -Force -ErrorAction SilentlyContinue

Write-Host '[3/5] merge chunks' -ForegroundColor Cyan
$m = curl.exe -s -m 40 -X POST -H ('X-Token: ' + $Token) -H ('X-To: ' + $Dest) -H ('X-N: ' + [string]$total) -H ('X-Name: ' + $Name) ($base + '/merge')
Write-Host ('  ' + $m) -ForegroundColor DarkGray
if ($m -notmatch ('"size":' + $bytes.Length)) {
    Write-Host '  merged size mismatch, abort' -ForegroundColor Red
    exit 1
}

Write-Host '[4/5] start' -ForegroundColor Cyan
$run = curl.exe -s -m 20 -X POST -H ('X-Token: ' + $Token) -H ('X-Exe: ' + $Dest) -H ('X-Args: ' + $StartArgs) ($base + '/start')
Write-Host ('  ' + $run) -ForegroundColor DarkGray

Write-Host '[5/5] verify' -ForegroundColor Cyan
Start-Sleep 4
$s = curl.exe -s -m 15 -H ('X-Token: ' + $Token) -H ('X-Name: ' + $Name) ($base + '/status')
Write-Host ('  status: ' + $s) -ForegroundColor DarkGray
if ($HealthUrl) {
    $hh = curl.exe -s -m 8 $HealthUrl
    if ($hh) { Write-Host ('  health: ' + $hh) }
    else { Write-Host '  health: (no response)' -ForegroundColor Yellow }
}
Write-Host 'done' -ForegroundColor Green
