#!/bin/bash
# =======================================================
# OpenWRT: тест автоопределения версии + grub.cfg
# НЕ перезаписывает диск, НЕ делает reboot
# =======================================================

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
msg()  { echo -e "${G}[*]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[ERR]${N} $1"; }

OWRT_BASE="https://downloads.openwrt.org/releases"
FALLBACK="25.12.4"

# -------------------------------------------------------
# 1. Диагностика curl
# -------------------------------------------------------
msg "--- Шаг 1: диагностика curl ---"
msg "curl version:"
curl --version 2>&1 | head -2

msg "Прямой тест curl (verbose, таймаут 15с):"
curl -v --connect-timeout 15 -o /dev/null "${OWRT_BASE}/" 2>&1 | grep -E '^[<>*]|HTTP|SSL|connect|Could not'
CURL_CODE=$?
msg "curl exit code: $CURL_CODE"

# -------------------------------------------------------
# 2. Попытки получить список версий
# -------------------------------------------------------
echo ""
msg "--- Шаг 2: получение списка версий ---"

msg "Попытка 1 — curl без проверки сертификата:"
RAW=$(curl -sSLk --connect-timeout 15 "${OWRT_BASE}/" 2>/dev/null)
if [ -n "$RAW" ]; then
    msg "Ответ получен ($(echo "$RAW" | wc -c) байт)"
    msg "Первые 10 строк:"
    echo "$RAW" | head -10
else
    warn "curl -k тоже вернул пустой ответ"
fi

msg "Попытка 2 — wget как альтернатива:"
RAW_WGET=$(wget -qO- --timeout=15 "${OWRT_BASE}/" 2>/dev/null)
if [ -n "$RAW_WGET" ]; then
    msg "wget вернул данные ($(echo "$RAW_WGET" | wc -c) байт)"
    msg "Первые 10 строк:"
    echo "$RAW_WGET" | head -10
else
    warn "wget тоже вернул пустой ответ"
fi

# Используем тот источник который сработал
DATA=""
[ -n "$RAW" ]      && DATA="$RAW"
[ -z "$DATA" ] && [ -n "$RAW_WGET" ] && DATA="$RAW_WGET"

# -------------------------------------------------------
# 3. Парсинг версий
# -------------------------------------------------------
echo ""
msg "--- Шаг 3: парсинг версий ---"
LATEST=""
if [ -n "$DATA" ]; then
    msg "regex (grep -oP):"
    VER_LIST=$(echo "$DATA" | grep -oP '(?<=>)\d+\.\d+\.\d+(?=/)' 2>/dev/null || true)
    echo "$VER_LIST"
    LATEST=$(echo "$VER_LIST" | sort -V | tail -n1)

    if [ -z "$LATEST" ]; then
        warn "grep -oP не нашёл, пробуем grep -o:"
        VER_LIST2=$(echo "$DATA" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | sort -Vu)
        echo "$VER_LIST2"
        LATEST=$(echo "$VER_LIST2" | sort -V | tail -n1)
    fi
fi

if [ -n "$LATEST" ]; then
    msg "Автоопределение: ${Y}${LATEST}${N}"
else
    warn "Автоопределение не удалось, fallback: ${Y}${FALLBACK}${N}"
    LATEST="$FALLBACK"
fi

# -------------------------------------------------------
# 4. Проверка доступности sha256sums
# -------------------------------------------------------
echo ""
msg "--- Шаг 4: sha256sums для версии ${LATEST} ---"
SHA_URL="${OWRT_BASE}/${LATEST}/targets/x86/64/sha256sums"
msg "URL: $SHA_URL"
SHA_LIST=$(curl -sSLk --connect-timeout 15 "$SHA_URL" 2>/dev/null)
if [ -n "$SHA_LIST" ]; then
    msg "sha256sums получен. Образы:"
    echo "$SHA_LIST" | grep 'ext4-combined'
else
    warn "sha256sums недоступен"
fi

# -------------------------------------------------------
# 5. grub.cfg — поиск в уже скачанном образе
# -------------------------------------------------------
echo ""
msg "--- Шаг 5: поиск grub.cfg в образе ---"
OWRT_TMP=""
if [ -f /tmp/owrt.img ]; then
    msg "Найден /tmp/owrt.img ($(du -sh /tmp/owrt.img | cut -f1))"
    OWRT_TMP=/tmp/owrt.img
elif [ -f /tmp/owrt.img.gz ]; then
    msg "Найден /tmp/owrt.img.gz — распаковываем..."
    gzip -dcq /tmp/owrt.img.gz > /tmp/owrt_test.img
    OWRT_TMP=/tmp/owrt_test.img
else
    warn "Образ не найден в /tmp. Запусти основной скрипт хотя бы до стадии патчинга."
fi

if [ -n "$OWRT_TMP" ]; then
    msg "fdisk -l:"
    fdisk -l "$OWRT_TMP" 2>/dev/null | grep -E 'Disk|Device|Linux'

    # Ищем ОБА раздела — FAT (boot) и Linux (rootfs)
    msg "Все разделы:"
    fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null

    FAT_OFFSET=$(fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null | grep -i 'fat\|efi\|W95' | head -1 | awk '{print $1 * 512}')
    LINUX_OFFSET=$(fdisk -l "$OWRT_TMP" -o Start,Type 2>/dev/null | grep -i 'linux' | tail -1 | awk '{print $1 * 512}')
    msg "FAT offset   : ${FAT_OFFSET:-не найден}"
    msg "Linux offset : ${LINUX_OFFSET:-не найден}"

    MNT=/tmp/owrt_test_mnt
    mkdir -p "$MNT"

    # Монтируем FAT раздел если есть
    if [ -n "$FAT_OFFSET" ] && [ "$FAT_OFFSET" -gt 0 ] 2>/dev/null; then
        msg "Монтируем FAT (boot) раздел (offset=$FAT_OFFSET)..."
        if mount -o loop,offset="$FAT_OFFSET" "$OWRT_TMP" "$MNT" 2>/dev/null; then
            msg "Дерево FAT раздела:"
            find "$MNT" 2>/dev/null | head -40
            msg "Поиск grub.cfg:"
            find "$MNT" -name 'grub.cfg' 2>/dev/null || warn "grub.cfg не найден в FAT разделе"
            umount "$MNT"
        else
            warn "Монтирование FAT раздела не удалось"
        fi
    fi

    # Монтируем Linux раздел
    if [ -n "$LINUX_OFFSET" ] && [ "$LINUX_OFFSET" -gt 0 ] 2>/dev/null; then
        msg "Монтируем Linux (rootfs) раздел (offset=$LINUX_OFFSET)..."
        if mount -o loop,offset="$LINUX_OFFSET" "$OWRT_TMP" "$MNT" 2>/dev/null; then
            msg "Дерево /boot в rootfs:"
            find "$MNT/boot" 2>/dev/null | head -20 || warn "/boot пуст или отсутствует"
            msg "Поиск grub.cfg в rootfs:"
            find "$MNT" -name 'grub.cfg' 2>/dev/null || warn "grub.cfg не найден в rootfs"
            umount "$MNT"
        else
            warn "Монтирование Linux раздела не удалось"
        fi
    fi
fi

echo ""
msg "=== Готово. Никаких изменений в системе не сделано. ==="
