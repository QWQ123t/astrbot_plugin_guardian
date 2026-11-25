# astrbot_plugin_guardian - QQ机器人守护系统管理插件
# 守护本体运行在进程外（PowerShell 常驻循环），本插件负责部署、拉起与遥控。
import asyncio
import os
import subprocess
import time
from pathlib import Path

from astrbot.api import logger
from astrbot.api.event import filter, AstrMessageEvent
from astrbot.api.star import Context, Star, register
from astrbot.api.message_components import Plain, Image
from astrbot.core.config.astrbot_config import AstrBotConfig
from astrbot.core.message.message_event_result import MessageChain

CREATE_NO_WINDOW = 0x08000000
PLUGIN_DIR = Path(__file__).resolve().parent
# 插件位于 <工作区>/astrbot/data/plugins/<包名>/ -> 上溯 4 层即工作区根目录
BASE_DIR = PLUGIN_DIR.parent.parent.parent.parent
WD_DIR = BASE_DIR / 'watchdog'
# 扁平结构：守护脚本直接位于插件根目录（便于 GitHub 网页上传与维护）
GUARDIAN_SRC = PLUGIN_DIR
SCRIPTS = ('qq-watchdog.ps1', 'watchdog-main.ps1')


def run_ps(script: str, timeout: int = 30) -> str:
    """同步执行 PowerShell（仅短命令），返回 stdout"""
    try:
        r = subprocess.run(
            ['powershell.exe', '-NoProfile', '-Command', script],
            capture_output=True, text=True, timeout=timeout,
            creationflags=CREATE_NO_WINDOW,
        )
        return (r.stdout or '').strip()
    except Exception as e:
        logger.warning(f'[guardian] PS 执行失败: {e}')
        return ''


@register('astrbot_plugin_guardian', 'TeleAgent', 'QQ机器人守护系统管理插件', 'v1.0.0')
class GuardianPlugin(Star):
    def __init__(self, context: Context, config: AstrBotConfig):
        super().__init__(context)
        self.context = context
        self.config = config

    # ---------- 配置 ----------
    def _container(self) -> str:
        return str(self.config.get('napcat_container') or 'napcat').strip()

    def _stale_min(self) -> int:
        try:
            return max(2, int(self.config.get('stale_minutes') or 6))
        except (TypeError, ValueError):
            return 6

    def _is_admin(self, event: AstrMessageEvent) -> bool:
        sender = str(event.get_sender_id())
        try:
            admins = list(self.context.get_config().admins_id or [])
        except Exception:
            admins = []
        extra = str(self.config.get('admin_extra_ids') or '')
        extra = extra.replace('，', ',')
        admins += [x.strip() for x in extra.split(',') if x.strip()]
        return sender in {str(a) for a in admins}

    # ---------- 守护循环检测 / 拉起 ----------
    def _loop_pid(self) -> int | None:
        cmd = (
            "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | "
            "Where-Object { $_.CommandLine -match 'watchdog-main' } | "
            "Select-Object -First 1 -ExpandProperty ProcessId"
        )
        out = run_ps(cmd, 15)
        try:
            pid = int(out.splitlines()[0].strip())
            return pid if pid > 0 else None
        except (ValueError, IndexError):
            return None

    def _status_fresh(self) -> bool:
        st = WD_DIR / 'status.txt'
        if not st.exists():
            return False
        return (time.time() - st.stat().st_mtime) < self._stale_min() * 60

    def deploy_scripts(self) -> str:
        """释放内置脚本到 watchdog 目录（ps1 用 UTF-8 BOM，bat 用 GBK），返回动作说明"""
        if not GUARDIAN_SRC.exists():
            return '插件内置脚本缺失(guardian/)'
        WD_DIR.mkdir(parents=True, exist_ok=True)
        copied = []
        for name in SCRIPTS:
            src = GUARDIAN_SRC / name
            dst = WD_DIR / name
            new = src.read_text(encoding='utf-8').replace('__BASE__', str(BASE_DIR))
            old = dst.read_text(encoding='utf-8-sig', errors='ignore') if dst.exists() else ''
            if new.strip() != old.strip():
                dst.write_text(new, encoding='utf-8-sig')
                copied.append(name)
        # 启动文件夹 bat
        try:
            startup = Path(os.environ.get('APPDATA', '')) / 'Microsoft' / 'Windows' / 'Start Menu' / 'Programs' / 'Startup'
            bat = startup / 'QQ机器人守护.bat'
            bat_tpl = (GUARDIAN_SRC / 'watchdog-autostart.bat').read_text(encoding='utf-8').replace('__WD__', str(WD_DIR))
            if not bat.exists() or bat.read_text(encoding='gbk', errors='ignore').strip() != bat_tpl.strip():
                bat.write_text(bat_tpl, encoding='gbk')
                copied.append('启动文件夹bat')
        except Exception as e:
            logger.warning(f'[guardian] 写开机自启失败: {e}')
        return ('已更新: ' + ', '.join(copied)) if copied else '脚本已是最新'

    def spawn_loop(self) -> str:
        """通过跳板 PowerShell + Start-Process 拉起守护循环（脱离 AstrBot 父进程）"""
        main_ps1 = WD_DIR / 'watchdog-main.ps1'
        if not main_ps1.exists():
            return 'watchdog-main.ps1 不存在，请先执行 /守护 部署'
        pid = self._loop_pid()
        if pid:
            return f'守护循环已在运行(pid={pid})'
        inner = (
            "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile',"
            f"'-ExecutionPolicy','Bypass','-File','{main_ps1}') -WindowStyle Hidden"
        )
        try:
            subprocess.Popen(
                ['powershell.exe', '-NoProfile', '-Command', inner],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=CREATE_NO_WINDOW,
            )
        except Exception as e:
            return f'拉起失败: {e}'
        time.sleep(3)
        pid = self._loop_pid()
        return f'守护循环已拉起(pid={pid if pid else "?"})'

    def stop_loop(self) -> str:
        pid = self._loop_pid()
        if not pid:
            return '守护循环未在运行'
        run_ps(f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue", 10)
        return f'已停止守护循环(pid={pid})'

    # ---------- docker 异步封装 ----------
    async def dkr(self, args: list[str], timeout: int = 60) -> str:
        try:
            proc = await asyncio.create_subprocess_exec(
                'docker', *args,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                creationflags=CREATE_NO_WINDOW,
            )
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
            return (out or b'').decode('utf-8', 'replace').strip()
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return '__TIMEOUT__'
        except Exception as e:
            logger.warning(f'[guardian] docker 失败: {e}')
            return ''

    # ---------- 生命周期 ----------
    async def initialize(self):
        if not self.config.get('auto_deploy', True):
            logger.info('[guardian] auto_deploy=false，跳过自动部署')
            return
        # 稍等环境稳定，后台执行，不阻塞插件加载
        await asyncio.sleep(5)
        try:
            pid = self._loop_pid()
            fresh = self._status_fresh()
            if pid or fresh:
                logger.info(f'[guardian] 守护已就绪(循环pid={pid}, 状态新鲜={fresh})，无需拉起')
            else:
                msg = self.deploy_scripts()
                logger.info(f'[guardian] 守护未运行 -> 部署: {msg}')
                logger.info(f'[guardian] {self.spawn_loop()}')
        except Exception as e:
            logger.error(f'[guardian] 自动部署失败: {e}')

    # ---------- 指令 ----------
    @filter.command('守护')
    async def guardian_cmd(self, event: AstrMessageEvent, action: str = '状态'):
        if not self._is_admin(event):
            return  # 非管理员静默
        action = (action or '状态').strip()
        container = self._container()

        if action in ('状态', '', '状态摘要'):
            await self.cmd_status(event)
        elif action == '部署':
            msg = await asyncio.to_thread(self.deploy_scripts)
            msg2 = await asyncio.to_thread(self.spawn_loop)
            await event.send(MessageChain([Plain(f'[守护管家]\n{msg}\n{msg2}')]))
        elif action in ('重启容器', '重启napcat'):
            await event.send(MessageChain([Plain(f'[守护管家] 优雅重启容器 {container} (30秒落盘防会话损坏)...')]))
            out = await self.dkr(['stop', '-t', '30', container], 120)
            await asyncio.sleep(3)
            out2 = await self.dkr(['start', container], 90)
            await event.send(MessageChain([Plain(f'[守护管家] 容器已优雅重启，约 30 秒后生效（会话数据已落盘，大概率免扫码）')]))
        elif action in ('重启守护', '重启循环'):
            msg1 = await asyncio.to_thread(self.stop_loop)
            msg2 = await asyncio.to_thread(self.spawn_loop)
            await event.send(MessageChain([Plain(f'[守护管家]\n{msg1}\n{msg2}')]))
        elif action == '日志':
            await self.cmd_log(event)
        elif action in ('二维码', '发码'):
            await self.cmd_qrcode(event)
        elif action in ('恢复登录', '恢复'):
            await self.cmd_restore(event)
        elif action in ('新码', '清数据'):
            await self.cmd_newcode(event)
        else:
            await event.send(MessageChain([Plain(
                '[守护管家] 子命令: 状态 | 部署 | 重启容器 | 重启守护 | 日志 | 二维码 | 恢复登录 | 新码')]))

    async def cmd_status(self, event: AstrMessageEvent):
        pid = await asyncio.to_thread(self._loop_pid)
        fresh = await asyncio.to_thread(self._status_fresh)
        st_path = WD_DIR / 'status.txt'
        st_txt = st_path.read_text(encoding='utf-8-sig', errors='ignore').strip() if st_path.exists() else '(无状态文件)'
        loop_txt = f'循环进程 pid={pid}' if pid else '循环未运行'
        if pid and not fresh:
            loop_txt += ' (状态超过冷却期,可能卡住)'
        elif not pid:
            loop_txt += ' / 状态' + ('新鲜(可能刚拉起)' if fresh else '过期')
        cstate = await self.dkr(['ps', '-a', '--format', '{{.Names}} {{.Status}}'], 45)
        lines = [f'[守护管家] {loop_txt}', f'状态文件: {st_txt or "(空)"}', f'容器: {cstate or "docker不可用"}']
        await event.send(MessageChain([Plain('\n'.join(lines))]))

    async def cmd_log(self, event: AstrMessageEvent):
        log_path = WD_DIR / 'watchdog.log'
        if not log_path.exists():
            await event.send(MessageChain([Plain('[守护管家] 暂无日志')]))
            return
        text = await asyncio.to_thread(log_path.read_text, 'utf-8', 'replace')
        tail = '\n'.join(text.strip().splitlines()[-15:])
        await event.send(MessageChain([Plain(f'[守护日志]\n{tail[-1800:]}')]))

    async def cmd_qrcode(self, event: AstrMessageEvent):
        qr_path = WD_DIR / 'qr_plugin.png'
        if qr_path.exists():
            qr_path.unlink()
        await self.dkr(['cp', f'{self._container()}:/app/napcat/cache/qrcode.png', str(qr_path)], 30)
        if not qr_path.exists():
            await event.send(MessageChain([Plain('[守护管家] 容器内暂无二维码(可能QQ已在线或容器未运行)')]))
            return
        age = time.time() - qr_path.stat().st_mtime
        note = '二维码如下' if age < 180 else f'注意: 该码已生成 {int(age // 60)} 分钟,可能已过期'
        await event.send(MessageChain([Plain(f'[守护管家] {note}'), Image.fromFileSystem(str(qr_path))]))

    async def _wipe_qq_data(self) -> int:
        """清空 QQ 登录数据（保留 NapCat 配置），进回收站；返回清理项数"""
        container = self._container()
        await self.dkr(['stop', '-t', '30', container], 120)
        await asyncio.sleep(3)
        qq_dir = BASE_DIR / 'napcat' / 'data' / 'qq'
        removed = 0
        if qq_dir.exists():
            ps_parts = ["Add-Type -AssemblyName Microsoft.VisualBasic"]
            for item in await asyncio.to_thread(lambda: list(qq_dir.iterdir())):
                if item.name == 'NapCat':
                    continue
                p = str(item).replace("'", "''")
                if item.is_dir():
                    ps_parts.append(
                        f"[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory('{p}', 'OnlyErrorDialogs', 'SendToRecycleBin')")
                else:
                    ps_parts.append(
                        f"[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('{p}', 'OnlyErrorDialogs', 'SendToRecycleBin')")
                removed += 1
            if removed:
                await asyncio.to_thread(run_ps, '; '.join(ps_parts), 120)
        return removed

    async def _restore_backup(self) -> bool:
        """从备份恢复会话数据(global)，返回是否恢复成功"""
        bak = BASE_DIR / 'napcat' / 'backup' / 'session'
        if not bak.exists():
            return False
        try:
            def _copy():
                import shutil
                dst = BASE_DIR / 'napcat' / 'data' / 'qq' / 'global'
                shutil.copytree(bak, dst, dirs_exist_ok=True)
                return dst.exists()
            return await asyncio.to_thread(_copy)
        except Exception as e:
            logger.warning(f'[guardian] 恢复备份失败: {e}')
            return False

    async def cmd_restore(self, event: AstrMessageEvent):
        """恢复登录：清数据 + 恢复会话备份 + 起容器尝试快速登录（免扫码）"""
        await event.send(MessageChain([Plain('[守护管家] 恢复登录: 停容器 -> 清数据 -> 恢复会话备份 -> 起容器')]))
        await self._wipe_qq_data()
        restored = await self._restore_backup()
        if not restored:
            await event.send(MessageChain([Plain('[守护管家] 无可用会话备份，请用 /守护 新码 走扫码流程')]))
            return
        await self.dkr(['start', self._container()], 90)
        await event.send(MessageChain([Plain('[守护管家] 已恢复备份并启动容器，等待快速登录（约1-2分钟）...')]))
        ok = False
        for _ in range(20):
            await asyncio.sleep(9)
            log = await self.dkr(['logs', self._container(), '--tail', '60'], 45)
            if ('| 发送 ->' in log) or ('| 接收 <-' in log):
                ok = True
                break
            if '二维码已保存' in log:
                await event.send(MessageChain([Plain('[守护管家] 备份票据已失效，需扫码。二维码马上发你')]))
                await self.cmd_qrcode(event)
                return
        if ok:
            await event.send(MessageChain([Plain('[守护管家] ✅ 恢复成功，QQ 已免扫码登录上线')]))
        else:
            await event.send(MessageChain([Plain('[守护管家] 未检测到消息流，请稍后用 /守护 状态 查看')]))

    async def cmd_newcode(self, event: AstrMessageEvent):
        container = self._container()
        await event.send(MessageChain([Plain('[守护管家] 开始出新码: 优雅停容器 -> 清登录数据 -> 重启')]))
        await self._wipe_qq_data()
        await self.dkr(['start', container], 90)
        await event.send(MessageChain([Plain('[守护管家] 已清理数据并启动容器,等待新二维码...')]))
        qr_ok = False
        for _ in range(15):
            await asyncio.sleep(6)
            log = await self.dkr(['logs', container, '--tail', '50'], 45)
            if '二维码已保存' in log:
                qr_ok = True
                break
        if not qr_ok:
            await event.send(MessageChain([Plain('[守护管家] 90秒内未见新二维码,请稍后用 /守护 二维码 再取')]))
            return
        await self.cmd_qrcode(event)

    async def terminate(self):
        pass
