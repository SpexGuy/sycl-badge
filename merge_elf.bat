set OBJCOPY="%USERPROFILE%\.pico-sdk\toolchain\15_2_Rel1\bin\arm-none-eabi-objcopy.exe"

%OBJCOPY% -O ihex %~dp0zig-out\firmware\sycl-os-kernel.elf sycl-os-kernel.hex
%OBJCOPY% -O ihex %~dp0zig-out\firmware\%1.elf %1.hex
sed '$d' sycl-os-kernel.hex > %1-os.hex
cat %1.hex >> %1-os.hex
%OBJCOPY% -I ihex -O elf32-littlearm %1-os.hex %~dp0zig-out\firmware\%1-os.elf

del %1-os.hex %1.hex sycl-os-kernel.hex
