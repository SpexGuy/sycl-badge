@echo off
start "OpenOCD GDB Server" cmd /k "%~dp0openocd.bat"
call "%~dp0gdb.bat"
