@echo off
start "OpenOCD GDB Server" cmd /k "%~dp0openocd.bat"
start "Badge GDB" cmd /k "%~dp0gdb_restart.bat"
start "Log Monitor" cmd /k "%~dp0rtt_server.exe"
