#!/usr/bin/env python3
"""Drive the QEMU serial console for the Fase 3.1 break-glass gate.

Boots the given disk image under QEMU (serial on stdio), interrupts the systemd-boot menu,
appends `systemd.unit=rescue.target` to the entry's cmdline, then at the sulogin prompt
sends the break-glass credential and asserts a root shell (`id` -> uid=0). Exits 0 on
success, non-zero otherwise.

Usage: breakglass-driver.py <disk.qcow2> <ovmf_code> <ovmf_vars> <password>
"""
import sys
import pexpect

if len(sys.argv) != 5:
    print("usage: breakglass-driver.py <disk.qcow2> <ovmf_code> <ovmf_vars> <password>")
    sys.exit(2)

disk, ovmf_code, ovmf_vars, password = sys.argv[1:5]

qemu = (
    "qemu-system-x86_64 -machine q35 -m 2048 -smp 2 -nographic "
    f"-drive if=pflash,format=raw,unit=0,readonly=on,file={ovmf_code} "
    f"-drive if=pflash,format=raw,unit=1,file={ovmf_vars} "
    f"-drive file={disk},format=qcow2,if=virtio "
    "-nic user,model=virtio-net-pci"
)

child = pexpect.spawn(qemu, encoding="utf-8", timeout=180)
child.logfile = sys.stdout

# 1. Catch the systemd-boot menu and enter the editor. systemd-boot prints the entry
#    title and waits for the timeout; any key stops the countdown.
child.expect(r"Astromesh|systemd-boot|Boot in")   # menu is up
child.send(" ")                                    # stop countdown
child.sendline("")                                 # ensure the entry is selected
child.send("e")                                    # edit cmdline of the selected entry
child.sendline(" systemd.unit=rescue.target")      # append + Enter boots

# 2. sulogin prompt on rescue. Accept either the maintenance hint or the password prompt.
child.expect(r"Press Enter for maintenance|Give root password|root password|Password:")
child.sendline(password)

# 3. Shell prompt -> prove root.
child.expect(r"#|\$")
child.sendline("id")
child.expect(r"uid=0\(root\)")
print("\n[breakglass-driver] PASS: root shell via break-glass (uid=0)")
sys.exit(0)
