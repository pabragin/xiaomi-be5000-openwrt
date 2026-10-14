# OpenWrt на Xiaomi BE5000 (Airoha AN7563)

**Русский** · [English](README.en.md)

> [!IMPORTANT]
> **Коротко.** Репозиторий описывает, как поставить OpenWrt на Xiaomi BE5000, имея только root-доступ по SSH, и как поднять роутер по UART, если загрузчик сломался.
> - **Главная ловушка:** загрузчик из релизов xinyooo и preloader X-WRT не знают флеш-память **Winbond W25N01KV**. С ней роутер падает на каждом холодном старте с `PANIC at PC : 0x810017a9`.
> - **Здесь лежит загрузчик, который её знает:** [`be5000-bootloader-w25n01kv.bin`](firmware/bootloader/), 57 чипов NAND, U-Boot с автозагрузкой и веб-восстановлением.
> - **Проверено на железе:** один BE5000 (AN7563PT, W25N01KV, 512 МБ DDR3), холодный старт, OpenWrt `be5000-upstream-ppe-20260925`, своя калибровка Wi-Fi.

## Содержание

1. [Что получится](#1-что-получится)
2. [Что нужно](#2-что-нужно)
3. [Установка по SSH](#3-установка-по-ssh) → подробно: [docs/ru/install-ssh.md](docs/ru/install-ssh.md)
4. [Если загрузчик сломался: UART](#4-если-загрузчик-сломался-uart) → подробно: [docs/ru/recovery-uart.md](docs/ru/recovery-uart.md)
5. [Файлы](#5-файлы)
6. [Как это устроено](#6-как-это-устроено) → подробно: [docs/ru/technical.md](docs/ru/technical.md)
7. [Источники и благодарности](#7-источники-и-благодарности)
8. [Открытые вопросы](#8-открытые-вопросы)

## 1. Что получится

| Компонент | Состояние после установки |
|---|---|
| Загрузчик (0x0–0x80000) | BL2 с поддержкой W25N01KV + BL31 + U-Boot 2026.01 (автозагрузка, веб-failsafe на `192.168.1.1`) |
| Калибровка Wi-Fi | заводская EEPROM MT7992 перенесена в блок `0xA0000` (раздел `art`) |
| Прошивка | OpenWrt от [iscle](https://github.com/iscle/openwrt/releases) в разделе `firmware` с `0xC0000` |
| Порты | `lan1`–`lan3` (1 Гбит, DSA) и `eth1` (2.5 Гбит), все в `br-lan` |
| Wi-Fi | 2.4 + 5 ГГц, по умолчанию выключен |

![Разметка флеша](images/flash-layout.svg)

> [!WARNING]
> Новая разметка перезаписывает заводские разделы `bdata` и `Factory`. Вернуться на прошивку Xiaomi можно только из полного бэкапа, который вы снимете на шаге 2.

## 2. Что нужно

- **Root по SSH** на роутере. Неважно, что стоит сейчас: сток Xiaomi, OpenWrt xinyooo/iscle или X-WRT. Какой там U-Boot, знать не нужно, скрипт сам определит разметку.
- **ПК** с `ssh`, `scp`, `python3` (macOS или Linux; на Windows подойдёт WSL).
- **Сетевой кабель** от ПК к LAN-порту роутера.
- **На всякий случай:** USB-UART адаптер 3.3 В. Если запись прервётся, без него роутер не поднять.

## 3. Установка по SSH

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
R=root@192.168.31.1          # адрес роутера сейчас (у стока Xiaomi обычно 192.168.31.1)
```

1. **Проверка.** Записи нет, только отчёт: разметка, доступны ли разделы на запись и **подходит ли загрузчик к вашему чипу NAND** (должно быть `SUPPORTED`).
   ```sh
   scp -O scripts/router/be5000-install.sh $R:/tmp/
   ssh $R sh /tmp/be5000-install.sh check     # всё сразу
   ssh $R sh /tmp/be5000-install.sh nand      # только чип NAND
   ```
   Как определить чип вручную: [docs/ru/install-ssh.md](docs/ru/install-ssh.md#подходит-ли-загрузчик-к-вашему-чипу-nand).
2. **Полный бэкап на ПК** (все разделы, сверка SHA-256). Сохраните его надёжно.
   ```sh
   sh scripts/pc/be5000-backup.sh $R
   ```
3. **Калибровка Wi-Fi** из своего бэкапа. Шаг нужен, только если `check` не написал `already contains MT7992 calibration`.
   ```sh
   python3 scripts/pc/be5000-calibration.py be5000-backup-*/mtd*-Factory.bin calibration.bin
   scp -O calibration.bin $R:/tmp/ && ssh $R sh /tmp/be5000-install.sh calibration /tmp/calibration.bin
   ```
4. **Загрузчик.**
   ```sh
   scp -O firmware/bootloader/be5000-bootloader-w25n01kv.bin $R:/tmp/
   ssh $R sh /tmp/be5000-install.sh bootloader /tmp/be5000-bootloader-w25n01kv.bin
   ```
5. **Прошивка через веб-failsafe.** Перезагрузите роутер. U-Boot не найдёт OpenWrt и откроет страницу восстановления. Задайте ПК адрес `192.168.1.10/24`, откройте `http://192.168.1.1`, загрузите [`openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`](https://github.com/iscle/openwrt/releases/tag/be5000-upstream-ppe-20260925) и нажмите **Proceed**.
6. **Первый вход:** `ssh root@192.168.1.1`, затем `passwd`, после этого настройте Wi-Fi (страна, сеть, пароль).

> [!CAUTION]
> Если `check` показывает, что раздел загрузчика или калибровки `READ-ONLY`, из этой системы их не записать. Варианты описаны в [docs/ru/install-ssh.md](docs/ru/install-ssh.md#если-раздел-read-only). Самый надёжный — UART.

## 4. Если загрузчик сломался: UART

Признаки: тишина в сети, в UART-логе `PANIC at PC : 0x810017a9` или любая остановка до U-Boot.

![Цепочка загрузки](images/boot-chain.svg)

1. Подключите USB-UART: GND–GND, TX↔RX, **VCC не подключать**, 115200 8N1.
   ![Подключение](images/uart-wiring.svg)
2. Запустите `python3 scripts/pc/be5000-uart-recover.py /dev/ttyUSB0`.
3. Замкните **GPIO0 на GND**, держите и включите питание. Где площадка — на [фото](docs/ru/recovery-uart.md#где-gpio0).
4. Скрипт сам пройдёт оба этапа XMODEM и запишет загрузчик. Затем разомкните GPIO0.

Подробно, с фото и таблицей ошибок: [docs/ru/recovery-uart.md](docs/ru/recovery-uart.md).

## 5. Файлы

| Файл | Что это | Куда |
|---|---|---|
| [`firmware/bootloader/be5000-bootloader-w25n01kv.bin`](firmware/bootloader/) | загрузчик 512 КБ: BL2 (57 чипов NAND) + BL31 + U-Boot | флеш `0x0` (SSH: `be5000-install.sh bootloader`; UART: XMODEM №2) |
| [`firmware/bootloader/be5000-uart-bl2-stage1.bin`](firmware/bootloader/) | тот же BL2 в мини-FIP | только UART, XMODEM №1 в BootROM |
| `calibration.bin` (делаете сами) | EEPROM MT7992 вашего роутера, 128 КБ | флеш `0xA0000` |
| OpenWrt `squashfs-sysupgrade.bin` ([iscle](https://github.com/iscle/openwrt/releases/tag/be5000-upstream-ppe-20260925)) | ядро FIT + squashfs | раздел `firmware` `0xC0000` (веб-failsafe или `sysupgrade`) |
| OpenWrt `initramfs-kernel.bin` (iscle) | система в RAM для проверки | TFTP → `bootm`, флеш не трогает |
| [`scripts/router/be5000-install.sh`](scripts/router/be5000-install.sh) | проверка, запись калибровки и загрузчика с проверкой чтением | запускается на роутере |
| [`scripts/pc/`](scripts/pc/) | бэкап, калибровка, UART-восстановление, проверка загрузчика | запускается на ПК |

Контрольные суммы и происхождение бинарников: [firmware/bootloader/README.md](firmware/bootloader/README.md).

## 6. Как это устроено

- **Почему кирпич.** BL2 читает следующую стадию с NAND по своей таблице чипов. В BL2 из xinyooo v2026.05–v2026.06 (и в preloader X-WRT) 56 чипов, W25N01KV нет. С ним BL2 не может прочитать FIP и уходит в `panic()`. После тёплой перезагрузки из Linux иногда грузится, поэтому проверять надо только холодным стартом.
- **Что внутри загрузчика.** BL2 со списком из 57 чипов NAND (включая W25N01KV), BL31 и U-Boot 2026.01 xinyooo с автозагрузкой и веб-failsafe.
- **Почему два файла для UART.** BootROM принимает по XMODEM не больше `0x1F800` байт и только FIP с одним BL2. Затем BL2 сам просит `Press x to update firmware` и принимает весь 512 КБ образ, который записывает во флеш.

Подробно, с логами и адресами: [docs/ru/technical.md](docs/ru/technical.md).

## 7. Источники и благодарности

- [xinyooo](https://github.com/xinyooo/openwrt/releases): порт AN7563, U-Boot с веб-failsafe, [PR #23960](https://github.com/openwrt/openwrt/pull/23960), [тема на форуме](https://forum.openwrt.org/t/release-custom-openwrt-u-boot-for-xiaomi-be5000-an7563/250004).
- [100PoR-new](https://github.com/openwrt/openwrt/pull/23960#issuecomment-6173662443): BL2 с W25N01KV (собран через [make_airoha_atf](https://github.com/xinyooo/make_airoha_atf)) и фото GPIO0.
- [iscle](https://github.com/iscle/openwrt): сборки OpenWrt, разметка с калибровкой в `art`, DSA, PPE, Wi-Fi.
- [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha): исходники BL2, по которым разобран формат XMODEM-восстановления.
- [Medvedolog, issue #17](https://github.com/Medvedolog/airoha-router-ursusflasher/issues/17): наблюдения BootROM AN7552.

## 8. Открытые вопросы

- [ ] Запись загрузчика из стоковой прошивки Xiaomi не проверена на железе: неизвестно, открыт ли там раздел на запись. Скрипт это проверяет до записи.
- [ ] BL2 и BL31 — бинарники Airoha без открытой лицензии; [запрос на публикацию](https://github.com/openwrt/openwrt/pull/24257#issuecomment-5040866776).
- [ ] Официальной поддержки BE5000 в OpenWrt пока нет: [PR #23960](https://github.com/openwrt/openwrt/pull/23960) открыт.

Отчёты об успехах и проблемах — в [Issues](../../issues). Укажите чип NAND и вывод `be5000-install.sh check`.
