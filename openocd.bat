@echo on
"%USERPROFILE%\.pico-sdk\openocd\0.12.0+dev\openocd.exe" -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed 5000"
@echo off
color 40
title "OpenOCD Exited"
