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

# ─── Step 1: Download EDID generator & create default EDID ───
echo "[1/5] Downloading EDID generator..."
GEN="/tmp/hdmi-edid-gen"
curl -sL -o "$GEN" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x "$GEN"
# Default active modes (same as hdmi-edid config defaults)
DEFAULT_MODES="4k30,4k25,4k24,1080p60,1080p50,1080p30,1080p25,1080p24,1080i60,1080i50,720p60,720p50,1440p60,1600p60,uw1080p60,uw1440p60,uxga60,1200p60,1050p60,900p60_1600,900p60,768p60,sxga60,800p60,x1024p60,480p60,480p60_720"
echo "  Generating default EDID..."
python3 "$GEN" "1080p60" "$DEFAULT_MODES"
rm -f "$GEN"
echo ""

# ─── Step 2: Detect audio EDID ───PYEOF
echo ""

# ─── Step 2: Detect real EDID and check for audio ───
echo "[2/5] Detecting audio EDID..."
HAS_AUDIO_EDID=false
EDID_SIZE=0

EDID_PATH=$(ls /sys/class/drm/card*-HDMI-A-1/edid 2>/dev/null | head -1)
if [ -n "$EDID_PATH" ]; then
    TMP=$(mktemp)
    cat "$EDID_PATH" > "$TMP" 2>/dev/null || true
    EDID_SIZE=$(wc -c < "$TMP")
    rm -f "$TMP"

    if [ "$EDID_SIZE" -ge 256 ]; then
        CEA_TAG=$(dd if="$EDID_PATH" bs=1 skip=128 count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
        if [ "$CEA_TAG" = "2" ]; then
            DTD_OFFSET=$(dd if="$EDID_PATH" bs=1 skip=130 count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
            SCAN_LEN=$((DTD_OFFSET > 4 ? DTD_OFFSET : 4))
            i=0
            while [ $i -lt $SCAN_LEN ]; do
                BYTE=$(dd if="$EDID_PATH" bs=1 skip=$((132 + i)) count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
                TAG=$(( (BYTE >> 5) & 7 ))
                LEN=$(( BYTE & 31 ))
                if [ "$TAG" = "1" ] && [ "$LEN" -ge 3 ]; then
                    HAS_AUDIO_EDID=true
                    break
                fi
                i=$((i + 1 + LEN))
            done
        fi
    fi
fi

if $HAS_AUDIO_EDID; then
    echo "  Audio-capable EDID detected (${EDID_SIZE}B) -> Path A (passthrough mode)"
else
    echo "  No audio-capable EDID (${EDID_SIZE}B) -> Path B (drm.edid_firmware mode)"
fi

# ─── Step 3: Configure kernel ───
echo "[3/5] Configuring kernel..."

if $HAS_AUDIO_EDID; then
    echo "  Path A: No kernel parameters added (extractor provides audio EDID)"
    [ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak"
else
    if ! grep -q 'vc4.force_hotplug=1' "$CMDLINE"; then
        [ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak"
        sed -i '$s/$/ vc4.force_hotplug=1/' "$CMDLINE"
        echo "  Added vc4.force_hotplug=1"
    else
        echo "  vc4.force_hotplug=1 already present"
    fi
    if ! grep -q 'drm.edid_firmware=HDMI-A-1:edid-hdmi-audio.bin' "$CMDLINE"; then
        sed -i '$s/$/ drm.edid_firmware=HDMI-A-1:edid-hdmi-audio.bin/' "$CMDLINE"
        echo "  Added drm.edid_firmware=HDMI-A-1:edid-hdmi-audio.bin"
    else
        echo "  drm.edid_firmware already present"
    fi
fi

echo "[4/5] Configuring config.txt..."
if ! grep -q '^hdmi_force_hotplug=1' "$CONFIG_TXT"; then
    sed -i '/^dtoverlay=vc4-kms-v3d$/a hdmi_force_hotplug=1' "$CONFIG_TXT"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already present"
fi

# ─── Step 4: Install scripts ───
echo "[5/5] Installing scripts..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  Installed to $SCRIPT"
curl -sL -o /usr/local/bin/hdmi-edid-gen https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-gen
chmod +x /usr/local/bin/hdmi-edid-gen
echo "  Installed hdmi-edid-gen"
curl -sL -o /usr/local/bin/hdmi-edid-merge https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid-merge
chmod +x /usr/local/bin/hdmi-edid-merge
echo "  Installed hdmi-edid-merge"

# ─── Step 5: Install systemd service (Path A only) ───
if $HAS_AUDIO_EDID; then
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
    echo "  Service installed and enabled (Path A)"
else
    echo "  Path B: no boot service (drm.edid_firmware handles EDID)"
    # Disable if previously installed
    systemctl disable hdmi-edid-boot.service 2>/dev/null || true
    rm -f /etc/systemd/system/hdmi-edid-boot.service
    systemctl daemon-reload
fi

echo ""
echo "========================================"
if $HAS_AUDIO_EDID; then
    echo "  Path A: extractor provides audio EDID"
    echo "  -> 4K passthrough + audio work automatically"
else
    echo "  Path B: drm.edid_firmware mode"
    echo "  -> Audio works, 36 resolutions in fake EDID"
    echo "  -> hdmi-edid config to merge external EDID"
fi
echo "========================================"
echo ""
echo "Commands:"
echo "  hdmi-edid switch      # (Path A) switch real/fake EDID"
echo "  hdmi-edid config      # manage EDID resolutions"
echo "  hdmi-edid uninstall   # remove all configuration"
