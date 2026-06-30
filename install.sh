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

# ─── Step 1: Generate fake EDID (36 resolutions + audio) ───
echo "[1/5] Generating fake EDID (36 resolutions + audio)..."
python3 << 'PYEOF'
import struct

PREF_MODE = "1080p60"

# DTD timing database: (pclk_10kHz, ha, hb, hso, hsw, va, vb, vso, vsw, hp, vp)
TIMINGS = {
    # Standard CEA-861 (also in VIC list, but needed for DTD generation)
    "1080p60":  (14850, 1920, 280, 88, 44, 1080, 45, 4, 5, 1, 1),
    "720p60":   ( 7425, 1280, 370, 110, 40, 720, 30, 5, 5, 1, 1),
    # Non-standard / PC resolutions (CVT-RB where applicable)

    "1440p60":  (24150, 2560, 160, 48, 32, 1440, 41, 3, 5, 0, 0),
    "1600p60":  (26850, 2560, 160, 48, 32, 1600, 46, 3, 6, 0, 0),
    "uw1080p60":(18560, 2560, 160, 48, 32, 1080, 42, 3, 5, 0, 0),
    "uw1440p60":(31975, 3440, 160, 48, 32, 1440, 41, 3, 5, 0, 0),
    "800p60":   ( 7100, 1280, 160, 48, 32, 800, 23, 3, 6, 0, 0),
    "768p60":   ( 8550, 1360, 432, 64, 112, 768, 27, 3, 6, 1, 1),
    "900p60":   (10650, 1440, 464, 80, 152, 900, 34, 3, 6, 0, 0),
    "900p60_1600":(10800, 1600, 160, 48, 32, 900, 34, 3, 6, 0, 0),
    "1050p60":  (14625, 1680, 560, 104, 176, 1050, 39, 3, 6, 0, 0),
    "1200p60":  (15400, 1920, 160, 48, 32, 1200, 35, 3, 6, 0, 0),
    "x1024p60": ( 6500, 1024, 320, 24, 136, 768, 38, 3, 6, 0, 0),
    "sxga60":   (10800, 1280, 408, 48, 112, 1024, 42, 3, 6, 1, 1),
    "sxga75":   (13500, 1280, 408, 48, 112, 1024, 42, 3, 6, 1, 1),
    "uxga60":   (16200, 1600, 560, 64, 192, 1200, 50, 3, 6, 1, 1),
}

# Standard CEA VICs in Video Data Block (21 VICs)
VICS = [
    97, 96, 95, 94, 93,       # 4K: 60,50,30,25,24
    16, 31, 34, 33, 32,       # 1080p: 60,50,30,25,24
    5, 20,                     # 1080i: 60,50
    4, 19, 60,                 # 720p: 60,50,24
    3, 2,                      # 480p (16:9, 4:3)
    18, 17,                    # 576p (16:9, 4:3)
    1,                         # 640x480@60
]

# Non-standard DTDs placed across CEA extension blocks
# Block0 has 2 DTDs (preferred + 720p60)
# Blocks 1-2 have 5 + 6 DTDs each, Block3 has the rest
BLOCK1_DTDS = ["1440p60", "1600p60", "uw1440p60", "800p60", "1200p60"]
BLOCK2_DTDS = ["768p60", "900p60", "900p60_1600", "1050p60", "x1024p60", "sxga60"]
BLOCK3_DTDS = ["sxga75", "uxga60", "uw1080p60"]

ALL_DTDS = BLOCK1_DTDS + BLOCK2_DTDS + BLOCK3_DTDS

def write_dtd(buf, off, t):
    pclk, ha, hb, hso, hsw, va, vb, vso, vsw, hp, vp = t
    struct.pack_into('<H', buf, off, pclk)
    buf[off+2] = ha & 0xFF
    buf[off+3] = hb & 0xFF
    buf[off+4] = ((ha>>8)&0xF)<<4 | ((hb>>8)&0xF)
    buf[off+5] = va & 0xFF
    buf[off+6] = vb & 0xFF
    buf[off+7] = ((va>>8)&0xF)<<4 | ((vb>>8)&0xF)
    buf[off+8] = hso & 0xFF
    buf[off+9] = hsw & 0xFF
    buf[off+10] = ((vso&0xF)<<4) | (vsw&0xF)
    buf[off+11] = ((hso>>8)&0x3)<<2 | ((hsw>>8)&0x3)
    buf[off+12:off+18] = bytes([0x00,0x00,0x00,0x18,0x00,0x00])

def write_cea_header(buf, off, dtd_offset, n_dtds):
    buf[off] = 0x02  # CEA-861 tag
    buf[off+1] = 0x03  # revision
    buf[off+2] = dtd_offset
    buf[off+3] = n_dtds

def write_audio_and_vendor(buf, off):
    # Audio: LPCM 2ch, 32/44.1/48kHz, 16/20/24bit
    buf[off]   = (1<<5)|3
    buf[off+1] = 0x09
    buf[off+2] = 0x07
    buf[off+3] = 0x07
    off += 4
    # Speaker: FL/FR
    buf[off]   = (4<<5)|3
    buf[off+1] = 0x00
    buf[off+2] = 0x00
    buf[off+3] = 0x01
    off += 4
    # Vendor HDMI
    buf[off]   = (3<<5)|5
    buf[off+1] = 0x03
    buf[off+2] = 0x0C
    buf[off+3] = 0x00
    buf[off+4] = 0x10  # PA=1.0.0.0, supports_ai=1
    buf[off+5] = 0x00
    return off + 6

def write_vic_list(buf, off, vics):
    n = len(vics)
    buf[off]   = (2<<5) | ((1+n) & 0x1F)
    buf[off+1] = n
    for i, vic in enumerate(vics):
        buf[off+2+i] = vic
    return off + 2 + n

# ─── Build EDID (512 bytes, 4 blocks) ───
edid = bytearray(512)
EDID_BLOCK = 128

# === Block 0: Base EDID ===
edid[0:8]   = bytes([0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00])
edid[8:10]  = bytes([0x48,0xF2])
edid[10:12] = struct.pack('<H', 1)
edid[12:16] = struct.pack('<I', 1)
edid[16]    = 26; edid[17] = 35
edid[18]    = 0x01; edid[19] = 0x04; edid[20] = 0xA5
edid[21:23] = bytes([0x00,0x00])
edid[23]    = 0x78; edid[24] = 0x0E
edid[25:35] = bytes([0xEE,0x91,0xA3,0x54,0x4C,0x99,0x26,0x0F,0x50,0x54])
edid[35:38] = bytes([0x21,0x08,0x00])
for i in range(38, 54, 2):
    edid[i] = 0x01; edid[i+1] = 0x01

# DTD 1: Preferred
write_dtd(edid, 54, TIMINGS[PREF_MODE])
# DTD 2: 720p60
write_dtd(edid, 72, TIMINGS["720p60"])

# Display name
edid[90:108] = bytes([0x00,0x00,0x00,0xFC,0x00,
    0x48,0x44,0x4D,0x49,0x2D,0x45,0x44,0x49,0x44,0x0A,0x20,0x20,0x20])
# Range limits
edid[108:126] = bytes([0x00,0x00,0x00,0xFD,0x00,
    24,77,30,85,0xAA,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00])

edid[126] = 3  # 3 extension blocks
edid[127] = (256 - sum(edid[:127])) & 0xFF

# === Block 1: CEA-861 with VIC list + audio + 5 DTDs ===
pos1 = 4
pos1 = write_vic_list(edid, EDID_BLOCK + pos1, VICS)
pos1 = write_audio_and_vendor(edid, EDID_BLOCK + pos1)
write_cea_header(edid, EDID_BLOCK, pos1, len(BLOCK1_DTDS))
for key in BLOCK1_DTDS:
    write_dtd(edid, EDID_BLOCK + pos1, TIMINGS[key])
    pos1 += 18
for i in range(pos1, 127):
    edid[EDID_BLOCK + i] = 0x00
edid[EDID_BLOCK + 127] = (256 - sum(edid[EDID_BLOCK:EDID_BLOCK+127])) & 0xFF

# === Block 2: CEA-861 DTDs only ===
pos2 = 4
write_cea_header(edid, 2*EDID_BLOCK, pos2, len(BLOCK2_DTDS))
for key in BLOCK2_DTDS:
    write_dtd(edid, 2*EDID_BLOCK + pos2, TIMINGS[key])
    pos2 += 18
for i in range(pos2, 127):
    edid[2*EDID_BLOCK + i] = 0x00
edid[2*EDID_BLOCK + 127] = (256 - sum(edid[2*EDID_BLOCK:2*EDID_BLOCK+127])) & 0xFF

# === Block 3: CEA-861 DTDs only ===
pos3 = 4
write_cea_header(edid, 3*EDID_BLOCK, pos3, len(BLOCK3_DTDS))
for key in BLOCK3_DTDS:
    write_dtd(edid, 3*EDID_BLOCK + pos3, TIMINGS[key])
    pos3 += 18
for i in range(pos3, 127):
    edid[3*EDID_BLOCK + i] = 0x00
edid[3*EDID_BLOCK + 127] = (256 - sum(edid[3*EDID_BLOCK:3*EDID_BLOCK+127])) & 0xFF

with open("/lib/firmware/edid-hdmi-audio.bin", 'wb') as f:
    f.write(bytes(edid))

print(f"  EDID: {len(edid)} bytes")
print(f"  Resolutions: {2 + len(VICS) + len(ALL_DTDS)} total ({len(VICS)} VICs + {2+len(ALL_DTDS)} DTDs)")
print(f"  Checksums: B0=0x{edid[127]:02x} B1=0x{edid[255]:02x} B2=0x{edid[383]:02x} B3=0x{edid[511]:02x}")
PYEOF
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

# ─── Step 4: Install hdmi-edid script ───
echo "[5/5] Installing hdmi-edid..."
curl -sL -o "$SCRIPT" https://raw.githubusercontent.com/sunfounder/pi-hdmi-edid/main/hdmi-edid
chmod +x "$SCRIPT"
echo "  Installed to $SCRIPT"

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
