# QQ 守护主循环（常驻）：每 90 秒调一次 qq-watchdog.ps1
# 单轮硬超时 8 分钟（防 docker 假死拖垮循环），超时杀掉子进程继续下一轮
# 带 PID 防重锁：已有循环在跑时，新实例自动退出
$ErrorActionPreference = 'SilentlyContinue'
$wd = '__BASE__\watchdog'
New-Item -ItemType Directory -Path $wd -Force | Out-Null

# ---- 防重锁 ----
$pidFile = Join-Path $wd 'watchdog-main.pid'
if (Test-Path $pidFile) {
    $old = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -match '^\d+$') {
        if (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue) { exit }
    }
}
Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII

while ($true) {
    $p = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $wd 'qq-watchdog.ps1')) `
        -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(480000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        Add-Content -LiteralPath (Join-Path $wd 'watchdog.log') -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  单轮超时已强杀,继续下一轮') -Encoding UTF8
    }
    Start-Sleep -Seconds 90
}
