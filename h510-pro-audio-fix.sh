#!/bin/bash
# h510-pro-audio-fix.sh
#
# Fixes the volume behavior of the Redragon H510-PRO headset (2.4GHz dongle)
# on Linux (PipeWire/WirePlumber/ALSA).
#
# Root cause: the dongle's volume Feature Unit is "sticky" and has an
# unreliable usable range (the kernel itself warns "Unlikely small volume
# range" and "sticky mixer values ... disabling" in dmesg). This makes the
# analog output only work near 100%, and the S/PDIF profile inherit the
# state of the same hardware register (since this dongle has no real
# separate digital DAC).
#
# Fix: lock the hardware at 100% on every connection (via udev + systemd,
# with retries to handle the USB mixer's initialization delay) and delegate
# all real volume control to software, via api.alsa.soft-mixer in
# WirePlumber. A second, user-level systemd unit re-applies the hardware
# lock shortly after WirePlumber's own session starts, since on cold boot
# WirePlumber can overwrite the hardware value during its own node
# initialization, well after the early udev-triggered fix already ran.
#
# Requirements: systemd, udev, alsa-utils (amixer), PipeWire + WirePlumber.
# Tested on Fedora; should work unmodified on any systemd + PipeWire/
# WirePlumber distro (Ubuntu 22.04+, Debian 12+, Arch, openSUSE, etc).
#
# Usage:
#   sudo ./h510-pro-audio-fix.sh              install the fix (default)
#   sudo ./h510-pro-audio-fix.sh --install     same as above, explicit
#   sudo ./h510-pro-audio-fix.sh --uninstall   remove everything this script installed
#
# Idempotent: safe to run --install multiple times.

set -euo pipefail

MODE="install"
case "${1:-}" in
    --uninstall) MODE="uninstall" ;;
    --install|"") MODE="install" ;;
    -h|--help)
        echo "Usage: sudo $0 [--install|--uninstall]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: sudo $0 [--install|--uninstall]" >&2
        exit 1
        ;;
esac

# --- Environment detection ---------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run with sudo (it writes to /etc and /usr/local/bin)." >&2
    echo "Usage: sudo $0 [--install|--uninstall]" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd (systemctl) was not found. This script relies on systemd" >&2
    echo "and udev integration, so it won't work on non-systemd distros" >&2
    echo "(e.g. Void Linux/runit, Devuan, OpenRC-based systems)." >&2
    exit 1
fi

if ! command -v udevadm >/dev/null 2>&1; then
    echo "udevadm was not found. This script requires udev." >&2
    exit 1
fi

# Determine the "real" user who invoked sudo, since WirePlumber is a
# per-user session service, not a system service.
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ]; then
    echo "Could not determine the original user (run via 'sudo', not as root directly)." >&2
    exit 1
fi

REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ -z "$REAL_HOME" ] || [ ! -d "$REAL_HOME" ]; then
    echo "Could not locate the home directory for '$REAL_USER'." >&2
    exit 1
fi

USER_ID=$(id -u "$REAL_USER" 2>/dev/null || true)
USER_SESSION_ACTIVE=false
if [ -n "$USER_ID" ] && [ -S "/run/user/$USER_ID/bus" ]; then
    USER_SESSION_ACTIVE=true
fi

run_as_user() {
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        "$@"
}

VENDOR_ID="040b"
PRODUCT_ID="0897"
CARD_MATCH_NAME="H510-PRO Wireless headset"
WIREPLUMBER_DEVICE_MATCH="alsa_card.usb-XiiSound_Technology_Corporation_H510-PRO_Wireless_headset-00"

SYSTEM_SCRIPT="/usr/local/bin/h510-volume-fix.sh"
SYSTEM_SERVICE="/etc/systemd/system/h510-volume-fix.service"
UDEV_RULE="/etc/udev/rules.d/99-h510-pro-volume.rules"
WP_CONF_DIR="$REAL_HOME/.config/wireplumber/wireplumber.conf.d"
WP_CONF_FILE="$WP_CONF_DIR/51-h510-pro-softvol.conf"
USER_SYSTEMD_DIR="$REAL_HOME/.config/systemd/user"
USER_SERVICE_FILE="$USER_SYSTEMD_DIR/h510-volume-recheck.service"

# =============================================================================
# UNINSTALL
# =============================================================================

if [ "$MODE" = "uninstall" ]; then
    echo "==> Uninstalling H510-PRO audio fix"
    echo "    Target user: $REAL_USER ($REAL_HOME)"
    echo

    echo "==> 1/5: Disabling and removing the user-level re-check service"
    if [ "$USER_SESSION_ACTIVE" = true ]; then
        run_as_user systemctl --user disable --now h510-volume-recheck.service 2>/dev/null || true
    fi
    rm -f "$USER_SERVICE_FILE"
    if [ "$USER_SESSION_ACTIVE" = true ]; then
        run_as_user systemctl --user daemon-reload || true
    fi

    echo "==> 2/5: Removing WirePlumber soft-mixer config"
    rm -f "$WP_CONF_FILE"

    echo "==> 3/5: Removing udev rule"
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules

    echo "==> 4/5: Disabling and removing the system-level service"
    systemctl disable --now h510-volume-fix.service 2>/dev/null || true
    rm -f "$SYSTEM_SERVICE"
    systemctl daemon-reload

    echo "==> 5/5: Removing the volume-fix script"
    rm -f "$SYSTEM_SCRIPT"

    echo
    echo "==> Restarting WirePlumber to drop the removed configuration..."
    if [ "$USER_SESSION_ACTIVE" = true ]; then
        run_as_user systemctl --user restart wireplumber 2>/dev/null || \
            echo "    (warning: could not restart WirePlumber automatically; run 'systemctl --user restart wireplumber' in your graphical session)"
    else
        echo "    No active graphical session detected for $REAL_USER; WirePlumber will"
        echo "    pick up the change on next login."
    fi

    echo
    echo "==> Uninstall complete."
    echo
    echo "Note: this does NOT change the current hardware volume level (PCM,0/PCM,1"
    echo "on the dongle) or your WirePlumber-saved software volume — it only removes"
    echo "the fix's automation. The dongle's original volume quirk will return."
    exit 0
fi

# =============================================================================
# INSTALL
# =============================================================================

AMIXER_BIN=$(command -v amixer || true)
if [ -z "$AMIXER_BIN" ]; then
    echo "amixer was not found in PATH. Install alsa-utils first:" >&2
    echo "  Fedora:        sudo dnf install alsa-utils" >&2
    echo "  Debian/Ubuntu: sudo apt install alsa-utils" >&2
    echo "  Arch:          sudo pacman -S alsa-utils" >&2
    exit 1
fi
echo "==> Found amixer at: $AMIXER_BIN"

# Check whether WirePlumber is actually present/running for this user.
# If not (e.g. PulseAudio-only setup, or pipewire-media-session instead of
# WirePlumber), the soft-mixer step won't have any effect, so we warn
# instead of silently doing nothing useful.
WIREPLUMBER_AVAILABLE=false
if command -v wireplumber >/dev/null 2>&1; then
    WIREPLUMBER_AVAILABLE=true
elif [ "$USER_SESSION_ACTIVE" = true ]; then
    if run_as_user systemctl --user is-enabled wireplumber >/dev/null 2>&1; then
        WIREPLUMBER_AVAILABLE=true
    fi
fi

if [ "$WIREPLUMBER_AVAILABLE" = false ]; then
    echo
    echo "WARNING: WirePlumber does not appear to be installed/active for user" >&2
    echo "'$REAL_USER'. This script's hardware-volume lock (steps 1-3) will" >&2
    echo "still work regardless of your audio server, but the software-volume" >&2
    echo "delegation (steps 4-5, api.alsa.soft-mixer + login re-check) only" >&2
    echo "applies to PipeWire + WirePlumber setups." >&2
    echo "If you're on PulseAudio-only or pipewire-media-session (older" >&2
    echo "PipeWire setups), steps 4-5 will be skipped, and you may still see" >&2
    echo "the 'only works at 100%' symptom on the analog profile when" >&2
    echo "adjusting volume from software." >&2
    echo
    read -r -p "Continue anyway with steps 1-3 only? [y/N] " REPLY
    case "$REPLY" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Aborted."; exit 1 ;;
    esac
fi

echo "==> Installing fix for the Redragon H510-PRO"
echo "    Target user: $REAL_USER ($REAL_HOME)"
echo

# --- 1. Volume-fix script with retry -----------------------------------------

echo "==> 1/5: Creating $SYSTEM_SCRIPT"

cat > "$SYSTEM_SCRIPT" << SCRIPT_EOF
#!/bin/bash
# Locks the H510-PRO's hardware volume (PCM,0 and PCM,1) with retries,
# since this dongle's USB mixer takes a moment to become ready after the
# udev 'add' event.

CARD_NAME="${CARD_MATCH_NAME}"
MAX_ATTEMPTS=10
SLEEP_SECS=0.3
AMIXER="${AMIXER_BIN}"

for i in \$(seq 1 "\$MAX_ATTEMPTS"); do
    CARD_NUM=\$(grep -m1 "\$CARD_NAME" /proc/asound/cards | awk '{print \$1}')

    if [ -n "\$CARD_NUM" ]; then
        if "\$AMIXER" -c "\$CARD_NUM" sset 'PCM',0 100% unmute >/dev/null 2>&1 \\
           && "\$AMIXER" -c "\$CARD_NUM" sset 'PCM',1 on >/dev/null 2>&1; then
            logger -t h510-volume-fix "Volume set successfully on card \$CARD_NUM (attempt \$i)"
            exit 0
        fi
    fi

    sleep "\$SLEEP_SECS"
done

logger -t h510-volume-fix "Failed after \$MAX_ATTEMPTS attempts"
exit 1
SCRIPT_EOF

chmod +x "$SYSTEM_SCRIPT"

# --- 2. systemd service (system-level, udev-triggered) -----------------------

echo "==> 2/5: Creating $SYSTEM_SERVICE"

cat > "$SYSTEM_SERVICE" << EOF
[Unit]
Description=Fix H510-PRO PCM hardware volume

[Service]
Type=oneshot
ExecStart=$SYSTEM_SCRIPT
EOF

systemctl daemon-reload

# --- 3. udev rule --------------------------------------------------------------

echo "==> 3/5: Creating $UDEV_RULE"

cat > "$UDEV_RULE" << EOF
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC*", ATTRS{idVendor}=="${VENDOR_ID}", ATTRS{idProduct}=="${PRODUCT_ID}", TAG+="systemd", ENV{SYSTEMD_WANTS}="h510-volume-fix.service"
EOF

udevadm control --reload-rules

# --- 4. WirePlumber config (soft-mixer) + 5. user-level re-check service ----

if [ "$WIREPLUMBER_AVAILABLE" = true ]; then
    echo "==> 4/5: Creating WirePlumber config (soft-mixer) for user $REAL_USER"

    mkdir -p "$WP_CONF_DIR"

    cat > "$WP_CONF_FILE" << EOF
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "~${WIREPLUMBER_DEVICE_MATCH}"
      }
    ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
      }
    }
  }
]
EOF

    chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config/wireplumber"

    echo "==> 5/5: Creating user-level re-check service (fixes the boot race"
    echo "         where WirePlumber overwrites the hardware value on its"
    echo "         own startup, after the early udev-triggered fix already ran)"

    mkdir -p "$USER_SYSTEMD_DIR"

    cat > "$USER_SERVICE_FILE" << 'EOF'
[Unit]
Description=Re-apply H510-PRO hardware volume after WirePlumber initializes
After=wireplumber.service
PartOf=wireplumber.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/h510-volume-fix.sh

[Install]
WantedBy=default.target
EOF

    chown -R "$REAL_USER":"$REAL_USER" "$USER_SYSTEMD_DIR"
else
    echo "==> 4/5: Skipped (WirePlumber not detected)"
    echo "==> 5/5: Skipped (WirePlumber not detected)"
fi

# --- Apply immediately (in case the dongle is already plugged in) -----------

echo
echo "==> Applying the fix immediately (in case the dongle is already connected)..."

if grep -q "$CARD_MATCH_NAME" /proc/asound/cards 2>/dev/null; then
    "$SYSTEM_SCRIPT" || echo "    (warning: dongle detected but the fix failed right now; the next replug should correct it)"
else
    echo "    Dongle not currently detected; the rule will apply on the next connection."
fi

# Reload the user's systemd instance, enable+start the re-check service, and
# restart WirePlumber, all within the user's own session bus if one is active.
if [ "$WIREPLUMBER_AVAILABLE" = true ] && [ "$USER_SESSION_ACTIVE" = true ]; then
    run_as_user systemctl --user daemon-reload || true
    run_as_user systemctl --user enable --now h510-volume-recheck.service || \
        echo "    (warning: could not enable the re-check service automatically; run 'systemctl --user enable --now h510-volume-recheck.service' in your graphical session)"
    run_as_user systemctl --user restart wireplumber || \
        echo "    (warning: could not restart WirePlumber automatically; run 'systemctl --user restart wireplumber' in your graphical session)"
elif [ "$WIREPLUMBER_AVAILABLE" = true ]; then
    echo "    No active graphical session detected for $REAL_USER; WirePlumber and the"
    echo "    re-check service will be picked up on next login."
fi

echo
echo "==> Installation complete."
echo
echo "Summary of what was installed:"
echo "  - $SYSTEM_SCRIPT"
echo "  - $SYSTEM_SERVICE"
echo "  - $UDEV_RULE"
if [ "$WIREPLUMBER_AVAILABLE" = true ]; then
    echo "  - $WP_CONF_FILE"
    echo "  - $USER_SERVICE_FILE (enabled)"
fi
echo
echo "Recommendation: use this device's 'output:analog-stereo' profile"
echo "(avoid the S/PDIF/IEC958 profile — on this dongle it doesn't represent"
echo "a real separate digital DAC; it's just another route over the same"
echo "analog hardware)."
echo
echo "Test with a full reboot (dongle already plugged in), then check with:"
echo "  journalctl --user -u h510-volume-recheck.service -n 10"
echo "  amixer -c \$(grep -m1 '$CARD_MATCH_NAME' /proc/asound/cards | awk '{print \$1}') sget 'PCM',0"
echo
echo "To remove everything this script installed, run:"
echo "  sudo $0 --uninstall"
