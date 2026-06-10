# Mesh cluster CA + IPsec (Fase 4.2)

`ca.crt` / `ca.key` are a **TEST** EC cluster CA. On first boot each node issues itself a cert
`CN=<node_id>` (SAN = its mesh IP) signed by this CA and seals the private key to the TPM (PCR 11+12,
reusing Fase 3.3). strongSwan (IKEv2) then requires a peer cert that chains to `ca.crt` before an
ESP SA is established — so the runtime's `/v1/mesh` is reachable only between authenticated nodes.

**INSECURE — dev/CI only.** `ca.key` is committed so the gate is self-contained. A production fleet
must keep the CA key **offline** (KMS/HSM) and issue node certs out-of-band (after remote TPM
attestation — Fase 4.2b), never bake the CA key into the image.

Regenerate:

    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -sha256 \
        -subj "/CN=Astromesh OS cluster CA - TEST INSECURE dev-only/" \
        -keyout ca.key -out ca.crt \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
