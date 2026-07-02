#!/bin/bash
# pi-hdmi-edid installer — one-line deployment for Raspberry Pi 5
# Usage: curl -sL https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/install.sh | sudo bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

# Auto-detect paths (Ubuntu flash-kernel puts cmdline in current/, Raspbian at top level)
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG_TXT="/boot/firmware/config.txt"
    # Ubuntu flash-kernel: cmdline.txt is in current/ subdirectory
    if [ -f "/boot/firmware/current/cmdline.txt" ]; then
        CMDLINE="/boot/firmware/current/cmdline.txt"
    elif [ -f "/boot/firmware/cmdline.txt" ]; then
        CMDLINE="/boot/firmware/cmdline.txt"
    else
        echo "ERROR: cannot find cmdline.txt"
        exit 1
    fi
elif [ -f "/boot/config.txt" ]; then
    CONFIG_TXT="/boot/config.txt"
    CMDLINE="/boot/cmdline.txt"
else
    echo "ERROR: cannot find config.txt in /boot/firmware or /boot"
    exit 1
fi
SCRIPT="/usr/local/bin/hdmi-edid"

echo "=== pi-hdmi-edid installer ==="
echo ""

# Step 1: Download EDID generator & create default EDID
echo "[1/6] Generating default EDID..."
GEN="/tmp/hdmi-edid-gen"
curl -sL -o "$GEN" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x "$GEN"
python3 "$GEN" "1080p60" "4k30,4k25,4k24,1080p60,1080p50,1080p30,1080p25,1080p24,1080i60,1080i50,720p60,720p50,1440p60,1600p60,uw1080p60,uw1440p60,uxga60,1200p60,1050p60,900p60_1600,900p60,768p60,sxga60,800p60,x1024p60,480p60,480p60_720"
rm -f "$GEN"
echo ""

# Step 2: Configure kernel (force mode = drm.edid_firmware + force_hotplug)
echo "[2/6] Configuring kernel (force mode)..."
if ! grep -q 'vc4.force_hotplug=1' "$CMDLINE"; then
    [ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak"
    sed -i '$s/$/ vc4.force_hotplug=1/' "$CMDLINE"
    echo "  Added vc4.force_hotplug=1"
else
    echo "  vc4.force_hotplug=1 already present"
fi
if ! grep -q 'drm.edid_firmware=HDMI-A-1:edid-hdmi-audio.bin' "$CMDLINE"; then
    sed -i '$s/$/ drm.edid_firmware=HDMI-A-1:edid-hdmi-audio.bin/' "$CMDLINE"
    echo "  Added drm.edid_firmware"
else
    echo "  drm.edid_firmware already present"
fi

echo "[3/6] Configuring config.txt..."
if ! grep -q '^hdmi_force_hotplug=1' "$CONFIG_TXT"; then
    sed -i '/^dtoverlay=vc4-kms-v3d$/a hdmi_force_hotplug=1' "$CONFIG_TXT"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already present"
fi

# Step 3: Install scripts
echo "[4/6] Installing scripts..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  hdmi-edid installed"
curl -sL -o /usr/local/bin/hdmi-edid-gen https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x /usr/local/bin/hdmi-edid-gen
echo "  hdmi-edid-gen installed"
curl -sL -o /usr/local/bin/hdmi-edid-merge https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-merge
chmod +x /usr/local/bin/hdmi-edid-merge
echo "  hdmi-edid-merge installed"

# Step 3.5: Install initramfs hook (so EDID loads before rootfs mount)
echo "[5/6] Installing initramfs hook..."
curl -sL -o /etc/initramfs-tools/hooks/edid https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/initramfs-edid-hook
chmod +x /etc/initramfs-tools/hooks/edid
[ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak" 2>/dev/null || true
update-initramfs -u 2>&1 || echo "  WARNING: update-initramfs failed — EDID may not load at early boot"
echo ""

# Step 4: Install systemd services (both boot + user)
echo "[6/6] Installing services..."
# Boot service — refreshes PipeWire at boot
curl -sL -o /etc/systemd/system/hdmi-edid-boot.service https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/systemd/hdmi-edid-boot.service
systemctl daemon-reload
systemctl enable hdmi-edid-boot.service 2>/dev/null || true
echo "  hdmi-edid-boot.service installed"

# User service — refreshes PipeWire + panel after desktop starts
DESKTOP_USER=$(loginctl list-users --no-legend 2>/dev/null | awk '$1 != "0" {print $2; exit}')
if [ -n "$DESKTOP_USER" ]; then
    USER_HOME=$(eval echo ~"$DESKTOP_USER")
    mkdir -p "$USER_HOME/.config/systemd/user"
    curl -sL -o "$USER_HOME/.config/systemd/user/hdmi-edid-user.service" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/systemd/hdmi-edid-user.service
    chown -R "$DESKTOP_USER":"$DESKTOP_USER" "$USER_HOME/.config/systemd"
    su -l "$DESKTOP_USER" -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user daemon-reload && XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user enable hdmi-edid-user.service" 2>/dev/null || true
    echo "  hdmi-edid-user.service installed"
else
    echo "  WARNING: no desktop user found, skipping user service"
fi

echo ""
echo "========================================"
echo "  pi-hdmi-edid installed (force mode)"
echo "  Reboot required."
echo "  Use hdmi-edid config to manage EDID."
echo "========================================"
