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

# ─── Step 1: Generate fake EDID (always, for fallback) ───
echo "[1/5] Generating fake EDID..."
base64 -d > "$FAKE_EDID" << 'B64EOF'
AP///////wBI8gEAAQAAABojAQSlAAB4Du6Ro1RMmSYPUFQhCAABAQEBAQEBAQEBAQEBAQEBAjqA
GHE4LUBYLEUAAAAAGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/QA5
Px5VqgAAAAAAAAAAAZICAxMAIwkHB4MBAAFmAwwAEACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJA==
B64EOF
echo "  Fake EDID: $(wc -c < "$FAKE_EDID") bytes"

# ─── Step 2: Detect real EDID and check for audio ───
echo "[2/5] Detecting audio EDID..."
HAS_AUDIO_EDID=false
EDID_SIZE=0

# Auto-detect DRM card path
EDID_PATH=$(ls /sys/class/drm/card*-HDMI-A-1/edid 2>/dev/null | head -1)
if [ -n "$EDID_PATH" ]; then
    TMP=$(mktemp)
    cat "$EDID_PATH" > "$TMP" 2>/dev/null || true
    EDID_SIZE=$(wc -c < "$TMP")
    rm -f "$TMP"

    if [ "$EDID_SIZE" -ge 256 ]; then
        # Check for CEA-861 extension block with audio
        # Byte 128 = extension block tag (0x02 = CEA-861)
        # Scan for Audio Data Block (tag 1, bits 7-3) in CEA data block collection
        CEA_TAG=$(dd if="$EDID_PATH" bs=1 skip=128 count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
        if [ "$CEA_TAG" = "2" ]; then
            # CEA-861 block exists. Check for Audio Data Block.
            DTD_OFFSET=$(dd if="$EDID_PATH" bs=1 skip=130 count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
            # Scan bytes 132..131+DTD_OFFSET for tag code 1 (Audio)
            SCAN_LEN=$((DTD_OFFSET > 4 ? DTD_OFFSET : 4))
            SCAN_START=132
            i=0
            while [ $i -lt $SCAN_LEN ]; do
                BYTE=$(dd if="$EDID_PATH" bs=1 skip=$((SCAN_START + i)) count=1 2>/dev/null | od -A n -t u1 | tr -d ' ')
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
    echo "  Audio-capable EDID detected (${EDID_SIZE}B) → Path A (passthrough mode)"
else
    echo "  No audio-capable EDID (${EDID_SIZE}B) → Path B (drm.edid_firmware mode)"
fi

# ─── Step 3: Configure kernel ───
echo "[3/5] Configuring kernel..."

if $HAS_AUDIO_EDID; then
    # Path A: No kernel params — rely on extractor's own EDID
    # HPD transitions work → 4K passthrough works
    echo "  Path A: No kernel parameters added (extractor provides audio EDID)"
    # Still backup cmdline in case we need to roll back
    [ ! -f "${CMDLINE}.bak" ] && cp "$CMDLINE" "${CMDLINE}.bak"
else
    # Path B: Force fake EDID at boot for audio
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

# ─── Step 4: Install hdmi-edid script ───
echo "[5/5] Installing hdmi-edid..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  Installed to $SCRIPT"

# ─── Step 5: Install systemd service (Path B only needs it) ───
# Always install — harmless on Path A (switch detects real EDID, does nothing)
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
if $HAS_AUDIO_EDID; then
    echo "  Path A: extractor provides audio EDID"
    echo "  → 4K passthrough + audio work automatically"
else
    echo "  Path B: drm.edid_firmware mode"
    echo "  → Audio works, but external EDID is overridden"
    echo "  → To read external display EDID: use I2C DDC"
fi
echo "========================================"
echo ""
echo "After reboot:"
echo "  hdmi-edid switch      # auto-detect EDID mode"
echo "  hdmi-edid uninstall   # remove all configuration"
