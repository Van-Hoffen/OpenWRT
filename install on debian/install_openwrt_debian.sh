#!/bin/bash

set -e

# Formatting
G='\033[0;32m'
Y='\033[1;33m'
R='\033[0;31m'
N='\033[0m'
msg()  { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[!] ERROR:${N} $1"; exit 1; }

# ─── Sanity checks ───────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && err "Must run as root."
[ "$(uname -m)" != "x86_64" ] && err "Only x86_64 is supported."

if systemd-detect-virt 2>/dev/null | grep -qiE "openvz|lxc"; then
    err "OpenVZ/LXC is not supported. Use a KVM-based VPS."
fi

# ─── Random port generation ──────────────────────────────────────────────────
SSH_PORT=${SSH_PORT:-$(shuf -i 10000-59999 -n1)}
LUCI_PORT=${LUCI_PORT:-$(shuf -i 10000-59999 -n1)}
while [ "$LUCI_PORT" -eq "$SSH_PORT" ]; do
    LUCI_PORT=$(shuf -i 10000-59999 -n1)
done

PASS_RAW="${SSH_PASS:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}"

msg "Generated SSH port  : $SSH_PORT"
msg "Generated LuCI port : $LUCI_PORT"
msg "Root password       : $PASS_RAW"
echo ""
warn "SAVE THIS INFORMATION NOW — it won't be shown after reboot!"
echo ""

# ─── Network Discovery ───────────────────────────────────────────────────────
msg "Collecting network data..."
ACTIVE_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
[ -z "$ACTIVE_IF" ] && err "Active interface not found."

ADDR_CIDR=$(ip -4 addr show "$ACTIVE_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
[ -z "$ADDR_CIDR" ] && err "Failed to detect IP address on $ACTIVE_IF."
WAN_IP=${ADDR_CIDR%/*}
WAN_PREFIX=${ADDR_CIDR#*/}
WAN_GW=$(ip route | grep default | awk '{print $3}')
[ -z "$WAN_GW" ] && err "Default gateway not found."

cdr2mask() {
    local i mask=""
    local full_octets=$(($1 / 8))
    local partial_octet=$(($1 % 8))
    for ((i=0; i<4; i++)); do
        if   [ $i -lt $full_octets ]; then mask+="255"
        elif [ $i -eq $full_octets ]; then mask+=$((256 - 2**(8 - $partial_octet)))
        else mask+="0"; fi
        [ $i -lt 3 ] && mask+="."
    done
    echo "$mask"
}
WAN_MASK=$(cdr2mask "${WAN_PREFIX:-24}")

msg "Interface : $ACTIVE_IF"
msg "WAN IP    : $WAN_IP / $WAN_MASK"
msg "Gateway   : $WAN_GW"

# ─── Dependencies (до curl-запросов) ─────────────────────────────────────────
msg "Installing dependencies..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl gzip util-linux fdisk initramfs-tools openssl kmod >/dev/null 2>&1

# ─── Auto-detect latest OpenWRT stable version ───────────────────────────────
msg "Detecting latest OpenWRT stable version..."

OWRT_BASE="https://downloads.openwrt.org/releases"

# Парсим листинг: ищем строки вида >25.12.4/<
LATEST_VER=$(curl -sSL --connect-timeout 15 "${OWRT_BASE}/" 2>/dev/null \
    | grep -oP '(?<=>)\d+\.\d+\.\d+(?=/)' \
    | sort -V \
    | tail -n1)

if [ -z "$LATEST_VER" ]; then
    warn "Auto-detection failed, falling back to known latest: 25.12.4"
    LATEST_VER="25.12.4"
fi

msg "Detected OpenWRT version: $LATEST_VER"

# ─── Найти имя образа через sha256sums ───────────────────────────────────────
TARGET_URL="${OWRT_BASE}/${LATEST_VER}/targets/x86/64"
SHA256_URL="${TARGET_URL}/sha256sums"

msg "Fetching file list from ${TARGET_URL}..."
SHA256_LIST=$(curl -sSL --connect-timeout 15 "$SHA256_URL" 2>/dev/null)
[ -z "$SHA256_LIST" ] && err "Cannot fetch sha256sums from ${SHA256_URL}"

# Предпочитаем ext4-combined (не efi, не squashfs)
IMG_NAME=$(echo "$SHA256_LIST" \
    | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined\.img\.gz' \
    | head -n1)

# Fallback: efi-вариант
if [ -z "$IMG_NAME" ]; then
    IMG_NAME=$(echo "$SHA256_LIST" \
        | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined-efi\.img\.gz' \
        | head -n1)
fi

[ -z "$IMG_NAME" ] && err "Cannot find ext4-combined image in ${SHA256_URL}"

IMG_URL="${TARGET_URL}/${IMG_NAME}"
IMG_SHA256=$(echo "$SHA256_LIST" | grep "$IMG_NAME" | awk '{print $1}')

msg "Image     : $IMG_NAME"
msg "Image URL : $IMG_URL"

# ─── Image Download ──────────────────────────────────────────────────────────
msg "Downloading OpenWRT ${LATEST_VER} image..."
OWRT_TMP="/tmp/owrt.img"
OWRT_GZ="/tmp/owrt.img.gz"

curl -L --progress-bar --connect-timeout 30 --retry 3 \
    "$IMG_URL" -o "$OWRT_GZ" || err "Image download failed."

[ ! -s "$OWRT_GZ" ] && err "Downloaded file is empty."
msg "Downloaded: $(du -sh "$OWRT_GZ" | cut -f1)"

# ─── SHA256 verification ─────────────────────────────────────────────────────
if [ -n "$IMG_SHA256" ]; then
    msg "Verifying SHA256..."
    ACTUAL_SHA256=$(sha256sum "$OWRT_GZ" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$IMG_SHA256" ]; then
        rm -f "$OWRT_GZ"
        err "SHA256 mismatch! Expected: $IMG_SHA256  Got: $ACTUAL_SHA256"
    fi
    msg "SHA256 OK."
else
    warn "SHA256 not verified (checksum not found in sha256sums)."
fi

# ─── Decompress image ────────────────────────────────────────────────────────
msg "Decompressing image..."
gzip -dcq "$OWRT_GZ" > "$OWRT_TMP" || err "Decompression failed."
[ ! -s "$OWRT_TMP" ] && err "Decompressed image is empty."
msg "Decompressed: $(du -sh "$OWRT_TMP" | cut -f1)"

# ─── Patch rootfs ────────────────────────────────────────────────────────────
msg "Patching rootfs..."
modprobe loop >/dev/null 2>&1 || true

OFFSET=$(fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null \
    | grep -i "linux" | tail -n1 | awk '{print $1 * 512}')
[ -z "$OFFSET" ] && err "Cannot detect Linux partition offset in image."
msg "Rootfs partition offset: $OFFSET bytes"

MNT="/tmp/owrt_mod/rootfs"
mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
mount -o loop,offset="$OFFSET" "$OWRT_TMP" "$MNT" || err "Failed to mount rootfs."

# ── Хеш пароля SHA-512 (совместим с busybox/OpenWRT) ─────────────────────────
PASS_SALT=$(openssl rand -hex 8)
PASS_HASH=$(openssl passwd -6 -salt "$PASS_SALT" "$PASS_RAW")

# ── UCI defaults ──────────────────────────────────────────────────────────────
mkdir -p "$MNT/etc/uci-defaults"
cat > "$MNT/etc/uci-defaults/99_vps_config" << EOF
#!/bin/sh

# SSH (dropbear)
uci set dropbear.@dropbear[0].Port='${SSH_PORT}'
uci set dropbear.@dropbear[0].PasswordAuth='on'
uci set dropbear.@dropbear[0].RootPasswordAuth='on'
uci commit dropbear

# LuCI HTTP (uhttpd)
uci del uhttpd.main.listen_http  2>/dev/null || true
uci del uhttpd.main.listen_https 2>/dev/null || true
uci add_list uhttpd.main.listen_http='0.0.0.0:${LUCI_PORT}'
uci add_list uhttpd.main.listen_http='[::]:${LUCI_PORT}'
uci commit uhttpd

# DNS
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

# Disable dnsmasq (не нужен на VPS без LAN)
[ -f /usr/sbin/dnsmasq ] && mv /usr/sbin/dnsmasq /usr/sbin/dnsmasq.bak 2>/dev/null || true
/etc/init.d/dnsmasq disable 2>/dev/null || true

# Firewall: Allow SSH
uci add firewall rule
uci set "firewall.@rule[-1].name=Allow-VPS-SSH"
uci set "firewall.@rule[-1].src=wan"
uci set "firewall.@rule[-1].dest_port=${SSH_PORT}"
uci set "firewall.@rule[-1].proto=tcp"
uci set "firewall.@rule[-1].target=ACCEPT"

# Firewall: Allow LuCI
uci add firewall rule
uci set "firewall.@rule[-1].name=Allow-VPS-LuCI"
uci set "firewall.@rule[-1].src=wan"
uci set "firewall.@rule[-1].dest_port=${LUCI_PORT}"
uci set "firewall.@rule[-1].proto=tcp"
uci set "firewall.@rule[-1].target=ACCEPT"

uci commit firewall

exit 0
EOF
chmod +x "$MNT/etc/uci-defaults/99_vps_config"

# ── Сетевая конфигурация ──────────────────────────────────────────────────────
cat > "$MNT/etc/config/network" << EOF
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0.10'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.1.1'
    option netmask '255.255.255.0'

config interface 'wan'
    option device 'eth0'
    option proto 'static'
    option ipaddr '${WAN_IP}'
    option netmask '${WAN_MASK}'
    option gateway '${WAN_GW}'
EOF

# ── Пароль root ───────────────────────────────────────────────────────────────
if [ -f "$MNT/etc/shadow" ]; then
    ESCAPED_HASH=$(printf '%s\n' "$PASS_HASH" | sed 's/[\/&$]/\\&/g')
    sed -i "s|^root:[^:]*:|root:${ESCAPED_HASH}:|" "$MNT/etc/shadow"
    msg "Password hash written to /etc/shadow"
else
    warn "/etc/shadow not found in image — password not set!"
fi

umount "$MNT"
msg "Rootfs patched successfully."

# ─── Compress patched image ───────────────────────────────────────────────────
msg "Compressing patched image..."
gzip -cq "$OWRT_TMP" > "$OWRT_GZ"
rm -f "$OWRT_TMP"
msg "Compressed: $(du -sh "$OWRT_GZ" | cut -f1)"

# ─── Initramfs hook ───────────────────────────────────────────────────────────
msg "Preparing initramfs hook..."
cat > /etc/initramfs-tools/hooks/owrt_image << 'HOOK_EOF'
#!/bin/sh
[ "$1" = "prereqs" ] && echo "" && exit 0
. /usr/share/initramfs-tools/hook-functions
copy_file raw /tmp/owrt.img.gz /owrt.img.gz
copy_exec /bin/gzip
copy_exec /bin/dd
copy_exec /bin/lsblk
HOOK_EOF
chmod +x /etc/initramfs-tools/hooks/owrt_image

# ─── Initramfs takeover script ────────────────────────────────────────────────
msg "Preparing initramfs takeover script..."
cat > /etc/initramfs-tools/scripts/init-premount/takeover << 'TAKEOVER_EOF'
#!/bin/sh
[ "$1" = "prereqs" ] && exit 0
sleep 5
T_DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | head -n1)
[ -z "$T_DISK" ] && echo "[takeover] ERROR: no disk found" && exit 1
echo "[takeover] Writing OpenWRT to $T_DISK ..."
gzip -dcq /owrt.img.gz 2>/dev/null | dd of="$T_DISK" bs=4M status=none conv=fsync
sync
echo "[takeover] Done. Rebooting..."
reboot -f
TAKEOVER_EOF
chmod +x /etc/initramfs-tools/scripts/init-premount/takeover

# ─── Rebuild initramfs ────────────────────────────────────────────────────────
msg "Rebuilding initramfs (this may take ~30s)..."
CURRENT_KERNEL=$(uname -r)
update-initramfs -u -k "$CURRENT_KERNEL" 2>&1 | tail -5
msg "Initramfs updated for kernel $CURRENT_KERNEL."

# ─── Final output ─────────────────────────────────────────────────────────────
echo ""
echo -e "${G}════════════════════════════════════════════════${N}"
echo -e "${G}  OpenWRT ${LATEST_VER} Install Ready — SAVE THIS!  ${N}"
echo -e "${G}════════════════════════════════════════════════${N}"
echo -e "  WAN IP    : ${Y}${WAN_IP}${N}"
echo -e "  SSH       : ${Y}ssh root@${WAN_IP} -p ${SSH_PORT}${N}"
echo -e "  LuCI UI   : ${Y}http://${WAN_IP}:${LUCI_PORT}${N}"
echo -e "  Password  : ${Y}${PASS_RAW}${N}"
echo -e "${G}════════════════════════════════════════════════${N}"
echo ""
warn "System will reboot in 10 seconds and write OpenWRT to disk."
warn "Your current SSH session WILL be dropped. This is irreversible!"
echo ""

sleep 10
reboot -f
