# AriaDeployd

目标机（`192.168.1.150`，Windows）上的**部署守护进程**：起一个内网 HTTP 小服务，
让本机通过 `curl` 就能上传 exe 到指定目录、停/启/重启进程，不用远程桌面手点。

## 为什么不用 SSH

目标机只开了 `3389`（远程桌面）/ `445`（SMB）/ `80`（NasCab），
`22`（OpenSSH）和 `5985`（WinRM）都没开，`Add-WindowsCapability` 装 OpenSSH 又报
`0x800f0950`（系统取不到更新源）。所以干脆自己起一个 988 KB 的小服务，一次部署、长期可用。

## 一次性部署（在目标机上做）

1. 把 `dist\deployd.exe` 拷到目标机，例如 `C:\aria-server\deployd.exe`
2. 双击运行（或加到启动项）。首次运行会生成 `deployd.json`：

```json
{
  "port": 8899,
  "token": "tk1794xxxxxxxxx",
  "roots": ["C:\\aria-server"]
}
```

3. 改 `roots` 为允许操作的目录（白名单，防误删整个盘），**token 抄下来**，重启 exe
4. 防火墙放行 8899（或只放行本机 IP）：

```powershell
New-NetFirewallRule -Name deployd -DisplayName 'deployd' -Enabled True `
  -Direction Inbound -Protocol TCP -Action Allow -LocalPort 8899
```

## 日常部署（在本机跑）

```powershell
# 推送 + 重启 + 健康检查
.\deploy.ps1 -Host 192.168.1.150 -Token <token> `
             -Exe d:\CLeno\Aria\server\dist\server.exe `
             -Dest C:\aria-server\server.exe `
             -Name server.exe -Args "5767 0.0.0.0 4" `
             -HealthUrl http://192.168.1.150:5767/health

.\deploy.ps1 ... -Status      # 看进程
.\deploy.ps1 ... -OnlyStop    # 只停
.\deploy.ps1 ... -Logs -Tail 60
```

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活（免 token） |
| GET | `/status` | 进程状态（`X-Name`） |
| POST | `/stop` | 按名杀进程（`X-Name`） |
| POST | `/start` | 后台启动（`X-Exe`、`X-Args`） |
| POST | `/upload` | body=字节；`X-To` 目标、`X-Part` 分块、`X-Name` 顺带重启 |
| POST | `/merge` | `X-To`、`X-N`：把 `.part0..N-1` 拼回目标 |
| GET | `/logs` | `X-File`、`X-N` |

参数一律走 **header**（`X-To` 等）：Windows 路径含 `\` 和 `:`，塞进 query 要 URL 编码，拼不好就被截断。

## 两个必须知道的坑（都是实测踩出来的）

**1. 用单线程 `http.serve`，不是 `serveWorkers`**

handler 在 worker 线程里跑时，`Sys.exec` / `Sys.findProcess` 这类依赖主线程 Win32 库句柄的调用
会抛「库对象已释放」，整个 worker 被打断 —— 表现为「先 status 正常，随后上传 500，之后全 500」。
deployd 只服务一个人，单线程完全够，handler 在主线程 ⇒ Sys 全部可用。

**2. 上传必须分块（≤1MB）**

同一份 4.3 MB 的 exe，单请求传过来服务端**收不全**（curl 显示 `closing connection`，
服务端日志无异常）；而 4.4 MB 的全零文件反而能过 —— 不可靠。改成 900 KB 一块、
各存 `<dest>.partN`、最后 `/merge` 拼接，稳定通过（实测 4413428 字节完全一致）。

同时 `Sys.findProcess` 是**子串**匹配（`server.exe` 会匹配到 `dumate-main-server.exe`），
所以进程判断一律用 `tasklist` + 精确同名比对，`stop` 才不会被误杀别人的进程。

## 进程内幕

- 停：`taskkill /F /IM <name>`（按精确同名先数一遍，杀完再数一遍得出实际数量）
- 启：`cmd /c start "" /b cmd /c "<exe>" <args> >> logs\<name>.<日期>.log 2>&1`
- 上传被占用：先 `taskkill` 再写，超时 500ms 重试一次
- 备份：覆盖前把旧文件存成 `<dest>.bak`（分块上传不备份）

## 启动参数（别自己编）

目标机上服务是 **127.0.0.1:8090**（服务端默认值），外网 https://s4.v100.vip:5767 由 **NasCab** 反代过来：5767 -> 127.0.0.1:8090。

所以 -StartArgs 要留空：

```powershell
-StartArgs ''
```n
踩过的坑：用 -StartArgs '5767 0.0.0.0 4' 启动，服务真的在 5767 监听，但 NasCab 又把它转到 8090（那里没人）=> 内网 5767 通、外网全挂，表现成「deployd 启动的不通、双击启动的通」，排查了好几轮。

另两个同类坑（已修）：
- start 必须带 /d 目标exe目录，否则子进程继承 deployd 的工作目录，服务端按相对路径找不到 data 就静默挂住（进程活着但不监听端口）；
- start 不要加 /b，否则没有控制台窗口，出问题看不到任何输出。
