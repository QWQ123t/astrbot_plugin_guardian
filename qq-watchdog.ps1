# QQ Bot 全自动守护脚本（单轮）v4
# 由 watchdog-main.ps1 常驻循环调用；带锁防重叠；所有路径基于工作区
$ErrorActionPreference = 'SilentlyContinue'

$base       = '__BASE__'
$logDir     = Join-Path $base 'watchdog'
$lockFile   = Join-Path $logDir 'watchdog.lock'
$mainLog    = Join-Path $logDir 'watchdog.log'
$statusFile = Join-Path $logDir 'status.txt'
$stateFile  = Join-Path $logDir 'state.json'
$qrOut      = Join-Path $base 'qq登录二维码_最新.png'
$napcatData = Join-Path $base 'napcat\data\qq'
$astrbotDir = Join-Path $base 'astrbot'
$astrbotExe = Join-Path $base 'astrbot-env\Scripts\astrbot.exe'
$dockerExe  = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$backupDir  = Join-Path $base 'napcat\backup\session'

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# ---- docker 超时保护包装：单条命令最多等60秒，防止 docker 假死拖垮守护 ----
function Dkr([string]$dkrArgs, [int]$timeoutSec = 60) {
    $o = Join-Path $logDir 'dkr.out.tmp'
    $e = Join-Path $logDir 'dkr.err.tmp'
    Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'docker' -ArgumentList $dkrArgs -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    if (-not $p.WaitForExit($timeoutSec * 1000)) { try { Stop-Process -Id $p.Id -Force } catch {}; return '__TIMEOUT__' }
    $r = ''; try { $r = [IO.File]::ReadAllText($o) } catch {}
    return $r
}

# ---- 防重叠锁（5分钟过期）----
if (Test-Path $lockFile) {
    $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt 5) { exit }
}
New-Item -ItemType File -Path $lockFile -Force | Out-Null

function Log($msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    Add-Content -LiteralPath $mainLog -Value $line -Encoding UTF8
    if ((Get-Item $mainLog -ErrorAction SilentlyContinue).Length -gt 2MB) {
        Move-Item -LiteralPath $mainLog ($mainLog + '.old') -Force
    }
}

# ---- 状态 ----
$state = @{ lastQrUrl = ''; restarts = 0; lastWipe = '2000-01-01T00:00:00' }
if (Test-Path $stateFile) {
    try { $s = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
          $state.lastQrUrl = [string]$s.lastQrUrl; $state.restarts = [int]$s.restarts; $state.lastWipe = [string]$s.lastWipe } catch {}
}
function Save-State {
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

# ---- 会话备份/恢复：登录成功后备份 global（含登录票据），损坏时可恢复免扫码 ----
function Backup-Session {
    $globalDir = Join-Path $napcatData 'global'
    if (-not (Test-Path $globalDir)) { return }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $tmpBak = Join-Path $base 'napcat\backup\session.tmp'
    if (Test-Path $tmpBak) { Remove-Item -LiteralPath $tmpBak -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $globalDir -Destination $tmpBak -Recurse -Force
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tmpBak -Destination $backupDir -Force
    Log 'QQ在线 -> 已备份会话数据(global)'
}
function Restore-Session {
    if (-not (Test-Path $backupDir)) { return $false }
    try {
        $globalDir = Join-Path $napcatData 'global'
        Copy-Item -LiteralPath $backupDir -Destination $globalDir -Recurse -Force
        return (Test-Path $globalDir)
    } catch { return $false }
}

$now  = Get-Date
$out  = @()

# ---- 1. Docker 引擎 ----
$eng = $false
$probe = Dkr "info --format {{.ServerVersion}}" 45
if ($probe) { $probe = $probe.Trim() }
if ($probe -eq '__TIMEOUT__' -or -not $probe) {
    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Start-Process $dockerExe
        Log 'Docker Desktop 未运行 -> 已启动'
        $out += 'DockerDesktop已拉起'
    }
    # 引擎可能在启动中：连续12次探测，失败过半才强杀重启
    $fails = 0
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        $probe = Dkr "info --format {{.ServerVersion}}" 45
        if ($probe) { $probe = $probe.Trim() }
        if ($probe -and $probe -ne '__TIMEOUT__') { break }
        $fails++
    }
    if ((-not $probe -or $probe -eq '__TIMEOUT__') -and $fails -ge 8) {
        Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 5
        try { Set-Service -Name 'com.docker.service' -StartupType Automatic -ErrorAction Stop; Start-Service -Name 'com.docker.service' -ErrorAction Stop } catch {}
        Start-Process $dockerExe
        Log 'Docker 引擎假死(连续探测失败) -> 已强杀重启'
        $out += '引擎已强杀重启'
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Seconds 5
            $probe = Dkr "info --format {{.ServerVersion}}" 45
            if ($probe) { $probe = $probe.Trim() }
            if ($probe -and $probe -ne '__TIMEOUT__') { break }
        }
    }
}
if ($probe -and $probe -ne '__TIMEOUT__') { $eng = $true; $out += '引擎OK' } else { $out += '引擎不可用' }

# ---- 2. napcat 容器 ----
$napcatRunning = $false
if ($eng) {
    $n = Dkr "ps --filter name=napcat --format {{.Names}}" 45
    if ($n -and $n -ne '__TIMEOUT__') { $napcatRunning = $true; $out += 'napcat运行中' }
    else {
        Dkr 'start napcat' 90 | Out-Null
        Log 'napcat 容器未运行 -> 已启动'
        $out += 'napcat已启动'
        Start-Sleep -Seconds 25
        $n = Dkr "ps --filter name=napcat --format {{.Names}}" 45
        if ($n -and $n -ne '__TIMEOUT__') { $napcatRunning = $true }
    }
}

# ---- 3. AstrBot ----
$l = Get-NetTCPConnection -LocalPort 6185 -State Listen -ErrorAction SilentlyContinue
if ($l) { $out += 'AstrBot运行中' }
else {
    Start-Process -FilePath $astrbotExe -ArgumentList 'run' -WorkingDirectory $astrbotDir -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDir 'astrbot-out.log') -RedirectStandardError (Join-Path $logDir 'astrbot-err.log')
    Log 'AstrBot 端口6185未监听 -> 已启动进程'
    $out += 'AstrBot已启动'
}

# ---- 4. QQ 登录状态检测与自愈 ----
if ($napcatRunning) {
    $log = Dkr 'logs napcat --tail 400' 60
    if ($log -eq '__TIMEOUT__') { $log = '' }

    # 是否在线：最近15分钟内有消息收发行（通用模式，不依赖机器人昵称）
    $online = $false
    $tsRx = [regex]'(\d\d-\d\d) (\d\d):(\d\d):(\d\d)'
    foreach ($ln in ($log -split "`n")) {
        if ($ln -match '\| (发送 ->|接收 <-)') {
            $m = $tsRx.Match($ln)
            if ($m.Success) {
                try {
                    $t = Get-Date ($now.Year.ToString() + '-' + $m.Groups[1].Value + ' ' + $m.Groups[2].Value + ':' + $m.Groups[3].Value + ':' + $m.Groups[4].Value)
                    if (($now - $t).TotalMinutes -ge 0 -and ($now - $t).TotalMinutes -lt 15) { $online = $true; break }
                } catch {}
            }
        }
    }

    # 最新二维码及其时间
    $qrUrl = ''
    $qrAgeMin = 9999
    $qrM = [regex]::Matches($log, '二维码解码URL: (https://txz\.qq\.com/\S+)')
    if ($qrM.Count -gt 0) {
        $qrUrl = $qrM[$qrM.Count - 1].Groups[1].Value
        $idx = $log.LastIndexOf($qrUrl)
        $before = $log.Substring(0, $idx)
        $tm = [regex]::Matches($before, '(\d\d-\d\d) (\d\d):(\d\d):(\d\d)')
        if ($tm.Count -gt 0) {
            $lm = $tm[$tm.Count - 1]
            try {
                $t = Get-Date ($now.Year.ToString() + '-' + $lm.Groups[1].Value + ' ' + $lm.Groups[2].Value + ':' + $lm.Groups[3].Value + ':' + $lm.Groups[4].Value)
                $qrAgeMin = ($now - $t).TotalMinutes
            } catch {}
        }
    }

    if ($online) {
        $out += 'QQ在线'
        $state.restarts = 0
        # 容器本次启动后首次在线时备份（票据对应本次登录会话，避免备份到空壳/旧票据）
        $needBak = $false
        $startedRawBak = Dkr "inspect napcat --format {{.State.StartedAt}}" 45
        try {
            $sb = [datetime]::Parse($startedRawBak, [Globalization.CultureInfo]::InvariantCulture)
            if ($sb.Kind -eq [datetimekind]::Unspecified) { $sb = [datetime]::SpecifyKind($sb, [datetimekind]::Utc) }
            $startedAt = $sb.ToLocalTime()
            if (-not (Test-Path $backupDir)) { $needBak = $true }
            elseif ((Get-Item $backupDir).LastWriteTime -lt $startedAt) { $needBak = $true }
        } catch { $needBak = $false }
        if ($needBak) { Backup-Session }
    } elseif ($qrUrl -and $qrAgeMin -lt 10) {
        # 等待扫码：渲染最新二维码
        if ($qrUrl -ne $state.lastQrUrl) {
            $enc = [Uri]::EscapeDataString($qrUrl)
            Invoke-WebRequest -Uri ('https://api.qrserver.com/v1/create-qr-code/?size=500x500&data=' + $enc) -OutFile $qrOut -UseBasicParsing -TimeoutSec 30
            $state.lastQrUrl = $qrUrl
            Log ('新二维码已渲染: ' + $qrOut)
        }
        $out += '等待扫码(最新二维码在 qq登录二维码_最新.png)'
    } else {
        # 卡死判定：容器已运行>=6分钟，但不在线也无近期二维码
        $startedRaw = Dkr "inspect napcat --format {{.State.StartedAt}}" 45
        $upMin = -1
        try {
            $s = [datetime]::Parse($startedRaw, [Globalization.CultureInfo]::InvariantCulture)
            if ($s.Kind -eq [datetimekind]::Unspecified) { $s = [datetime]::SpecifyKind($s, [datetimekind]::Utc) }
            $upMin = ($now - $s.ToLocalTime()).TotalMinutes
        } catch {}
        if ($upMin -ge 6) {
            if ([int]$state.restarts -lt 2) {
                # 优雅停止（30秒落盘）再启动，避免硬杀损坏会话数据
                Dkr 'stop -t 30 napcat' 120 | Out-Null
                Start-Sleep -Seconds 3
                Dkr 'start napcat' 90 | Out-Null
                $state.restarts = [int]$state.restarts + 1
                Log ('QQ登录卡死 -> 第' + $state.restarts + '次优雅重启容器')
                $out += ('卡死优雅重启x' + $state.restarts)
            } elseif ((($now - [datetime]$state.lastWipe).TotalMinutes) -ge 60) {
                # 反复卡死：清数据后优先恢复备份（可能免扫码快速登录），无备份则出新码
                Add-Type -AssemblyName Microsoft.VisualBasic
                Dkr 'stop -t 30 napcat' 120 | Out-Null
                Get-ChildItem $napcatData | Where-Object { $_.Name -ne 'NapCat' } | ForEach-Object {
                    if ($_.PSIsContainer) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($_.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin') }
                    else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($_.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin') }
                }
                $restored = Restore-Session
                Dkr 'start napcat' 90 | Out-Null
                $state.lastWipe = $now.ToString('o')
                $state.restarts = 0
                $state.lastQrUrl = ''
                if ($restored) {
                    Log 'QQ反复卡死 -> 已清理并恢复会话备份，容器已启动（尝试快速登录）'
                    $out += '已清数据并恢复备份(尝试免扫码)'
                } else {
                    Log 'QQ反复卡死 -> 已清理登录数据，容器已重启（将生成新二维码，需扫码）'
                    $out += '已清数据出新码'
                }
            } else {
                $out += '卡死但60分钟内已清理过,等待'
            }
        } else {
            $out += ('启动中(' + [int]$upMin + '分钟)')
        }
    }
}

Save-State
$st = ($now.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + ($out -join ' | '))
$tmp = $statusFile + '.tmp'
Set-Content -LiteralPath $tmp -Value $st -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $statusFile -Force
Log ($out -join ' | ')

Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
