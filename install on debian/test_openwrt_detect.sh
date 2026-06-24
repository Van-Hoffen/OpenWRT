#!/bin/bash
# =======================================================
# OpenWRT: тест автоопределения версии + grub.cfg
# НЕ перезаписывает диск, НЕ делает reboot
# =======================================================

G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
msg()  { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }

OWRT_BASE="https://downloads.openwrt.org/releases"
FALLBACK="25.12.4"

# -------------------------------------------------------
# 1. Автоопределение версии
# -------------------------------------------------------
msg "--- Шаг 1: автоопределение версии ---"
RAW=$(curl -sSLk --connect-timeout 15 "${OWRT_BASE}/" 2>/dev/null)
[ -z "$RAW" ] && RAW=$(wget -qO- --timeout=15 "${OWRT_BASE}/" 2>/dev/null)

# Фильтр: только версии формата YY.MM.x где YY >= 21
# sort -V = версионная сортировка (не лексикографическая!)
LATEST=$(echo "$RAW" \
    | grep -o '[0-9][0-9]\.[0-9][0-9]*\.[0-9][0-9]*' \
    | grep -E '^(2[1-9]|[3-9][0-9])\.' \
    | sort -V \
    | tail -n1)

if [ -n "$LATEST" ]; then
    msg "Автоопределение: ${Y}${LATEST}${N}"
else
    warn "Не удалось, fallback: ${Y}${FALLBACK}${N}"
    LATEST="$FALLBACK"
fi

# -------------------------------------------------------
# 2. sha256sums + поиск образа
# -------------------------------------------------------
echo ""
msg "--- Шаг 2: sha256sums для ${LATEST} ---"
SHA_URL="${OWRT_BASE}/${LATEST}/targets/x86/64/sha256sums"
SHA_LIST=$(curl -sSLk --connect-timeout 15 "$SHA_URL" 2>/dev/null)
IMG_NAME=$(echo "$SHA_LIST" | grep -o 'openwrt-[^ ]*ext4-combined\.img\.gz' | head -1)
[ -z "$IMG_NAME" ] && IMG_NAME=$(echo "$SHA_LIST" | grep -o 'openwrt-[^ ]*ext4-combined-efi\.img\.gz' | head -1)

if [ -n "$IMG_NAME" ]; then
    IMG_URL="${OWRT_BASE}/${LATEST}/targets/x86/64/${IMG_NAME}"
    msg "Образ: ${Y}${IMG_NAME}${N}"
    msg "URL: ${IMG_URL}"
else
    warn "Образ не найден в sha256sums"
fi

# -------------------------------------------------------
# 3. grub.cfg
# -------------------------------------------------------
echo ""
msg "--- Шаг 3: поиск grub.cfg ---"

OWRT_IMG=""
for CANDIDATE in /tmp/owrt.img /tmp/owrt_test.img; do
    if [ -f "$CANDIDATE" ] && [ -s "$CANDIDATE" ]; then
        msg "Используем ${CANDIDATE} ($(du -sh "$CANDIDATE" | cut -f1))"
        OWRT_IMG="$CANDIDATE"
        break
    fi
done

if [ -z "$OWRT_IMG" ]; then
    for GZ in /tmp/owrt.img.gz /tmp/owrt_test.img.gz; do
        if [ -f "$GZ" ] && [ -s "$GZ" ]; then
            msg "Распаковываем ${GZ}..."
            gzip -dcq "$GZ" > /tmp/owrt_test.img
            OWRT_IMG=/tmp/owrt_test.img
            break
        fi
    done
fi

if [ -z "$OWRT_IMG" ] && [ -n "$IMG_URL" ]; then
    msg "Скачиваем образ..."
    curl -L --progress-bar --connect-timeout 30 "$IMG_URL" -o /tmp/owrt_test.img.gz
    gzip -dcq /tmp/owrt_test.img.gz > /tmp/owrt_test.img
    OWRT_IMG=/tmp/owrt_test.img
fi

if [ -n "$OWRT_IMG" ]; then
    LODEV=$(losetup -fP --show "$OWRT_IMG" 2>/dev/null)
    if [ -n "$LODEV" ]; then
        msg "losetup: $LODEV"
        lsblk -o NAME,SIZE,FSTYPE,LABEL "$LODEV" 2>/dev/null
        echo ""
        MNT=/tmp/owrt_test_mnt
        mkdir -p "$MNT"
        for PART in ${LODEV}p1 ${LODEV}p2 ${LODEV}p3; do
            [ -b "$PART" ] || continue
            msg "--- $PART ---"
            if mount -o ro "$PART" "$MNT" 2>/dev/null; then
                GRUB=$(find "$MNT" -name 'grub.cfg' 2>/dev/null | head -3)
                if [ -n "$GRUB" ]; then
                    msg "✅ GRUB.CFG найден в $PART:"
                    echo "$GRUB"
                    msg "Содержимое:"
                    cat "$(echo "$GRUB" | head -1)"
                else
                    warn "grub.cfg нет в $PART"
                    find "$MNT" 2>/dev/null | head -15
                fi
                umount "$MNT"
            else
                warn "Монтирование $PART не удалось"
            fi
        done
        losetup -d "$LODEV"
    else
        warn "losetup не сработал"
        fdisk -l "$OWRT_IMG" 2>/dev/null || warn "fdisk тоже не сработал"
    fi
else
    warn "Нечего монтировать"
fi

echo ""
msg "=== Готово. Никаких изменений в системе не сделано. ==="
