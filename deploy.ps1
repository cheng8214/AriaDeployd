<#
  deploy.ps1 — 把 exe 推到目标机器并重启（配合 deployd.leno 用）

  用法：
    .\deploy.ps1 -TargetHost 192.168.1.150 -Dest C:\aria-server\server.exe -Exe d:\CLeno\Aria\server\dist\server.exe
    .\deploy.ps1 ... -Name server.exe -Args "5767 0.0.0.0 4"      # 部署后自动启动
    .\deploy.ps1 ... -OnlyStop                                    # 只停
    .\deploy.ps1 ... -Status                                      # 只看状态
    .\deploy.ps1 ... -Logs                                        # 看日志尾

  流程：分块上传（每块 900KB）→ /merge 合并 → 停止旧进程 → 启动 → 健康检查
#>
param(
    [string]$TargetHost = '192.168.1.150',
    [int]$Port = 8899,
    [string]$Token = 'test123',
    [string]$Dest = '',
    [string]$Exe = '',
    [string]$Name = 'server.exe',
    [string]$Args = '',
    [string]$HealthUrl = '',
    [int]$Chunk = 900000,
    [switch]$OnlyStop,
    [switch]$Status,
    [switch]$Logs,
    [int]$Tail = 40
)

$ErrorActionPreference = 'Stop'
$base = "http://${TargetHost}:${Port}"
$H = @{ 'X-Token' = $Token }

function Post($path, [hashtable]$extra) {
    $h = @{}
    foreach ($k in $H.Keys) { $h[$k] = $H[$k] }
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    $argsList = @('-s', '-m', '120', '-X', 'POST')
    foreach ($k in $h.Keys) { $argsList += @('-H', ($k + ': ' + [string]$h[$k])) }
    $argsList += @($base + $path)
    return (curl.exe @argsList)
}

function Get2($path, [hashtable]$extra) {
    $h = @{}
    foreach ($k in $H.Keys) { $h[$k] = $H[$k] }
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    $argsList = @('-s', '-m', '30')
    foreach ($k in $h.Keys) { $argsList += @('-H', ($k + ': ' + [string]$h[$k])) }
    $argsList += @($base + $path)
    return (curl.exe @argsList)
}

# ---- 健康检查 / 探活 ----
try {
    $h = curl.exe -s -m 5 "$base/health"
    if (-not $h) { throw "no response" }
    Write-Host "[deployd] $h" -ForegroundColor DarkGray
} catch {
    Write-Host "[FAIL] deployd 不可达 ($base)" -ForegroundColor Red
    Write-Host "       先在目标机启动 deployd.exe，并确认防火墙放行 $Port"
    exit 1
}

if ($Status) {
    Get2 '/status' @{ 'X-Name' = $Name }
    exit 0
}
if ($OnlyStop) {
    Post '/stop' @{ 'X-Name' = $Name }
    exit 0
}
if ($Logs) {
    $dir = Split-Path $Dest -Parent
    $lf = Join-Path $dir (Join-Path 'logs' ($Name + '.' + (Get-Date -Format 'yyyyMMdd') + '.log'))
    Get2 '/logs' @{ 'X-File' = $lf; 'X-N' = "$Tail" }
    exit 0
}

if (-not $Dest) { Write-Host "缺少 -Dest" -ForegroundColor Red; exit 1 }
if (-not $Exe) { Write-Host "缺少 -Exe" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Exe)) { Write-Host "找不到 $Exe" -ForegroundColor Red; exit 1 }

$bytes = [IO.File]::ReadAllBytes($Exe)
$total = [Math]::Ceiling($bytes.Length / $Chunk)
Write-Host "[1/4] 上传 $($bytes.Length) 字节，分 $total 块" -ForegroundColor Cyan

$seg = Join-Path $env:TEMP 'deployd_seg.bin'
for ($i = 0; $i -lt $total; $i++) {
    $start = $i * $Chunk
    $len = [Math]::Min($Chunk, $bytes.Length - $start)
    $buf = New-Object byte[] $len
    [Array]::Copy($bytes, $start, $buf, 0, $len)
    [IO.File]::WriteAllBytes($seg, $buf)
    $h = @{ 'X-Token' = $Token; 'X-To' = $Dest; 'X-Part' = "$i" }
    $r = curl.exe -s -m 60 -X POST -H "X-Token: $Token" -H "X-To: $Dest" -H "X-Part: $i" --data-binary "@$seg" "$base/upload"
    if ($r -notmatch '"ok":true') {
        Write-Host "  块 $i 失败: $r" -ForegroundColor Red
        exit 1
    }
    Write-Host ("  块 {0}/{1} ok" -f ($i + 1), $total) -ForegroundColor DarkGray
}
Remove-Item $seg -Force -ErrorAction SilentlyContinue

Write-Host "[2/4] 合并分块" -ForegroundColor Cyan
$m = Post '/merge' @{ 'X-To' = $Dest; 'X-N' = "$total" }
Write-Host "  $m" -ForegroundColor DarkGray
if ($m -notmatch ('"size":' + $bytes.Length)) {
    Write-Host "  合并后大小不符，终止" -ForegroundColor Red
    exit 1
}

Write-Host "[3/4] 停止旧进程并启动" -ForegroundColor Cyan
$st = Post '/stop' @{ 'X-Name' = $Name }
Write-Host "  stop: $st" -ForegroundColor DarkGray
$run = Post '/start' @{ 'X-Exe' = $Dest; 'X-Args' = $Args }
Write-Host "  start: $run" -ForegroundColor DarkGray

Write-Host "[4/4] 检查" -ForegroundColor Cyan
Start-Sleep 3
$s = Get2 '/status' @{ 'X-Name' = $Name }
Write-Host "  status: $s" -ForegroundColor DarkGray
if ($HealthUrl) {
    try {
        $h = curl.exe -s -m 8 $HealthUrl
        Write-Host "  health: $h"
    } catch {
        Write-Host "  health 检查失败" -ForegroundColor Red
    }
}
Write-Host "完成" -ForegroundColor Green
