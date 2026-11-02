#!/bin/bash
# Compares the versions of everything relevant to the H510-PRO fix against
# the environment recorded in tested-environment.conf.
#
#   ./check-environment.sh            show current vs. tested, flag differences
#   ./check-environment.sh --update   record the current environment as tested
#
# Exit status: 0 if identical to the tested environment, 1 if anything differs.

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$DIR/tested-environment.conf"

pkgver() {
    if command -v rpm >/dev/null 2>&1; then
        rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "$1" 2>/dev/null | head -1
    elif command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Version}\n' "$1" 2>/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Q "$1" 2>/dev/null | awk '{print $2}'
    fi
}

collect() {
    CUR_distro=$(. /etc/os-release && echo "$PRETTY_NAME")
    CUR_kernel=$(uname -r)
    CUR_pipewire=$(pipewire --version 2>/dev/null | awk '/Compiled|Linked/ {print $NF; exit}')
    CUR_wireplumber=$(wireplumber --version 2>/dev/null | awk '/Linked/ {print $NF; exit}')
    CUR_pipewire_alsa=$(pkgver pipewire-alsa)
    CUR_pipewire_pulseaudio=$(pkgver pipewire-pulseaudio)
    CUR_alsa_lib=$(pkgver alsa-lib || true)
    [ -n "$CUR_alsa_lib" ] || CUR_alsa_lib=$(pkgver libasound2)
    CUR_alsa_utils=$(amixer --version 2>/dev/null | awk '{print $NF}')
    CUR_systemd=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
    CUR_gnome_shell=$(pkgver gnome-shell)
    CUR_dongle_bcdDevice=$(lsusb -d 040b:0897 -v 2>/dev/null | awk '/bcdDevice/ {print $2}')
}

KEYS="distro kernel pipewire wireplumber pipewire_alsa pipewire_pulseaudio alsa_lib alsa_utils systemd gnome_shell dongle_bcdDevice"

collect

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Environment in which h510-pro-audio-fix.sh was last verified working"
        echo "# (both channels audible, volume control working, after dongle replug)."
        echo "# Compare with the current system using: ./check-environment.sh"
        echo "# After re-testing on a new environment, update with: ./check-environment.sh --update"
        echo "tested_on=$(date +%F)"
        for k in $KEYS; do v="CUR_$k"; echo "$k=\"${!v}\""; done
    } > "$CONF"
    echo "Recorded current environment in $CONF"
    exit 0
fi

[ -f "$CONF" ] || { echo "Missing $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

diffs=0
printf '%-22s %-38s %-38s\n' COMPONENT TESTED CURRENT
echo "tested on: $tested_on"
for k in $KEYS; do
    t="${!k:-?}"; v="CUR_$k"; c="${!v:-?}"
    if [ "$t" = "$c" ]; then mark=" "; else mark="*"; diffs=$((diffs+1)); fi
    printf '%s %-20s %-38s %-38s\n' "$mark" "$k" "$t" "$c"
done
echo
if [ "$diffs" -eq 0 ]; then
    echo "Environment identical to the tested one."
else
    echo "$diffs component(s) differ (*). Re-test the fix (replug dongle, check both channels"
    echo "and volume), then run: ./check-environment.sh --update"
    exit 1
fi
