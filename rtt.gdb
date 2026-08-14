target extended-remote :3333

file ./zig-out/firmware/sycl-os-kernel.elf

set remote memory-read-packet-size 1024
set remote memory-write-packet-size 1024

define rtt-init
    set $rtt_addr = &RttControlBlock
    eval "monitor rtt setup 0x%x 0x40 \"SEGGER RTT\"", $rtt_addr
    monitor rtt start
    monitor rtt server start 10345 0
end

monitor reset halt
load
break drivers.rtt.rtt_initialized
run
rtt-init
delete 1
continue