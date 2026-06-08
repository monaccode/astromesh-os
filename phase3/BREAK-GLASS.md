# Break-glass — emergency console recovery (Fase 3.1)

Astromesh OS has **no interactive login by default**: getty is masked and SSH is not
installed. Recovery for a broken node is a deliberate, audited, **console-only** action.

## When to use
A node that cannot reach the control plane and cannot be diagnosed remotely, when
re-imaging (the preferred cattle action) is not yet an option.

## Procedure
1. Attach to the node's **serial/physical console** (cloud serial console, or local).
2. Reboot the node. When the **systemd-boot** menu appears, press a key to stop the
   countdown.
3. Select the Astromesh OS entry and press **`e`** to edit its kernel command line.
4. Append: ` systemd.unit=rescue.target` (or `systemd.unit=emergency.target` for a more
   minimal environment) and press **Enter** to boot.
5. At the `sulogin` prompt, enter the **break-glass credential** (the password whose hash
   was provisioned via `ASTROMESH_BREAKGLASS_HASH`). You get a root shell for diagnosis.

The root filesystem is dm-verity **read-only**: this shell is for diagnosis, not for
editing the root. Writable state lives under `/var`.

## Security notes
- If no break-glass hash was provisioned, root is locked and `sulogin` will **not** open a
  shell — recovery is re-imaging only.
- Every break-glass entry is visible in the journal/serial console (audited).
- **Roadmap:** 3.3 seals the credential to the TPM (unsealed only under an intact boot);
  3.6 (Secure Boot) locks cmdline editing and moves the trigger to a dedicated measured
  boot entry.
