#!/usr/bin/env bash
# Source me. Detects distribution, version, codename, arch into env vars.

detect_os() {
    DISTRO_ID=""
    DISTRO_VERSION=""
    DISTRO_CODENAME=""
    DISTRO_PRETTY=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION}"
    fi
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) ARCH_NORM=amd64 ;;
        aarch64|arm64) ARCH_NORM=arm64 ;;
        armv7l|armv6l) ARCH_NORM=armv7 ;;
        *) ARCH_NORM="$ARCH" ;;
    esac
    export DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_PRETTY ARCH ARCH_NORM
}

is_pi() {
    [[ -r /proc/device-tree/model ]] && grep -qi 'raspberry pi' /proc/device-tree/model
}

is_supported_distro() {
    # The only tested targets are trixie-based: Debian 13 and Raspberry Pi OS
    # (raspbian) 13. Both ship podman 5.4.x, which satisfies the >= 5.3 floor
    # the engine Quadlets need ([Quadlet] DefaultDependencies=false). Other
    # distros are not blocked — they fall through to a "untested, continuing"
    # warning in preflight — but the post-install podman version gate in
    # install.sh fails loudly on anything that ships podman < 5.3 (e.g. Ubuntu
    # 24.04 = 4.9.3). Debian 12 (bookworm, podman 4.3.1, no Quadlet) is the one
    # hard block, handled separately in preflight's check_distro_blocked.
    case "$DISTRO_ID:$DISTRO_VERSION" in
        debian:13) return 0 ;;
        raspbian:13) return 0 ;;
        *) return 1 ;;
    esac
}
