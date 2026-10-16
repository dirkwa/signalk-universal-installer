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
# audio and input are opt-*out* (enabled by default when present), unlike
# bluetooth/gpio which are opt-in. They need an explicit has() check, not
# `//`: jq's `//`
# treats a stored `false` as empty and would fall through to the fresh
# enabled-by-default `true`, silently re-enabling an operator opt-out. So:
# carry the prior value verbatim when present, else keep the fresh default.
# (bluetooth/gpio tolerate `//` only because their fresh default is already
# false, so `false // false` is harmless there.)
#
# input carries the same shape and the same trap; older hardware.json files
# predate the class entirely, hence the has() check rather than a default.
#
# onboardSerial (HALPI2 RS-485, docs/halpi2.md) is opt-out like audio and
# is re-emitted by every detection, so only the per-device `enabled` is
# carried, matched by `device`. `board` is a hardware fact, not a toggle:
# the fresh detection always wins and nothing is carried.
#
# USB serial devices (matched by `byId`) and CAN interfaces (matched by
# `interface`) carry their per-device `enabled` the same way. Before this,
# every re-detect set each USB serial device back to the fresh default
# (enabled), so an operator could not keep one switched off: in issue #309 a
# touchscreen's own serial port, set to `enabled: false` because it
# disappears with the monitor, came back on at the next `signalk hardware
# rescan` or installer run. A device the operator switched off is also kept
# when the fresh detection does not see it (unplugged, or a monitor that is
# off), so the setting survives a re-detect made while it is absent. A
# missing device that was enabled is dropped, as before: the fresh detection
# decides which devices exist.

# hardware_merge <old.json> <fresh.json> — prints merged JSON to stdout.
# Requires jq; callers guard on `command -v jq` before invoking.
hardware_merge() {
    jq -s '
        def carry_toggles($prev; key):
            . as $fresh
            | map(. as $dev
                  | ([$prev[] | select(key == ($dev | key))] | first) as $p
                  | if $p == null or ($p | has("enabled") | not)
                    then $dev else $dev + {enabled: $p.enabled} end)
              + [ $prev[] | select(.enabled == false)
                  | . as $p
                  | select(any($fresh[]; key == ($p | key)) | not) ];
        .[0] as $old
        | .[1]
        | .bluetooth.enabled = ($old.bluetooth.enabled // false)
        | .gpio.enabled = ($old.gpio.enabled // false)
        | .audio.enabled = (if $old | has("audio")
                            then $old.audio.enabled
                            else .audio.enabled end)
        | .input.enabled = (if $old | has("input")
                            then $old.input.enabled
                            else .input.enabled end)
        | if $old.socketcanCandidate != null
          then .socketcanCandidate = $old.socketcanCandidate
          else . end
        | if has("serial")
          then .serial |= carry_toggles(($old.serial // []); .byId)
          else . end
        | if has("can")
          then .can |= carry_toggles(($old.can // []); .interface)
          else . end
        | if has("onboardSerial")
          then .onboardSerial |= map(
                 . as $dev
                 | ([($old.onboardSerial // [])[] | select(.device == $dev.device)] | first) as $prev
                 | if $prev == null or ($prev | has("enabled") | not)
                   then $dev else $dev + {enabled: $prev.enabled} end)
          else . end
    ' "$1" "$2"
}
