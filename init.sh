#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Chromebook Ubuntu Server initialization
# ============================================================
# Run with:
#   sudo ./init.sh
#
# This script is intended to be idempotent and safe to rerun.
# ============================================================

# ----------------------------
# User-configurable settings
# ----------------------------

BATTERY_LIMIT=60
SCREEN_ON_BRIGHTNESS=4800

BACKLIGHT_BRIGHTNESS="/sys/class/backlight/intel_backlight/brightness"
EDP_STATUS="/sys/class/drm/card1-eDP-1/status"

# Optional battery alias. This is written verbatim into ~/.bash_aliases.
BATTERY_ALIAS="alias battery='upower -i /org/freedesktop/UPower/devices/battery_BAT0'"

# ----------------------------
# Basic setup
# ----------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this script with sudo:"
    echo "  sudo $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "ERROR: could not determine home directory for user: $REAL_USER"
    exit 1
fi

echo "============================================================"
echo "Initializing Ubuntu server"
echo "User:       $REAL_USER"
echo "Home:       $USER_HOME"
echo "Script dir: $SCRIPT_DIR"
echo "============================================================"

# ----------------------------
# System update
# IMPORTANT: upgrade happens before any package installation.
# ----------------------------

echo
echo "==> Updating package indexes..."
apt update

echo
echo "==> Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo
echo "==> Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    htop \
    nano \
    tmux \
    locales \
    curl \
    git \
    rfkill \
    upower \
    iw

# ----------------------------
# Locale
# ----------------------------

echo
echo "==> Configuring en_US.UTF-8 locale..."
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# ----------------------------
# uv
# ----------------------------

echo
echo "==> Installing uv for $REAL_USER if needed..."

if sudo -u "$REAL_USER" env HOME="$USER_HOME" bash -lc \
    'command -v uv >/dev/null 2>&1 || [ -x "$HOME/.local/bin/uv" ]'; then
    echo "uv already installed."
else
    sudo -u "$REAL_USER" env HOME="$USER_HOME" \
        bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
fi

# ----------------------------
# Ignore lid close
# ----------------------------

echo
echo "==> Configuring lid-close behavior..."

mkdir -p /etc/systemd/logind.conf.d

cat > /etc/systemd/logind.conf.d/ignore-lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

# ----------------------------
# Battery charge limit
# ----------------------------

echo
echo "==> Configuring ${BATTERY_LIMIT}% battery charge limit..."

cat > /etc/systemd/system/battery-charge-limit.service <<EOF
[Unit]
Description=Set Chromebook battery charge limit

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'while [ ! -e /sys/class/power_supply/BAT0/charge_control_end_threshold ]; do sleep 2; done; echo ${BATTERY_LIMIT} > /sys/class/power_supply/BAT0/charge_control_end_threshold'
TimeoutStartSec=120
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------
# True screen-off at boot
#
# brightness=0 alone only disables the backlight.  We also
# disable the eDP connector so the panel/display pipeline can
# enter its low-power state.
# ----------------------------

echo
echo "==> Configuring display-off-at-boot service..."

cat > /etc/systemd/system/backlight-off.service <<EOF
[Unit]
Description=Turn off Chromebook display pipeline at boot

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in \$(seq 1 60); do if [ -e "${BACKLIGHT_BRIGHTNESS}" ] && [ -e "${EDP_STATUS}" ]; then break; fi; sleep 1; done; [ -e "${BACKLIGHT_BRIGHTNESS}" ] && echo 0 > "${BACKLIGHT_BRIGHTNESS}"; [ -e "${EDP_STATUS}" ] && echo off > "${EDP_STATUS}"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ----------------------------
# Disable Bluetooth at boot
# ----------------------------

echo
echo "==> Configuring Bluetooth to be blocked at boot..."

RFKILL_BIN="$(command -v rfkill)"

cat > /etc/systemd/system/disable-bluetooth.service <<EOF
[Unit]
Description=Block Bluetooth radio at boot
After=systemd-rfkill.service

[Service]
Type=oneshot
ExecStart=${RFKILL_BIN} block bluetooth
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# The Bluetooth daemon is unnecessary on this server.
# Ignore failure in case bluez/bluetooth.service is not installed.
systemctl disable --now bluetooth.service 2>/dev/null || true

# ----------------------------
# Shell aliases
# ----------------------------

echo
echo "==> Updating $USER_HOME/.bash_aliases..."

ALIASES_FILE="$USER_HOME/.bash_aliases"

touch "$ALIASES_FILE"
chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$ALIASES_FILE"

# Remove the previous managed block, if any.
sed -i '/# BEGIN SERVER ALIASES/,/# END SERVER ALIASES/d' "$ALIASES_FILE"

{
    echo
    echo "# BEGIN SERVER ALIASES"
    echo "# Managed by init.sh"
    printf "%s\n" \
        "alias screenoff='echo 0 | sudo tee ${BACKLIGHT_BRIGHTNESS} >/dev/null; echo off | sudo tee ${EDP_STATUS} >/dev/null'"
    printf "%s\n" \
        "alias screenon='echo detect | sudo tee ${EDP_STATUS} >/dev/null; sleep 1; echo ${SCREEN_ON_BRIGHTNESS} | sudo tee ${BACKLIGHT_BRIGHTNESS} >/dev/null'"

    if [[ -n "$BATTERY_ALIAS" ]]; then
        printf "%s\n" "$BATTERY_ALIAS"
    fi

    echo "# END SERVER ALIASES"
} >> "$ALIASES_FILE"

chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$ALIASES_FILE"

# ----------------------------
# Activate configuration
# ----------------------------

echo
echo "==> Reloading systemd..."
systemctl daemon-reload

echo
echo "==> Enabling core services..."
systemctl enable battery-charge-limit.service
systemctl enable backlight-off.service
systemctl enable disable-bluetooth.service

echo
echo "==> Applying configuration now..."

# Battery threshold
systemctl restart battery-charge-limit.service || true

# Disable Bluetooth now and on every boot.
systemctl restart disable-bluetooth.service || true

# Turn the display fully off now, including when rerunning this script.
systemctl restart backlight-off.service || true

# ----------------------------
# Verification
# ----------------------------

echo
echo "============================================================"
echo "Verification"
echo "============================================================"

echo
echo "[Locale]"
grep -E '^LANG=' /etc/default/locale 2>/dev/null || true

echo
echo "[uv]"
if sudo -u "$REAL_USER" env HOME="$USER_HOME" bash -lc 'command -v uv >/dev/null 2>&1'; then
    sudo -u "$REAL_USER" env HOME="$USER_HOME" bash -lc 'uv --version'
elif [[ -x "$USER_HOME/.local/bin/uv" ]]; then
    sudo -u "$REAL_USER" "$USER_HOME/.local/bin/uv" --version
else
    echo "uv not found"
fi

echo
echo "[Battery charge limit]"
if [[ -e /sys/class/power_supply/BAT0/charge_control_end_threshold ]]; then
    cat /sys/class/power_supply/BAT0/charge_control_end_threshold
else
    echo "charge_control_end_threshold not currently available"
fi

echo
echo "[Display]"
if [[ -e "$BACKLIGHT_BRIGHTNESS" ]]; then
    printf "brightness: "
    cat "$BACKLIGHT_BRIGHTNESS"
else
    echo "brightness control not found"
fi

if [[ -e "$EDP_STATUS" ]]; then
    printf "eDP status: "
    cat "$EDP_STATUS"

    EDP_ENABLED="${EDP_STATUS%/status}/enabled"
    if [[ -e "$EDP_ENABLED" ]]; then
        printf "eDP enabled: "
        cat "$EDP_ENABLED"
    fi
else
    echo "eDP status control not found"
fi

echo
echo "[Bluetooth]"
rfkill list bluetooth 2>/dev/null || echo "No Bluetooth rfkill device found."
systemctl is-enabled disable-bluetooth.service 2>/dev/null || true

echo
echo "[Lid behavior]"
cat /etc/systemd/logind.conf.d/ignore-lid.conf

echo
echo "[Aliases]"
sed -n '/# BEGIN SERVER ALIASES/,/# END SERVER ALIASES/p' "$ALIASES_FILE"

echo
echo "============================================================"
echo "Initialization complete."
echo
echo "Reconnect your shell, or run:"
echo "  source ~/.bash_aliases"
echo
echo "A reboot is recommended so all boot-time settings are tested:"
echo "  sudo reboot"
echo "============================================================"
