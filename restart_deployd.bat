@echo off
rem deployd 自重启：由旧 deployd 的 /start 拉起（它启动完就退出，不会自杀）
rem 等 3 秒让那条 HTTP 请求先返回，再替换文件（运行中的 exe 不能覆盖）
timeout /t 3 /nobreak >nul
taskkill /F /IM deployd.exe >nul 2>&1
timeout /t 2 /nobreak >nul
if exist "D:\AriaServer\deployd_new.exe" copy /Y "D:\AriaServer\deployd_new.exe" "D:\deployd\deployd.exe" >nul
start "" /d "D:\deployd" "D:\deployd\deployd.exe"
