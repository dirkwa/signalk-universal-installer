# Recovery

Placeholder. Real content lands in Phase 5 (doctor) and Phase 7 (recovery script).

Will cover:

- The Doctor Console (`:3004`) — read-only probes + the "Recover" button.
- The host-resident recovery script (`~/.local/bin/signalk-recovery`) — works with zero containers running, only needs SSH.
- Last-known-good Quadlet snapshots in `~/.signalk-doctor/snapshots/`.
- Resetting failed systemd units (`systemctl --user reset-failed signalk-*.service`).
- What to do if the updater itself is bricked (use the doctor; if the doctor is also down, use the bash script).
