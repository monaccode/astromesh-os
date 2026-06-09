#!/usr/bin/env bash
# Fase 4.1 astromeshd launcher. Picks the config dir: the machine-config-rendered /run/astromesh/config
# when it carries a runtime.yaml (a machine-config was applied this boot), else the baked, read-only
# /etc/astromesh (today's behavior — used when no machine-config was injected). Keeps boots without a
# machine-config byte-identical to the pre-4.1 ExecStart.
set -u
CFG=/etc/astromesh
if [ -f /run/astromesh/config/runtime.yaml ]; then
    CFG=/run/astromesh/config
fi
exec /opt/astromesh/venv/bin/astromeshd --config "${CFG}/"
