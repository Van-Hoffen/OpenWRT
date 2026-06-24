#!/bin/bash
# =======================================================
# OpenWRT: тест автоопределения версии + grub.cfg
# НЕ перезаписывает диск, НЕ делает reboot
# =======================================================

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
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

# grep -oP не работает на HTML этого сайта (нет шаблона >VER/)
# Используем grep -o + фильтр по формату YY.MM.N (не берём snapshotXY)
LATEST=$(echo "$RAW" \
    | grep -o '[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]*' \
    | grep -v '^[0-9]\{1,2\}\.[0-9]\{1,2\}\.[0-9]$' \
    | sort -Vu \
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
# 3. grub.cfg: скачать если нет в /tmp
# -------------------------------------------------------
echo ""
msg "--- Шаг 3: поиск grub.cfg ---"

OWRT_IMG=""
if [ -f /tmp/owrt.img ]; then
    msg "Используем /tmp/owrt.img"
    OWRT_IMG=/tmp/owrt.img
elif [ -f /tmp/owrt.img.gz ]; then
    msg "Распаковываем /tmp/owrt.img.gz..."
    gzip -dcq /tmp/owrt.img.gz > /tmp/owrt_test.img
    OWRT_IMG=/tmp/owrt_test.img
elif [ -n "$IMG_URL" ]; then
    msg "Скачиваем образ..."
    curl -L --progress-bar --connect-timeout 30 "$IMG_URL" -o /tmp/owrt_test.img.gz
    msg "Распаковываем..."
    gzip -dcq /tmp/owrt_test.img.gz > /tmp/owrt_test.img
    OWRT_IMG=/tmp/owrt_test.img
else
    warn "Нечего монтировать"
fi

if [ -n "$OWRT_IMG" ]; then
    msg "Размер образа: $(du -sh "$OWRT_IMG" | cut -f1)"

    # losetup: надёжнее чем fdisk для образов
    msg "Партиции через losetup:"
    LODEV=$(losetup -fP --show "$OWRT_IMG" 2>/dev/null)
    if [ -n "$LODEV" ]; then
        lsblk -o NAME,SIZE,FSTYPE,LABEL "$LODEV" 2>/dev/null
        echo ""
        MNT=/tmp/owrt_test_mnt
        mkdir -p "$MNT"
        # Перебираем все партиции
        for PART in ${LODEV}p1 ${LODEV}p2 ${LODEV}p3; do
            [ -b "$PART" ] || continue
            msg "Пробуем смонтировать $PART..."
            if mount -o ro "$PART" "$MNT" 2>/dev/null; then
                GRUB=$(find "$MNT" -name 'grub.cfg' 2>/dev/null | head -3)
                if [ -n "$GRUB" ]; then
                    msg "НАШЛО в $PART:"
                    echo "$GRUB"
                    msg "Первые 5 строк grub.cfg:"
                    head -5 "$(echo "$GRUB" | head -1)"
else
                    warn "grub.cfg не найден в $PART"
                    msg "Дерево $PART:"
                    find "$MNT" 2>/dev/null | head -20
                fi
                umount "$MNT"
            else
                warn "Монтирование $PART не удалось"
            fi
        done
        losetup -d "$LODEV"
    else
        warn "losetup не сработал, пробуем fdisk..."
        fdisk -l "$OWRT_IMG" 2>/dev/null || warn "fdisk тоже не сработал"
    fi
fi

echo ""
msg "=== Готово. Никаких изменений в системе не сделано. ==="
