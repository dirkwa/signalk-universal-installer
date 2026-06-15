#!/usr/bin/env bash
# Source me. Detects distribution, version, codename, arch into env vars.

detect_os() {
    DISTRO_ID=""
    DISTRO_VERSION=""
    DISTRO_CODENAME=""
    DISTRO_PRETTY=""
    DISTRO_VARIANT=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-}"
        DISTRO_CODENAME="${VERSION_CODENAME:-}"
        DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID $DISTRO_VERSION}"
        # VARIANT_ID distinguishes Fedora CoreOS ("coreos") — the immutable,
        # rpm-ostree image podman machine runs — from Workstation/Server.
        DISTRO_VARIANT="${VARIANT_ID:-}"
    fi
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) ARCH_NORM=amd64 ;;
        aarch64|arm64) ARCH_NORM=arm64 ;;
        armv7l|armv6l) ARCH_NORM=armv7 ;;
        *) ARCH_NORM="$ARCH" ;;
    esac
    export DISTRO_ID DISTRO_VERSION DISTRO_CODENAME DISTRO_VARIANT DISTRO_PRETTY ARCH ARCH_NORM
}

is_pi() {
    [[ -r /proc/device-tree/model ]] && grep -qi 'raspberry pi' /proc/device-tree/model
}

is_supported_distro() {
    # Tested targets, all of which ship podman >= 5.3 — the floor the engine
    # Quadlets need ([Quadlet] DefaultDependencies=false, added in podman 5.3.0):
    #
    #   * Debian 13 / trixie and Raspberry Pi OS (raspbian) trixie — podman 5.4.x.
    #     Gated on codename, not VERSION_ID, so trixie point releases (13.1, …)
    #     and Pi OS's own versioning both match.
    #   * Ubuntu/Kubuntu 25.04 (plucky, podman 5.4.1), 25.10 (questing, 5.4.2)
    #     and 26.04 (resolute, 5.7.0). Gated on VERSION_ID >= 25.04 so the whole
    #     25.x line and later qualify; the EOL 24.x line (oracular 24.10 = podman
    #     5.0.3, noble 24.04 = 4.9.3) is excluded because its archive podman is
    #     below the 5.3 floor. Ubuntu uses ID=ubuntu across all flavours (Kubuntu,
    #     Xubuntu, …), so this one branch covers them all.
    #
    # Fedora is supported because it's what `podman machine` runs (the VM the
    # macOS and Windows installers use). Fedora ships podman 5.x, so the
    # podman >= 5.3 floor is satisfied. This covers both Fedora CoreOS
    # (VARIANT_ID=coreos — the immutable podman-machine image) and
    # Workstation/Server; the installer's pkg_install() handles the
    # rpm-ostree-can't-install-at-runtime case for CoreOS.
    #
    # Other distros are not blocked here — they fall through to a "untested,
    # continuing" warning in preflight — but the post-install podman version gate
    # in install.sh fails loudly on anything shipping podman < 5.3. Debian 12
    # (bookworm, podman 4.3.1, no Quadlet) is the one hard block, handled in
    # preflight's check_distro_blocked.
    case "$DISTRO_ID" in
        debian | raspbian)
            [[ "$DISTRO_CODENAME" == "trixie" ]] && return 0
            ;;
        fedora)
            return 0
            ;;
        ubuntu)
            # VERSION_ID is "YY.MM" (e.g. 25.04, 26.04). Compare numerically:
            # major*100 + minor >= 2504. sort -V would mis-rank 26.04 vs 25.10
            # on the zero-padded minor, so do the arithmetic explicitly. 10# forces
            # base-10 so a "04" minor isn't read as (invalid) octal.
            local major minor
            major="${DISTRO_VERSION%%.*}"
            minor="${DISTRO_VERSION#*.}"
            if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
                (( major * 100 + 10#$minor >= 2504 )) && return 0
            fi
            ;;
    esac
    return 1
}
