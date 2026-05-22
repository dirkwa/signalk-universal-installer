#!/usr/bin/env bash
# Source me. Provides info/warn/error/success/die helpers with ANSI colour
# when stdout is a TTY, plain text otherwise. Adapted from the legacy
# signalk-universal-installer-v1 installer.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_GRAY=$'\033[0;90m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_GRAY='' C_BOLD='' C_RESET=''
fi

info()    { printf '%s[i]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()      { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%s[ERR]%s %s\n' "$C_RED"  "$C_RESET" "$*" >&2; }
die()     { err "$@"; exit 1; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
