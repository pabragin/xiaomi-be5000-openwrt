# OpenWrt на Xiaomi BE5000 (Airoha AN7563)

**Русский** · [English](README.en.md)

> [!IMPORTANT]
> **Коротко.** Репозиторий описывает, как поставить OpenWrt на Xiaomi BE5000, имея только root-доступ по SSH, и как поднять роутер по UART, если загрузчик сломался.
> - **Главная ловушка:** загрузчик из релизов xinyooo и preloader X-WRT не знают флеш-память **Winbond W25N01KV**. С ней роутер падает на каждом холодном старте с `PANIC at PC : 0x810017a9`.
> - **Здесь лежит загрузчик, который её знает:** [`be5000-bootloader-w25n01kv.bin`](firmware/bootloader/), 57 чипов NAND, U-Boot с автозагрузкой и веб-восстановлением.
> - **Скорость Wi-Fi:** 1757 Мбит/с скачивание и 1643 Мбит/с отдача через BE5000 (OpenSpeedTest, MacBook 2x2 на 160 МГц до ПК в проводной сети).
> - **Проверено на железе:** BE5000 (AN7563PT, W25N01KV, 512 МБ DDR3): установка из стоковой прошивки Xiaomi по SSH, восстановление по UART, установка через веб-failsafe, холодный старт, своя сборка OpenWrt с настройками в UBI, своя калибровка Wi-Fi.

## Содержание

1. [Что работает](#1-что-работает)
2. [Что нужно](#2-что-нужно)
3. [Установка](#3-установка) → подробно: [docs/ru/install-ssh.md](docs/ru/install-ssh.md)
4. [Если загрузчик сломался: UART](#4-если-загрузчик-сломался-uart) → подробно: [docs/ru/recovery-uart.md](docs/ru/recovery-uart.md)
5. [Файлы](#5-файлы)
6. [Как это устроено](#6-как-это-устроено) → подробно: [docs/ru/technical.md](docs/ru/technical.md)
7. [Источники и благодарности](#7-источники-и-благодарности)
8. [Обратная связь](#8-обратная-связь)

## 1. Что работает

Всё ниже проверено на BE5000 с этой прошивкой.

| Что | Как работает |
|---|---|
| **Система** | OpenWrt SNAPSHOT `r36539+835`, ядро **Linux 6.18.55**, драйвер Wi-Fi mt76 2026-10-08 |
| **Wi-Fi 5 ГГц** | 160 МГц, Wi-Fi 6/7. MacBook 2x2: скачивание **1757 Мбит/с**, отдача **1643 Мбит/с** ([замер](firmware/openwrt/README.md#speed)) |
| **Wi-Fi 2,4 ГГц** | работает, 20/40 МГц |
| **Аппаратное ускорение** | трафик Wi-Fi ↔ провод идёт через PPE и NPU, процессор на полной скорости загружен на ~10% |
| **Роуминг** | 802.11r: телефоны и ноутбуки бесшовно переходят между BE5000 и другой точкой OpenWrt с той же сетью |
| **Порты** | три по 1 Гбит/с и один 2,5 Гбит/с, все в одной сети |
| **Настройки** | сохраняются после перезагрузок и отключения питания, переносятся при обновлении прошивки |
| **Перезагрузка** | обычная и по питанию, без зависаний; при зависании роутер сам перезагружается через ~30 с (watchdog) |
| **Управление** | веб-интерфейс LuCI и SSH на `192.168.1.1`, обновления через `sysupgrade` |
| **MAC-адреса** | с наклейки роутера, из его заводской калибровки |

<img src="images/openspeedtest-be5000.png" alt="OpenSpeedTest через BE5000: 1757 Мбит/с скачивание, 1643 Мбит/с отдача" width="320">

**Ограничения:**
- **Wi-Fi по умолчанию выключен.** После установки задайте страну, имя сети и пароль.
- **Старые устройства только с WPA2-TKIP** (например, некоторые принтеры) подключаются через раз и переподключаются каждые несколько секунд.
- **Скачивание на одном быстром клиенте** упирается примерно в 1,45–1,75 Гбит/с. Предел задаёт канал PCIe между процессором и радио (одна линия, 5 GT/s).

> [!WARNING]
> Установка перезаписывает заводские разделы `bdata` и `Factory`. Вернуться на прошивку Xiaomi можно только из полного бэкапа, который установщик снимет на шаге 1.

## 2. Что нужно

- **Роутер с доступом по SSH** (root и пароль). Неважно, что на нём стоит: сток Xiaomi, OpenWrt xinyooo/iscle или X-WRT.
- **Компьютер** с macOS или Linux (на Windows — WSL) и **сетевой кабель** до роутера.

> [!NOTE]
> Настройки хранятся в UBI, а не в JFFS2: на флеше W25N01KV JFFS2 портит записи, и после перезагрузки роутер поднимается без сети ([issue #1](../../issues/1)). С OpenWrt iscle/xinyooo на этот образ переходят без сохранения настроек (`sysupgrade -n`).

## 3. Установка

**Шаг 1. Одна команда на компьютере.** Подключите компьютер кабелем к порту LAN роутера (не к порту 2.5G). Скачайте репозиторий и запустите установщик с адресом роутера:

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
sh install.sh root@192.168.31.1        # 192.168.31.1 — адрес стока Xiaomi; на OpenWrt обычно 192.168.1.1
```

Скрипт один раз спросит пароль роутера и сам:
1. проверит, подходит ли загрузчик к чипу памяти (если нет, остановится, ничего не записав);
2. сохранит полный бэкап флеша в папку `be5000-backup-<дата>` (её нужно сохранить: без неё прошивку Xiaomi не вернуть);
3. спросит `YES`, перенесёт калибровку Wi-Fi и запишет загрузчик;
4. перезагрузит роутер.

**Шаг 2. Прошивка через браузер.**
1. Задайте компьютеру адрес вручную: IP `192.168.1.10`, маска `255.255.255.0`. На macOS: «Настройки → Сеть → (адаптер) → Подробнее → TCP/IP → Вручную».
2. Откройте `http://192.168.1.1`, выберите файл [`firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`](firmware/openwrt/), нажмите **Upload**, затем **Proceed**.
3. Подождите 5 минут и не выключайте питание. Роутер сам перезагрузится в OpenWrt.

**Шаг 3. Настройка.** Верните компьютеру автоматический адрес (DHCP), откройте `http://192.168.1.1`, задайте пароль, затем страну, имя и пароль Wi-Fi.

> [!CAUTION]
> Если во время записи загрузчика пропало питание или после шага 1 роутер не появляется в сети, поднять его можно только по UART (раздел 4).

Каждый шаг по отдельности, ручная проверка чипа и случай `READ-ONLY`: [docs/ru/install-ssh.md](docs/ru/install-ssh.md).

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
| [`firmware/openwrt/…-squashfs-sysupgrade.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin) | OpenWrt ([описание сборки](firmware/openwrt/README.md)): ядро FIT + squashfs | раздел `firmware` `0xC0000` (веб-failsafe или `sysupgrade`) |
| [`firmware/openwrt/…-initramfs-kernel.bin`](firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-initramfs-kernel.bin) | OpenWrt в RAM для проверки и восстановления | TFTP → `bootm`, флеш не трогает |
| [`install.sh`](install.sh) | установка одной командой: проверка, бэкап, калибровка, загрузчик | запускается на компьютере |
| [`scripts/router/be5000-install.sh`](scripts/router/be5000-install.sh) | проверка, запись калибровки и загрузчика с проверкой чтением | запускается на роутере |
| [`scripts/pc/`](scripts/pc/) | бэкап, калибровка, UART-восстановление, проверка загрузчика | запускается на ПК |

Контрольные суммы и происхождение бинарников: [firmware/bootloader/README.md](firmware/bootloader/README.md), [firmware/openwrt/README.md](firmware/openwrt/README.md).

## 6. Как это устроено

| Компонент | Что стоит на флеше |
|---|---|
| Загрузчик (0x0–0x80000) | BL2 с поддержкой W25N01KV + BL31 + U-Boot 2026.01 (автозагрузка, веб-failsafe на `192.168.1.1`) |
| Калибровка Wi-Fi | заводская EEPROM MT7992 перенесена в блок `0xA0000` (раздел `art`) |
| Прошивка | OpenWrt (своя сборка на основе [iscle](https://github.com/iscle/openwrt)) в разделе `firmware` с `0xC0000`, 24 МБ |
| Настройки | раздел `ubi` с `0x18C0000`, 40 МБ, том `rootfs_data` (UBIFS) |

![Разметка флеша](images/flash-layout.svg)

- **Что внутри загрузчика.** BL2 со списком из 57 чипов NAND (включая W25N01KV), BL31 и U-Boot 2026.01 xinyooo с автозагрузкой и веб-failsafe.
- **Почему два файла для UART.** BootROM принимает по XMODEM не больше `0x1F800` байт и только FIP с одним BL2. Затем BL2 сам просит `Press x to update firmware` и принимает весь 512 КБ образ, который записывает во флеш.

Подробно, с логами и адресами: [docs/ru/technical.md](docs/ru/technical.md).

## 7. Источники и благодарности

- [xinyooo](https://github.com/xinyooo/openwrt/releases): порт AN7563, U-Boot с веб-failsafe, [PR #23960](https://github.com/openwrt/openwrt/pull/23960), [тема на форуме](https://forum.openwrt.org/t/release-custom-openwrt-u-boot-for-xiaomi-be5000-an7563/250004).
- [100PoR-new](https://github.com/openwrt/openwrt/pull/23960#issuecomment-6173662443): BL2 с W25N01KV (собран через [make_airoha_atf](https://github.com/xinyooo/make_airoha_atf)) и фото GPIO0.
- [iscle](https://github.com/iscle/openwrt): порт OpenWrt для BE5000, разметка с калибровкой в `art`, DSA, PPE, Wi-Fi.
- [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha): исходники BL2, по которым разобран формат XMODEM-восстановления.
- [Medvedolog, issue #17](https://github.com/Medvedolog/airoha-router-ursusflasher/issues/17): наблюдения BootROM AN7552.

## 8. Обратная связь

Отчёты об успехах и проблемах — в [Issues](../../issues). Укажите чип NAND и вывод `be5000-install.sh check`.
