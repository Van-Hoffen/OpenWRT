#!/bin/bash

set -e

# Formatting
G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'
msg() { echo -e "${G}[*]${N} $1"; }
err() { echo -e "${R}[!] ERROR:${N} $1"; exit 1; }

# 1. Network Discovery
msg "Collecting network data..."
ACTIVE_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
[ -z "$ACTIVE_IF" ] && err "Active interface not found."

ADDR_CIDR=$(ip -4 addr show "$ACTIVE_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
WAN_IP=${ADDR_CIDR%/*}
WAN_PREFIX=${ADDR_CIDR#*/}
WAN_GW=$(ip route | grep default | awk '{print $3}')

cdr2mask() {
  local i mask=""
  local full_octets=$(($1 / 8))
  local partial_octet=$(($1 % 8))
  for ((i=0; i<4; i++)); do
    if [ $i -lt $full_octets ]; then mask+="255"
    elif [ $i -eq $full_octets ]; then mask+=$((256 - 2**(8 - $partial_octet)))
    else mask+="0"; fi
    [ $i -lt 3 ] && mask+="."
  done
  echo $mask
}
WAN_MASK=$(cdr2mask ${WAN_PREFIX:-24})

# 2. Dependencies
msg "Installing tools..."
apt-get update -y >/dev/null 2>&1
apt-get install -y curl gzip util-linux fdisk initramfs-tools openssl kmod >/dev/null 2>&1

# 3. Image Preparation
msg "Downloading OpenWRT image..."
URL="https://downloads.openwrt.org/releases/23.05.0/targets/x86/64/openwrt-23.05.0-x86-64-generic-ext4-combined.img.gz"
curl -L "$URL" -s | gzip -dcq > /tmp/owrt.img 2>/dev/null || true
[ ! -s /tmp/owrt.img ] && err "Image download failed."

# 4. Patching
msg "Patching rootfs..."
modprobe loop >/dev/null 2>&1 || true
OFFSET=$(fdisk -l /tmp/owrt.img -o Start,Type | grep "Linux" | tail -n1 | awk '{print $1 * 512}')
mkdir -p /tmp/owrt_mod/rootfs
mount -o loop,offset="$OFFSET" /tmp/owrt.img /tmp/owrt_mod/rootfs

cat <<EOF > /tmp/owrt_mod/rootfs/etc/uci-defaults/99_final_fix
#!/bin/sh
uci set dropbear.@dropbear[0].Port='${SSH_PORT:-42222}'
uci del uhttpd.main.listen_http
uci add_list uhttpd.main.listen_http='0.0.0.0:8880'
uci add_list uhttpd.main.listen_http='[::]:8880'

# Firewall: Allow SSH
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-SSH'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='${SSH_PORT:-42222}'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

# Firewall: Allow LuCI (Web UI)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-LuCI'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='8880'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit
printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
[ -f /usr/sbin/dnsmasq ] && mv /usr/sbin/dnsmasq /usr/sbin/dnsmasq.bak
/etc/init.d/dnsmasq disable
exit 0
EOF
chmod +x /tmp/owrt_mod/rootfs/etc/uci-defaults/99_final_fix

cat <<EOF > /tmp/owrt_mod/rootfs/etc/config/network
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
    option ipaddr '$WAN_IP'
    option netmask '$WAN_MASK'
    option gateway '$WAN_GW'
EOF

PASS_RAW="${SSH_PASS:-root}"
PASS_HASH=$(openssl passwd -1 "$PASS_RAW")
sed -i "s|^root:[^:]*:|root:$PASS_HASH:| " /tmp/owrt_mod/rootfs/etc/shadow

umount /tmp/owrt_mod/rootfs
gzip -cq /tmp/owrt.img > /tmp/owrt.img.gz 2>/dev/null
rm /tmp/owrt.img

# 5. Initramfs Setup
msg "Preparing initramfs..."
cat <<EOF > /etc/initramfs-tools/hooks/owrt_image
#!/bin/sh
[ "\$1" = "prereqs" ] && echo "" && exit 0
. /usr/share/initramfs-tools/hook-functions
copy_file raw /tmp/owrt.img.gz /owrt.img.gz
copy_exec /bin/gzip
copy_exec /bin/dd
copy_exec /bin/lsblk
EOF
chmod +x /etc/initramfs-tools/hooks/owrt_image

cat <<EOF > /etc/initramfs-tools/scripts/init-premount/takeover
#!/bin/sh
[ "\$1" = "prereqs" ] && exit 0
sleep 5
T_DISK=\$(lsblk -ndo NAME,TYPE | grep disk | head -n1 | awk '{print "/dev/" \$1}')
[ -z "\$T_DISK" ] && exit 1
gzip -dcq /owrt.img.gz 2>/dev/null | dd of=\$T_DISK bs=4M status=none
sync
reboot -f
EOF
chmod +x /etc/initramfs-tools/scripts/init-premount/takeover

update-initramfs -u >/dev/null 2>&1
msg "SUCCESS! Rebooting to OpenWRT in 5s."
msg "WAN IP: $WAN_IP"
msg "LuCI UI: http://$WAN_IP:8880"
msg "SSH: port ${SSH_PORT:-42222}, user root, pass $PASS_RAW"
sleep 5
reboot -f
