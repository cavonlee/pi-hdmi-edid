#!/bin/bash
# pi-hdmi-edid installer — one-line deployment for Raspberry Pi 5
# Usage: curl -sL https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/install.sh | sudo bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

CMDLINE="/boot/firmware/cmdline.txt"
CONFIG_TXT="/boot/firmware/config.txt"
SCRIPT="/usr/local/bin/hdmi-edid"

echo "=== pi-hdmi-edid installer ==="
echo ""

# Step 1: Download EDID generator & create default EDID
echo "[1/4] Generating default EDID..."
GEN="/tmp/hdmi-edid-gen"
curl -sL -o "$GEN" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x "$GEN"
python3 "$GEN" "1080p60" "4k30,4k25,4k24,1080p60,1080p50,1080p30,1080p25,1080p24,1080i60,1080i50,720p60,720p50,1440p60,1600p60,uw1080p60,uw1440p60,uxga60,1200p60,1050p60,900p60_1600,900p60,768p60,sxga60,800p60,x1024p60,480p60,480p60_720"
rm -f "$GEN"
echo ""

# Step 2: Configure kernel (force mode = drm.edid_firmware + force_hotplug)
echo "[2/4] Configuring kernel (force mode)..."
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

echo "[3/4] Configuring config.txt..."
if ! grep -q '^hdmi_force_hotplug=1' "$CONFIG_TXT"; then
    sed -i '/^dtoverlay=vc4-kms-v3d$/a hdmi_force_hotplug=1' "$CONFIG_TXT"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already present"
fi

# Step 3: Install scripts
echo "[4/4] Installing scripts..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  hdmi-edid installed"
curl -sL -o /usr/local/bin/hdmi-edid-gen https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x /usr/local/bin/hdmi-edid-gen
echo "  hdmi-edid-gen installed"
curl -sL -o /usr/local/bin/hdmi-edid-merge https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-merge
chmod +x /usr/local/bin/hdmi-edid-merge
echo "  hdmi-edid-merge installed"

# No boot service for force mode
systemctl disable hdmi-edid-boot.service 2>/dev/null || true
rm -f /etc/systemd/system/hdmi-edid-boot.service
systemctl daemon-reload 2>/dev/null || true

echo ""
echo "========================================"
echo "  Force mode installed"
echo "  Reboot to apply."
echo "  Use hdmi-edid config to manage EDID."
echo "========================================"
