# Secure Boot TEST keys (Fase 3.6)

`db.key` / `db.crt` are a **TEST** keypair used to sign the UKI + systemd-boot and to auto-enroll
Secure Boot keys in the gate's OVMF firmware. They are committed **only** so the build is
reproducible and the gate is self-contained.

**INSECURE — dev/CI only. Never use in production.** A production image must sign with a key held
in a cloud secret (KMS/HSM), never a key committed to a repo.

Regenerate:

    openssl req -new -x509 -newkey rsa:4096 -nodes -days 3650 -sha256 \
        -subj "/CN=Astromesh OS SecureBoot TEST key - INSECURE dev-only/" \
        -keyout db.key -out db.crt
