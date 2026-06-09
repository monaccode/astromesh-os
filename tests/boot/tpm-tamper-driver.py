#!/usr/bin/env python3
"""Boot the disk under QEMU+swtpm with an APPENDED kernel-cmdline token (via the systemd-boot
menu editor) so systemd-stub measures a different PCR 11 -> the sealed secret must NOT unseal.
Waits for the [seal] TAMPER-BLOCKED marker; fails if UNSEAL OK appears instead.

Usage: tpm-tamper-driver.py <disk.qcow2> <ovmf_code> <ovmf_vars> <swtpm_sock> <token>
"""
import sys
import pexpect

if len(sys.argv) != 6:
    print("usage: tpm-tamper-driver.py <disk> <ovmf_code> <ovmf_vars> <swtpm_sock> <token>")
    sys.exit(2)
disk, ovmf_code, ovmf_vars, swtpm_sock, token = sys.argv[1:6]

qemu = (
    "qemu-system-x86_64 -machine q35 -m 2048 -smp 2 -nographic "
    f"-drive if=pflash,format=raw,unit=0,readonly=on,file={ovmf_code} "
    f"-drive if=pflash,format=raw,unit=1,file={ovmf_vars} "
    f"-drive file={disk},format=qcow2,if=virtio "
    f"-chardev socket,id=chrtpm,path={swtpm_sock} -tpmdev emulator,id=tpm0,chardev=chrtpm "
    "-device tpm-tis,tpmdev=tpm0 "
    "-nic user,model=virtio-net-pci"
)
child = pexpect.spawn(qemu, encoding="utf-8", timeout=300)
child.logfile = sys.stdout

try:
    # systemd-boot menu: stop the countdown (space), edit the selected entry (e), append the
    # token (cursor at start, trims a leading space -> wrap in both spaces), boot (Enter).
    child.expect(r"Boot in \d+ s", timeout=60)
    child.send(" ")
    child.send("e")
    child.expect(r"console=ttyS0|root=", timeout=20)
    child.send(f" {token} ")
    child.send("\r")

    # The unseal service must REFUSE to unseal under the tampered PCR 11.
    i = child.expect([r"\[seal\] TAMPER-BLOCKED OK", r"\[seal\] UNSEAL OK"], timeout=240)
    if i == 0:
        print("\n[tpm-tamper-driver] PASS: secret withheld under tampered boot")
        rc = 0
    else:
        print("\n[tpm-tamper-driver] FAIL: secret UNSEALED under tampered boot (PCR binding not enforced)")
        rc = 1
except (pexpect.TIMEOUT, pexpect.EOF) as e:
    print(f"\n[tpm-tamper-driver] FAIL: {type(e).__name__}\n----- buffer -----\n{child.before}")
    rc = 1
finally:
    child.close(force=True)

sys.exit(rc)
