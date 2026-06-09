# Declarative machine-config (Fase 4.1)

The node's role (runtime profile) and identity come from a declarative machine-config injected at
boot via a systemd **SMBIOS credential** — no SSH, no baked role. The same disk boots as any of the
7 runtime roles (`full`, `gateway`, `inference`, `worker`, `mesh-gateway`, `mesh-inference`,
`mesh-worker`).

## Format

A small YAML document delivered as the credential `astromesh.machine_config`:

    profile: worker      # one of the 7 runtime roles (validated; unknown -> the node keeps the default)
    node_id: node-a      # stable node identity (the mesh, 4.2, reads /var/lib/astromesh/node-id)
    hostname: node-a     # optional; defaults to node_id

## Injection

systemd reads the credential from `$CREDENTIALS_DIRECTORY`. Inject it as a **binary (base64)**
credential to avoid escaping issues:

    b64=$(printf 'profile: worker\nnode_id: node-a\n' | base64 -w0)
    qemu ... -smbios type=11,value=io.systemd.credential.binary:astromesh.machine_config=$b64

Cloud platforms inject the same credential by their own means (SMBIOS OEM strings, instance metadata
mapped to systemd credentials, etc.). Absent any machine-config, the node falls back to the baked
default config and still serves `/v1/health` — fail-soft, not fail-closed (an unconfigured node is a
degraded node, not a broken boot).

## Mesh membership (peers, mTLS, TPM attestation) is **not** here — that is Fase 4.2.
