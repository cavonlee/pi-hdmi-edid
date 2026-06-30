#!/bin/bash
# pi-hdmi-edid installer — one-line deployment for Raspberry Pi 5
# Usage: curl -sL https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/install.sh | sudo bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

CMDLINE="/boot/firmware/cmdline.txt"
CONFIG_TXT="/boot/firmware/config.txt"
FAKE_EDID="/lib/firmware/edid-hdmi-audio.bin"
SCRIPT="/usr/local/bin/hdmi-edid"

echo "=== pi-hdmi-edid installer ==="
echo ""

# 1. Generate fake EDID (embedded base64)
echo "[1/5] Generating fake EDID..."
base64 -d > "$FAKE_EDID" << 'B64EOF'
AP///////wBI8gEAAQAAABojAQSlAAB4Du6Ro1RMmSYPUFQhCAABAQEBAQEBAQEBAQEBAQEBAjqA
GHE4LUBYLEUAAAAAGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/QA5
Px5VqgAAAAAAAAAAAZICAxMAIwkHB4MBAAFmAwwAEACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJA==
B64EOF
echo "  Fake EDID: $(wc -c < "$FAKE_EDID") bytes"

# 2. Configure kernel
echo "[2/5] Configuring cmdline.txt..."
if ! grep -q 'vc4.force_hotplug=1' "$CMDLINE"; then
    [ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak"
    sed -i '$s/$/ vc4.force_hotplug=1/' "$CMDLINE"
    echo "  Added vc4.force_hotplug=1"
else
    echo "  vc4.force_hotplug=1 already present"
fi

echo "[3/5] Configuring config.txt..."
if ! grep -q '^hdmi_force_hotplug=1' "$CONFIG_TXT"; then
    sed -i '/^dtoverlay=vc4-kms-v3d$/a hdmi_force_hotplug=1' "$CONFIG_TXT"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already present"
fi

# 3. Download hdmi-edid script
echo "[4/5] Installing hdmi-edid..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  Installed to $SCRIPT"

# 4. Install systemd service
echo "[5/5] Installing systemd service..."
cat > /etc/systemd/system/hdmi-edid-boot.service << 'UNITEOF'
[Unit]
Description=HDMI EDID Boot Setup
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hdmi-edid switch
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable hdmi-edid-boot.service
echo "  Service installed and enabled"

echo ""
echo "========================================"
echo "  Install complete. Reboot to apply."
echo "========================================"
echo ""
echo "After reboot:"
echo "  hdmi-edid switch      # auto-detect EDID mode"
echo "  hdmi-edid uninstall   # remove all configuration"
