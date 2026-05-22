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
    case "$DISTRO_ID:$DISTRO_VERSION" in
        debian:13|debian:12) return 0 ;;
        ubuntu:24.04|ubuntu:24.10|ubuntu:25.04|ubuntu:25.10|ubuntu:26.04) return 0 ;;
        raspbian:12|raspbian:13) return 0 ;;
        *) return 1 ;;
    esac
}
