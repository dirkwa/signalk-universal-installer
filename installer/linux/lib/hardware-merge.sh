#!/usr/bin/env bash
# Shared merge that carries operator hardware toggles forward across a
# re-detect. Sourced by install.sh (section "Hardware detection") and by
# scripts/test/check-hardware-merge.sh so the production filter and its
# test can never drift apart.
#
# detect-hardware.sh always re-emits fresh state — opt-in classes at
# enabled=false, audio at its /dev/snd-derived default — and the installer
# merges the operator's prior toggles back over the fresh detection so a
# documented re-run (`curl … | bash`) can't silently flip passthrough on/off.
#
# audio is opt-*out* (enabled by default when present), unlike bluetooth/gpio
# which are opt-in. It needs an explicit has() check, not `//`: jq's `//`
# treats a stored `false` as empty and would fall through to the fresh
# enabled-by-default `true`, silently re-enabling an operator opt-out. So:
# carry the prior value verbatim when present, else keep the fresh default.
# (bluetooth/gpio tolerate `//` only because their fresh default is already
# false, so `false // false` is harmless there.)
#
# onboardSerial (HALPI2 RS-485, docs/halpi2.md) is opt-out like audio and
# is re-emitted by every detection, so only the per-device `enabled` is
# carried, matched by `device`. `board` is a hardware fact, not a toggle:
# the fresh detection always wins and nothing is carried.

# hardware_merge <old.json> <fresh.json> — prints merged JSON to stdout.
# Requires jq; callers guard on `command -v jq` before invoking.
hardware_merge() {
    jq -s '
        .[0] as $old
        | .[1]
        | .bluetooth.enabled = ($old.bluetooth.enabled // false)
        | .gpio.enabled = ($old.gpio.enabled // false)
        | .audio.enabled = (if $old | has("audio")
                            then $old.audio.enabled
                            else .audio.enabled end)
        | if $old.socketcanCandidate != null
          then .socketcanCandidate = $old.socketcanCandidate
          else . end
        | if has("onboardSerial")
          then .onboardSerial |= map(
                 . as $dev
                 | ([($old.onboardSerial // [])[] | select(.device == $dev.device)] | first) as $prev
                 | if $prev == null then $dev else $dev + {enabled: $prev.enabled} end)
          else . end
    ' "$1" "$2"
}
