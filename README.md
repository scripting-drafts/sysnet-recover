# sysnet-recover

Offline-safe system and network diagnosis/recovery for Linux (systemd + NetworkManager).

    sysnet-recover.sh diagnose
    sysnet-recover.sh diagnose --export DIR
    sysnet-recover.sh recover --dry-run
    sudo sysnet-recover.sh recover

Diagnosis is read-only. Recovery is conservative and never downloads, installs, changes the firewall, kills processes, or deletes package caches. Local probes only; `--no-probe` disables gateway ICMP.
