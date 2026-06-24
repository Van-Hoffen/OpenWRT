#!/bin/bash
# =======================================================
# OpenWRT: тест автоопределения версии + grub.cfg
# Запуск: bash test_openwrt_detect.sh
# НЕ перезаписывает диск, НЕ делает reboot
# =======================================================

set -e
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
msg()  { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[!] ERROR:${N} $1"; exit 1; }

OWRT_BASE="https://downloads.openwrt.org/releases"
FALLBACK="25.12.4"

# -------------------------------------------------------
# 1. Автоопределение версии
# -------------------------------------------------------
msg "--- Шаг 1: автоопределение последней стабильной версии ---"
msg "Запрос: ${OWRT_BASE}/"

RAW=$(curl -sSL --connect-timeout 15 "${OWRT_BASE}/" 2>&1)
CURL_EXIT=$?

echo ""
msg "curl exit code: $CURL_EXIT"
msg "Первые 20 строк ответа:"
echo "$RAW" | head -20
echo "..."

msg "Пробуем regex \\d+\\.\\d+\\.\\d+ (grep -oP):"
VER_LIST=$(echo "$RAW" | grep -oP '(?<=>)\d+\.\d+\.\d+(?=/)' 2>/dev/null || true)
echo "Найдено версий: $(echo "$VER_LIST" | grep -c . || echo 0)"
echo "Список:"
echo "$VER_LIST"
LATEST=$(echo "$VER_LIST" | sort -V | tail -n1)
echo ""
if [ -n "$LATEST" ]; then
    msg "Автоопределение: ${Y}${LATEST}${N}"
else
    warn "Ничего не нашли через grep -oP. Пробуем альтернативный regex..."
    VER_LIST2=$(echo "$RAW" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | sort -Vu || true)
    echo "Альтернативный список:"
    echo "$VER_LIST2"
    LATEST=$(echo "$VER_LIST2" | sort -V | tail -n1)
    if [ -n "$LATEST" ]; then
        msg "Автоопределение (alt): ${Y}${LATEST}${N}"
    else
        warn "Автоопределение не удалось, fallback: ${Y}${FALLBACK}${N}"
        LATEST="$FALLBACK"
    fi
fi

# -------------------------------------------------------
# 2. Проверка наличия образа
# -------------------------------------------------------
echo ""
msg "--- Шаг 2: поиск образа для версии ${LATEST} ---"
TARGET_URL="${OWRT_BASE}/${LATEST}/targets/x86/64"
SHA_URL="${TARGET_URL}/sha256sums"
msg "Запрос sha256sums: ${SHA_URL}"
SHA_LIST=$(curl -sSL --connect-timeout 15 "$SHA_URL" 2>/dev/null || true)
if [ -z "$SHA_LIST" ]; then
    warn "sha256sums не получен"
else
    msg "Первые 10 строк sha256sums:"
    echo "$SHA_LIST" | head -10
    IMG=$(echo "$SHA_LIST" | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined\.img\.gz' | head -1)
    [ -z "$IMG" ] && IMG=$(echo "$SHA_LIST" | grep -oP 'openwrt-[\d.]+-x86-64-generic-ext4-combined-efi\.img\.gz' | head -1)
    if [ -n "$IMG" ]; then
        msg "Образ найден: ${Y}${IMG}${N}"
        msg "URL: ${TARGET_URL}/${IMG}"
    else
        warn "Образ не найден в sha256sums"
    fi
fi

# -------------------------------------------------------
# 3. grub.cfg — где он на самом деле
# -------------------------------------------------------
echo ""
msg "--- Шаг 3: поиск grub.cfg в смонтированном образе ---"

if [ -f /tmp/owrt.img ]; then
    msg "Найден /tmp/owrt.img ($(du -sh /tmp/owrt.img | cut -f1)) — используем его."
    OWRT_TMP=/tmp/owrt.img
elif [ -f /tmp/owrt.img.gz ]; then
    msg "Найден /tmp/owrt.img.gz — распаковываем во /tmp/owrt_test.img ..."
    gzip -dcq /tmp/owrt.img.gz > /tmp/owrt_test.img
    OWRT_TMP=/tmp/owrt_test.img
else
    warn "Образ не найден в /tmp. Скачиваем минимально (только для теста grub)..."
    msg "Скачиваем ${LATEST}..."
    IMG_URL="${TARGET_URL}/${IMG}"
    curl -L --progress-bar --connect-timeout 30 "$IMG_URL" -o /tmp/owrt_test.img.gz
    gzip -dcq /tmp/owrt_test.img.gz > /tmp/owrt_test.img
    OWRT_TMP=/tmp/owrt_test.img
fi

msg "fdisk -l на образе:"
fdisk -l "$OWRT_TMP" 2>/dev/null || warn "fdisk не сработал"

msg "Поиск Linux-раздела:"
OFFSET_LINE=$(fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null | grep -i linux | tail -n1)
echo "  Строка: $OFFSET_LINE"
OFFSET=$(echo "$OFFSET_LINE" | awk '{print $1 * 512}')
msg "Offset: $OFFSET байт"

if [ -n "$OFFSET" ] && [ "$OFFSET" -gt 0 ] 2>/dev/null; then
    MNT=/tmp/owrt_test_mnt
    mkdir -p "$MNT"
    mount -o loop,offset="$OFFSET" "$OWRT_TMP" "$MNT" && MOUNTED=1 || MOUNTED=0
    if [ "$MOUNTED" -eq 1 ]; then
        msg "Смонтировано. Дерево /boot:"
        find "$MNT/boot" 2>/dev/null | head -30 || warn "/boot пуст или отсутствует"
        echo ""
        msg "Поиск grub.cfg:"
        find "$MNT" -name 'grub.cfg' 2>/dev/null | head -5 || warn "grub.cfg не найден нигде"
        echo ""
        msg "Поиск *.cfg в образе:"
        find "$MNT" -name '*.cfg' 2>/dev/null | head -10 || true
        umount "$MNT"
    else
        warn "Монтирование не удалось"
    fi
else
    warn "Offset не определён — монтирование пропущено"
fi

echo ""
msg "=== Готово. Никаких изменений в системе не сделано. ==="
