# OpenWRT on Debian VPS — Install Script

Автоматическая установка OpenWRT поверх Debian/Ubuntu на KVM VPS.

## Быстрый старт

```bash
curl -sSL https://raw.githubusercontent.com/Van-Hoffen/OpenWRT/main/install-on-debian/install_openwrt_debian.sh -o install.sh
bash install.sh
```

## Что делает скрипт

1. Скачивает последний стабильный образ OpenWRT x86/64
2. Патчит rootfs прямо в образе (uci-defaults, сеть, пароль)
3. Встраивает образ в initramfs и перезагружается — Debian заменяется OpenWRT

## Интерактивная настройка

При запуске скрипт спросит:

| Параметр | По умолчанию | Описание |
|---|---|---|
| SSH port | случайный | Порт dropbear |
| LuCI port | случайный | Порт веб-интерфейса |
| Root password | случайный 16 симв. | Пароль root |
| WireGuard | опционально | Сервер WG, порт, подсеть |
| PODKOP | опционально | VLESS URL, списки, DNS |

## Что настраивается автоматически

- **DNS**: `1.1.1.1` / `8.8.8.8`, `peerdns=0` на WAN — работает сразу после загрузки
- **WireGuard** (если выбран): генерация ключей, UCI конфиг `wg0`, правило firewall UDP, pubkey выводится в `/etc/banner` при входе
- **PODKOP + sing-box** (если выбран): установка, UCI конфиг с VLESS URL и списками community lists, `singbox-tmpdir` init.d (START=19)
- **Firewall**: правила для SSH и LuCI открываются с WAN

## Требования

- KVM VPS (OpenVZ/LXC **не поддерживается**)
- Debian 10/11/12 или Ubuntu 20.04+
- x86_64
- Root доступ
- 2+ GB RAM рекомендуется

## После установки

Первая загрузка OpenWRT запускает `uci-defaults` — скрипты настройки выполняются **один раз** и удаляются. Если выбран WireGuard — публичный ключ сервера будет виден при SSH-входе (`/etc/banner`).

### Добавить WireGuard клиента

```bash
# На OpenWRT
wg genkey | tee /etc/wireguard/client1.key | wg pubkey > /etc/wireguard/client1.pub
# Добавить пир через LuCI: Network → Interfaces → wg0 → Peers
```

### Если VLESS URL не задан при установке

LuCI → Services → Podkop → Main section → Proxy string

## Известные ограничения

- `dnsmasq` отключён — DNS идёт напрямую через resolv.conf (`1.1.1.1`)
- После установки `apk` требует DNS — скрипт `10_dns_fix` решает это автоматически
- `/tmp/sing-box` исчезает при ребуте — `singbox-tmpdir` init.d пересоздаёт его при старте
