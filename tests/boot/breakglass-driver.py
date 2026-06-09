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

child = pexpect.spawn(qemu, encoding="utf-8", timeout=300)  # generous for TCG (no KVM) in CI
child.logfile = sys.stdout

try:
    # 1. systemd-boot menu: a "Boot in N s." countdown over the default-selected entry
    #    ("Debian GNU/Linux 13 ..."). Stop the countdown with SPACE — a benign key that
    #    neither boots (Enter does) nor moves the selection (arrows do, off our entry).
    child.expect(r"Boot in \d+ s", timeout=60)
    child.send(" ")

    # 2. Edit the selected entry's kernel cmdline. After 'e', systemd-boot echoes the current
    #    cmdline (which contains console=ttyS0 and root=) for line-editing.
    child.send("e")
    child.expect(r"console=ttyS0|root=", timeout=20)

    # 3. Insert the rescue unit and boot with Enter. systemd-boot's editor places the cursor
    #    at the START of the cmdline and trims a leading space, so wrap the token in BOTH a
    #    leading and a trailing space — that guarantees a separator whether it lands before
    #    `roothash=` (cursor at start) or after the last arg (cursor at end). Spaces are harmless.
    child.send(" systemd.unit=rescue.target ")
    child.send("\r")

    # 4. rescue.target runs sulogin, which prompts for the root password (the break-glass
    #    credential) because root now has a hash.
    child.expect(r"(?i)give root password|root password|press enter for maintenance|password:", timeout=240)
    child.sendline(password)

    # 5. Root maintenance shell -> prove uid=0.
    child.expect(r"[#$]", timeout=120)
    child.sendline("id")
    child.expect(r"uid=0\(root\)", timeout=30)
    print("\n[breakglass-driver] PASS: root shell via break-glass (uid=0)")
    rc = 0
except (pexpect.TIMEOUT, pexpect.EOF) as e:
    # Print the buffer accumulated before the failed match — that's the diagnostic.
    print(f"\n[breakglass-driver] FAIL: {type(e).__name__}\n----- buffer before match -----\n{child.before}")
    rc = 1
finally:
    # Always reap the QEMU child; otherwise a failed match orphans a running qemu that keeps
    # the qcow2 write-locked and wrecks the next run.
    child.close(force=True)

sys.exit(rc)
