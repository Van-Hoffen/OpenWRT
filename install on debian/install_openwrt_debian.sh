#!/bin/bash

set -e

# Formatting
G='\033[0;32m'
Y='\033[1;33m'
R='\033[0;31m'
C='\033[0;36m'
B='\033[1;34m'
N='\033[0m'
msg()    { echo -e "${G}[*]${N} $1"; }
warn()   { echo -e "${Y}[!]${N} $1"; }
err()    { echo -e "${R}[!] ERROR:${N} $1"; exit 1; }
section(){ echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; echo -e "${B}  $1${N}"; echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }
ask()    { echo -e "${C}[?]${N} $1"; }

read_tty() {
    if [ -t 0 ]; then
        read -r "$1"
    else
        read -r "$1" < /dev/tty
    fi
}

# ─── Sanity checks ───────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && err "Must run as root."
[ "$(uname -m)" != "x86_64" ] && err "Only x86_64 is supported."
if systemd-detect-virt 2>/dev/null | grep -qiE "openvz|lxc"; then
    err "OpenVZ/LXC is not supported. Use a KVM-based VPS."
fi

# ─── Dependencies ────────────────────────────────────────────────────────────
msg "Installing base dependencies..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl gzip util-linux fdisk initramfs-tools openssl kmod >/dev/null 2>&1
msg "Dependencies installed."

# ─── Interactive setup ───────────────────────────────────────────────────────
section "OpenWRT VPS Installer — Interactive Setup"

ask "SSH port [random]: "
read_tty INPUT_SSH_PORT
SSH_PORT=${INPUT_SSH_PORT:-$(shuf -i 10000-59999 -n1)}

ask "LuCI web UI port [random]: "
read_tty INPUT_LUCI_PORT
LUCI_PORT=${INPUT_LUCI_PORT:-$(shuf -i 10000-59999 -n1)}
while [ "$LUCI_PORT" -eq "$SSH_PORT" ] 2>/dev/null; do
    LUCI_PORT=$(shuf -i 10000-59999 -n1)
done

ask "Root password [random 16 chars]: "
read_tty INPUT_PASS
PASS_RAW="${INPUT_PASS:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)}"

echo ""
msg "SSH port  : ${Y}${SSH_PORT}${N}"
msg "LuCI port : ${Y}${LUCI_PORT}${N}"
msg "Password  : ${Y}${PASS_RAW}${N}"
echo ""
warn "SAVE THIS INFORMATION NOW — it won't be shown after reboot!"
echo ""

# ─── WireGuard ───────────────────────────────────────────────────────────────
section "WireGuard Server (optional)"

INSTALL_WG=0
ask "Install WireGuard server? [y/N]: "
read_tty YN
if echo "$YN" | grep -qiE "^y(es)?$"; then
    INSTALL_WG=1
    ask "WireGuard listen port [51820]: "
    read_tty INPUT_WG_PORT
    WG_PORT=${INPUT_WG_PORT:-51820}
    ask "WireGuard internal network [10.8.0.0/24]: "
    read_tty INPUT_WG_NET
    WG_NET=${INPUT_WG_NET:-10.8.0.0/24}
    WG_SERVER_IP=$(echo "$WG_NET" | sed 's|\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*/.*|\1.1|')
    WG_PREFIX=$(echo "$WG_NET" | cut -d/ -f2)
    msg "WireGuard port   : ${Y}${WG_PORT}${N}"
    msg "Server WG IP     : ${Y}${WG_SERVER_IP}/${WG_PREFIX}${N}"
fi

# ─── PODKOP ──────────────────────────────────────────────────────────────────
section "PODKOP + sing-box (optional)"

INSTALL_PODKOP=0
ask "Install PODKOP (bypass censorship)? [y/N]: "
read_tty YN
if echo "$YN" | grep -qiE "^y(es)?$"; then
    INSTALL_PODKOP=1
    echo ""
    warn "VLESS URL может содержать спецсимволы. Вставьте его и нажмите Enter."
    warn "Если нет VLESS URL сейчас — просто нажмите Enter, добавите позже в LuCI → Services → Podkop"
    echo ""
    ask "VLESS URL (или Enter для пропуска): "
    read_tty VLESS_URL
    echo ""
    msg "Выберите списки для обхода блокировок."
    msg "Список ${Y}russiainside${N} будет добавлен всегда."
    echo ""
    PODKOP_LISTS="russiainside"
    for LIST_NAME in meta telegram twitter discord googleai googleplay; do
        ask "Добавить список '${Y}${LIST_NAME}${N}'? [y/N]: "
        read_tty YN_LIST
        if echo "$YN_LIST" | grep -qiE "^y(es)?$"; then
            PODKOP_LISTS="${PODKOP_LISTS} ${LIST_NAME}"
        fi
    done
    echo ""
    msg "Списки для обхода: ${Y}${PODKOP_LISTS}${N}"
    ask "DNS для PODKOP — doh (рекомендуется) или plain [doh]: "
    read_tty PODKOP_DNS_TYPE
    PODKOP_DNS_TYPE=${PODKOP_DNS_TYPE:-doh}
fi

# ─── Confirm ─────────────────────────────────────────────────────────────────
section "Подтверждение"
echo ""
echo -e "  SSH port  : ${Y}${SSH_PORT}${N}"
echo -e "  LuCI port : ${Y}${LUCI_PORT}${N}"
echo -e "  Password  : ${Y}${PASS_RAW}${N}"
[ "$INSTALL_WG" -eq 1 ] && echo -e "  WireGuard : ${Y}enabled, port ${WG_PORT}, net ${WG_NET}${N}" || echo -e "  WireGuard : ${Y}skip${N}"
if [ "$INSTALL_PODKOP" -eq 1 ]; then
    echo -e "  PODKOP    : ${Y}enabled${N}"
    [ -n "$VLESS_URL" ] && echo -e "  VLESS URL : ${Y}(задан)${N}" || echo -e "  VLESS URL : ${Y}(не задан, добавить позже)${N}"
    echo -e "  Списки    : ${Y}${PODKOP_LISTS}${N}"
else
    echo -e "  PODKOP    : ${Y}skip${N}"
fi
echo ""
warn "Система будет НЕОБРАТИМО перезаписана. Все данные на диске уничтожены."
ask "Продолжить установку? [y/N]: "
read_tty CONFIRM
echo "$CONFIRM" | grep -qiE "^y(es)?$" || { msg "Отменено."; exit 0; }

# ─── Network Discovery ───────────────────────────────────────────────────────
section "Сетевое обнаружение"
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

# ─── Detect latest OpenWRT version ─────────────────────────────────────────────
msg "Detecting latest OpenWRT stable version..."
OWRT_BASE="https://downloads.openwrt.org/releases"
LATEST_VER=$(curl -sSL --connect-timeout 15 "${OWRT_BASE}/" 2>/dev/null \
    | grep -oP '(?<=>)\d+\.\d+\.\d+(?=/)' | sort -V | tail -n1)
[ -z "$LATEST_VER" ] && warn "Auto-detection failed, using 25.12.4" && LATEST_VER="25.12.4"
msg "Detected OpenWRT version: $LATEST_VER"

# ─── Find image ──────────────────────────────────────────────────────────────
TARGET_URL="${OWRT_BASE}/${LATEST_VER}/targets/x86/64"
SHA256_URL="${TARGET_URL}/sha256sums"
msg "Fetching file list..."
SHA256_LIST=$(curl -sSL --connect-timeout 15 "$SHA256_URL" 2>/dev/null)
[ -z "$SHA256_LIST" ] && err "Cannot fetch sha256sums from ${SHA256_URL}"
IMG_NAME=$(echo "$SHA256_LIST" | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined\.img\.gz' | head -n1)
[ -z "$IMG_NAME" ] && IMG_NAME=$(echo "$SHA256_LIST" | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined-efi\.img\.gz' | head -n1)
[ -z "$IMG_NAME" ] && err "Cannot find ext4-combined image."
IMG_URL="${TARGET_URL}/${IMG_NAME}"
IMG_SHA256=$(echo "$SHA256_LIST" | grep "$IMG_NAME" | awk '{print $1}')
msg "Image : $IMG_NAME"

# ─── Download ────────────────────────────────────────────────────────────────
msg "Downloading OpenWRT ${LATEST_VER}..."
OWRT_TMP="/tmp/owrt.img"
OWRT_GZ="/tmp/owrt.img.gz"
curl -L --progress-bar --connect-timeout 30 --retry 3 "$IMG_URL" -o "$OWRT_GZ" || err "Download failed."
[ ! -s "$OWRT_GZ" ] && err "Downloaded file is empty."
msg "Downloaded: $(du -sh "$OWRT_GZ" | cut -f1)"

# ─── SHA256 ────────────────────────────────────────────────────────────────────
if [ -n "$IMG_SHA256" ]; then
    msg "Verifying SHA256..."
    ACTUAL=$(sha256sum "$OWRT_GZ" | awk '{print $1}')
    [ "$ACTUAL" != "$IMG_SHA256" ] && rm -f "$OWRT_GZ" && err "SHA256 mismatch!"
    msg "SHA256 OK."
fi

# ─── Decompress ──────────────────────────────────────────────────────────────
msg "Decompressing image..."
gzip -dcq "$OWRT_GZ" > "$OWRT_TMP" || err "Decompression failed."
[ ! -s "$OWRT_TMP" ] && err "Decompressed image is empty."
msg "Decompressed: $(du -sh "$OWRT_TMP" | cut -f1)"

# ─── Patch rootfs ────────────────────────────────────────────────────────────
section "Патчинг rootfs"
modprobe loop >/dev/null 2>&1 || true
OFFSET=$(fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null | grep -i "linux" | tail -n1 | awk '{print $1 * 512}')
[ -z "$OFFSET" ] && err "Cannot detect Linux partition offset."
MNT="/tmp/owrt_mod/rootfs"
mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
mount -o loop,offset="$OFFSET" "$OWRT_TMP" "$MNT" || err "Failed to mount rootfs."

# ── GRUB: добавляем console=tty0 для VNC/KVM
GRUB_CFG="$MNT/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
    if ! grep -q 'console=tty0' "$GRUB_CFG"; then
        sed -i 's/console=ttyS0/console=tty0 console=ttyS0/g' "$GRUB_CFG"
        msg "GRUB patched: added console=tty0 (VNC/KVM)"
    fi
else
    warn "grub.cfg not found — GRUB patch skipped."
fi

# ── Пароль
PASS_SALT=$(openssl rand -hex 8)
PASS_HASH=$(openssl passwd -6 -salt "$PASS_SALT" "$PASS_RAW")
mkdir -p "$MNT/etc/uci-defaults"

# ── 10_dns_fix
cat > "$MNT/etc/uci-defaults/10_dns_fix" << 'EOF'
#!/bin/sh
[ -f /usr/sbin/dnsmasq ] && mv /usr/sbin/dnsmasq /usr/sbin/dnsmasq.bak 2>/dev/null || true
/etc/init.d/dnsmasq disable 2>/dev/null || true
uci set network.wan.peerdns='0'
uci set network.wan.dns='1.1.1.1 8.8.8.8'
uci commit network
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
exit 0
EOF
chmod +x "$MNT/etc/uci-defaults/10_dns_fix"

# ── 20_vps_base
cat > "$MNT/etc/uci-defaults/20_vps_base" << EOF
#!/bin/sh
uci set dropbear.@dropbear[0].Port='${SSH_PORT}'
uci set dropbear.@dropbear[0].PasswordAuth='on'
uci set dropbear.@dropbear[0].RootPasswordAuth='on'
uci commit dropbear
uci del uhttpd.main.listen_http  2>/dev/null || true
uci del uhttpd.main.listen_https 2>/dev/null || true
uci add_list uhttpd.main.listen_http='0.0.0.0:${LUCI_PORT}'
uci add_list uhttpd.main.listen_http='[::]:${LUCI_PORT}'
uci commit uhttpd
uci add firewall rule
uci set "firewall.@rule[-1].name=Allow-VPS-SSH"
uci set "firewall.@rule[-1].src=wan"
uci set "firewall.@rule[-1].dest_port=${SSH_PORT}"
uci set "firewall.@rule[-1].proto=tcp"
uci set "firewall.@rule[-1].target=ACCEPT"
uci add firewall rule
uci set "firewall.@rule[-1].name=Allow-VPS-LuCI"
uci set "firewall.@rule[-1].src=wan"
uci set "firewall.@rule[-1].dest_port=${LUCI_PORT}"
uci set "firewall.@rule[-1].proto=tcp"
uci set "firewall.@rule[-1].target=ACCEPT"
uci commit firewall
exit 0
EOF
chmod +x "$MNT/etc/uci-defaults/20_vps_base"

# ── 30_wireguard
if [ "$INSTALL_WG" -eq 1 ]; then
    cat > "$MNT/etc/uci-defaults/30_wireguard" << EOF
#!/bin/sh
apk update
apk add wireguard-tools luci-proto-wireguard qrencode
mkdir -p /etc/wireguard
wg genkey > /etc/wireguard/server.key
chmod 600 /etc/wireguard/server.key
wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
SERVER_PRIVKEY=\$(cat /etc/wireguard/server.key)
uci set network.wg0='interface'
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="\${SERVER_PRIVKEY}"
uci set network.wg0.listen_port='${WG_PORT}'
uci add_list network.wg0.addresses='${WG_SERVER_IP}/${WG_PREFIX}'
uci commit network
uci add_list firewall.@zone[0].network='wg0'
uci commit firewall
uci add firewall rule
uci set "firewall.@rule[-1].name=Allow-WireGuard"
uci set "firewall.@rule[-1].src=wan"
uci set "firewall.@rule[-1].dest_port=${WG_PORT}"
uci set "firewall.@rule[-1].proto=udp"
uci set "firewall.@rule[-1].target=ACCEPT"
uci commit firewall
SERVER_PUBKEY=\$(cat /etc/wireguard/server.pub)
echo "" >> /etc/banner
echo "=== WireGuard Server Public Key ===" >> /etc/banner
echo "\${SERVER_PUBKEY}" >> /etc/banner
echo "====================================" >> /etc/banner
exit 0
EOF
    chmod +x "$MNT/etc/uci-defaults/30_wireguard"
fi

# ── 40_podkop
if [ "$INSTALL_PODKOP" -eq 1 ]; then
    VLESS_ESCAPED=$(printf '%s' "$VLESS_URL" | sed "s/'/'\\\\''/g")
    LISTS_UCI=""
    for L in $PODKOP_LISTS; do
        LISTS_UCI="${LISTS_UCI}\nuci add_list podkop.settings.community_lists='${L}'"
    done
    [ -n "$VLESS_URL" ] && VLESS_UCI="uci set podkop.main.proxy_string='${VLESS_ESCAPED}'" \
                        || VLESS_UCI="# VLESS URL не задан — добавьте в LuCI → Services → Podkop"
    cat > "$MNT/etc/uci-defaults/40_podkop" << EOF
#!/bin/sh
mkdir -p /tmp/sing-box
chmod 755 /tmp/sing-box
cat > /etc/init.d/singbox-tmpdir << 'INITEOF'
#!/bin/sh /etc/rc.common
START=19
start() {
    mkdir -p /tmp/sing-box
    chmod 755 /tmp/sing-box
}
INITEOF
chmod +x /etc/init.d/singbox-tmpdir
/etc/init.d/singbox-tmpdir enable
sh \$(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
sleep 3
uci set podkop.settings='settings'
uci set podkop.settings.dns_type='${PODKOP_DNS_TYPE}'
uci set podkop.settings.dns_server='dns.adguard-dns.com'
uci set podkop.settings.bootstrap_dns_server='9.9.9.9'
uci set podkop.settings.enable_output_network_interface='1'
uci set podkop.settings.output_network_interface='eth0'
uci set podkop.settings.cache_path='/tmp/sing-box/cache.db'
uci set podkop.settings.download_lists_via_proxy='1'
uci set podkop.settings.download_lists_via_proxy_section='main'
uci set podkop.settings.update_interval='1d'
uci add_list podkop.settings.source_network_interfaces='br-lan'
EOF
    [ "$INSTALL_WG" -eq 1 ] && echo "uci add_list podkop.settings.source_network_interfaces='wg0'" >> "$MNT/etc/uci-defaults/40_podkop"
    cat >> "$MNT/etc/uci-defaults/40_podkop" << EOF
uci set podkop.main='section'
uci set podkop.main.connection_type='proxy'
uci set podkop.main.proxy_config_type='url'
${VLESS_UCI}
${LISTS_UCI}
uci commit podkop
/etc/init.d/podkop enable
exit 0
EOF
    chmod +x "$MNT/etc/uci-defaults/40_podkop"
fi

# ── Сеть
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
    option peerdns '0'
    option dns '1.1.1.1 8.8.8.8'
EOF

# ── Пароль root
if [ -f "$MNT/etc/shadow" ]; then
    ESCAPED_HASH=$(printf '%s\n' "$PASS_HASH" | sed 's/[\/&$]/\\&/g')
    sed -i "s|^root:[^:]*:|root:${ESCAPED_HASH}:|" "$MNT/etc/shadow"
    msg "Password hash written to /etc/shadow"
else
    warn "/etc/shadow not found!"
fi

umount "$MNT"
msg "Rootfs patched."

# ─── Recompress ────────────────────────────────────────────────────────────
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

# ─── Takeover script (busybox-compatible, как в v1) ─────────────────────────────
msg "Preparing takeover script..."
cat > /etc/initramfs-tools/scripts/init-premount/takeover << 'TAKEOVER_EOF'
#!/bin/sh
[ "$1" = "prereqs" ] && exit 0
sleep 5
T_DISK=$(lsblk -ndo NAME,TYPE | grep disk | head -n1 | awk '{print "/dev/" $1}')
[ -z "$T_DISK" ] && echo "[takeover] ERROR: no disk found" && exit 1
echo "[takeover] Writing OpenWRT to $T_DISK ..."
gzip -dcq /owrt.img.gz 2>/dev/null | dd of=$T_DISK bs=4M status=none
sync
echo "[takeover] Done. Rebooting..."
reboot -f
TAKEOVER_EOF
chmod +x /etc/initramfs-tools/scripts/init-premount/takeover

# ─── Rebuild initramfs ───────────────────────────────────────────────────────────
msg "Rebuilding initramfs..."
update-initramfs -u -k "$(uname -r)" 2>&1 | tail -3
msg "Initramfs ready."

# ─── Final output ────────────────────────────────────────────────────────────
echo ""
echo -e "${G}════════════════════════════════════════════════${N}"
echo -e "${G}  OpenWRT ${LATEST_VER} — SAVE THIS BEFORE REBOOT  ${N}"
echo -e "${G}════════════════════════════════════════════════${N}"
echo -e "  WAN IP   : ${Y}${WAN_IP}${N}"
echo -e "  SSH      : ${Y}ssh root@${WAN_IP} -p ${SSH_PORT}${N}"
echo -e "  LuCI     : ${Y}http://${WAN_IP}:${LUCI_PORT}${N}"
echo -e "  Password : ${Y}${PASS_RAW}${N}"
[ "$INSTALL_WG" -eq 1 ] && echo -e "  WireGuard: ${Y}port ${WG_PORT} — pubkey будет в /etc/banner${N}"
[ "$INSTALL_PODKOP" -eq 1 ] && echo -e "  PODKOP   : ${Y}списки: ${PODKOP_LISTS}${N}"
[ "$INSTALL_PODKOP" -eq 1 ] && [ -z "$VLESS_URL" ] && echo -e "  VLESS    : ${Y}не задан — добавьте в LuCI → Services → Podkop${N}"
echo -e "${G}════════════════════════════════════════════════${N}"
echo ""
warn "Система перезагрузится через 10 секунд и запишет OpenWRT на диск."
warn "Текущая SSH-сессия будет обрвана. Это НЕОБРАТИМО!"
echo ""
sleep 10
reboot -f
