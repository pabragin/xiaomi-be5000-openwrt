# Как это устроено

[← README](../../README.ru.md) · [English](../en/technical.md)

> [!IMPORTANT]
> **Коротко.** AN7563 грузится цепочкой BootROM → BL2 → BL31 → U-Boot. BL2 сам читает NAND по встроенной таблице чипов: нет чипа — `panic()`. Для восстановления BootROM и BL2 умеют XMODEM, но каждый принимает свой формат.

## Содержание

1. [Железо](#железо)
2. [Разметка флеша](#разметка-флеша)
3. [Загрузчик](#загрузчик)
4. [Почему PANIC](#почему-panic)
5. [XMODEM-восстановление](#xmodem-восстановление)
6. [Калибровка Wi-Fi](#калибровка-wi-fi)
7. [Образ OpenWrt](#образ-openwrt)
8. [PCIe](#pcie)
9. [Поддерживаемые чипы NAND](#поддерживаемые-чипы-nand)

## Железо

| Компонент | Значение |
|---|---|
| SoC | Airoha AN7563PT (в логе BL2 `AN7552DRAMC V0.4`), 2× Cortex-A7 |
| DRAM | 512 МБ DDR3 (Winbond W634GU6…), 1866 MT/s |
| NAND | SPI-NAND 128 МБ, у разных партий разные: Winbond **W25N01KV**, ESMT и другие |
| Wi-Fi | MediaTek MT7992 (2.4 + 5 ГГц), EEPROM во флеше |
| Ethernet | встроенный коммутатор MT7530 (3× 1 Гбит) + EN8811H (2.5 Гбит) |
| UART | 115200 8N1, 3.3 В |

## Разметка флеша

![Разметка](../../images/flash-layout.svg)

| Смещение | Сток Xiaomi | После установки | Размер |
|---|---|---|---|
| `0x000000` | Bootloader | u-boot | `0x7C000` |
| `0x07C000` | ↑ | u-boot-env (RO) | `0x4000` |
| `0x080000` | u-boot-env | art: блок 1 | `0x20000` |
| `0x0A0000` | ↑ (пусто) | art: блок 2 = **калибровка** | `0x20000` |
| `0x0C0000` | ↑ | firmware: kernel (FIT) | `0x3C0000` |
| `0x100000` | bdata (`ethaddr=…`) | ↑ | |
| `0x180000` | **Factory** (EEPROM `92 79` + MAC) | firmware: rootfs | |
| `0x600000` | kernel (сток) | ↑ | |
| `0xC00000` | ubi (сток) | ↑ | |
| `0x40C0000` | ↑ | конец firmware | |

Логические адреса считаются через Airoha BMT: `BMT v1 at block 1023`, `BBT v1 at block 943`, 943 рабочих блока.

## Загрузчик

Первые `0x80000` байт: 0x800 нулей, затем FIP TF-A (`0xAA640001`, serial `0x12345678`):

| Часть | UUID (первые байты) | Что делает |
|---|---|---|
| BL2 | `5ff9ec0b` | маленький распаковщик + LZMA: DRAM, таблица SPI-NAND, загрузка FIP |
| BL31 | `47d4086d` | secure monitor |
| BL33 | `d6d0eea7` | U-Boot (LZMA) |

BootROM грузит BL2 с NAND сам. Дальше BL2 читает FIP со смещения `0x800` своим драйвером и проверяет заголовок в `FIP_BASE`.

## Почему PANIC

Исходники BL2: [Ansuel/atf-airoha](https://github.com/Ansuel/atf-airoha), `plat/ecnt/en7523/ecnt_bl2_setup.c`:

```c
if (flash_read(fip_offset, PLAT_ECNT_FIP_MAX_SIZE, (uint8_t *) PLAT_ECNT_FIP_BASE) == FLASH_READ_STATUS_CORRECT) { }
else { panic(); }
...
while (plat_check_header((uint8_t *) PLAT_ECNT_FIP_BASE) == 0) { panic(); }
```

Если чипа NAND нет в таблице BL2, `flash_read` не работает, и на любом холодном старте получается `PANIC at PC : 0x810017a9`.

| BL2 | Чипов | W25N01KV |
|---|---|---|
| xinyooo v2026.05-r1…v2026.06-r1 (`8d363ec4…`), X-WRT 26.10 preloader | 56 | нет |
| сборка r35200+4 от 2026-07-02, этот репозиторий | 57 | **есть** |

> [!NOTE]
> После тёплой перезагрузки из Linux «плохой» BL2 иногда доходит до U-Boot. Проверяйте загрузчик только холодным стартом: питание из розетки.

## XMODEM-восстановление

| Этап | Кто принимает | Приглашение | Формат | Ограничение |
|---|---|---|---|---|
| 1 | BootROM (GPIO0 = GND, `HWCONF is f`) | `Press x` | FIP с одной записью BL2 по смещению `0x60` | ≤ `0x1F800` байт, ждёт ~30 с |
| 2 | BL2 из этапа 1 | `Press x to update firmware` | весь 512 КБ образ: 0x800 нулей + FIP | длина ровно `0x80000` → BL2 пишет его во флеш с 0 |

Оба этапа — XMODEM-CRC, блоки по 128 байт.

| Что отправили | Результат |
|---|---|
| весь 512 КБ образ на этап 1 | `CAN` на блоке 1009 (`0x1F800`) |
| голый BL2 на этап 1 | принят, тишина |
| FIP без 0x800 нулей на этап 2 | `PANIC`: BL2 кладёт файл в `FIP_BASE - 0x800`, и заголовок оказывается не на месте |

## Калибровка Wi-Fi

- **На стоке:** EEPROM MT7992 в начале раздела Factory (`0x180000`), 7680 байт (`0x1E00`), начинается с `92 79`, затем базовый MAC. Остаток раздела `FF`.
- **На новой разметке:** OpenWrt читает EEPROM из второго блока `art` (`0xA0000`) через NVMEM.
- **Как переносится:** `be5000-calibration.py` берёт первые `0x1E00` байт и добавляет `FF` до 128 КБ.

Без калибровки в `dmesg` будет `mt7996e … eeprom load fail, use default bin`: драйвер берёт стандартную EEPROM MediaTek. Wi-Fi работает, но её MAC `00:0c:43:26:60:10` одинаковый у всех роутеров, поэтому на первой загрузке каждое радио получает случайный `macaddr_base` в `/etc/config/wireless`.

## Образ OpenWrt

`squashfs-sysupgrade.bin` — не tar, а готовый образ раздела `firmware`:

| Смещение | Что |
|---|---|
| `0x000000` | FIT (`d00dfeed`): ядро + DTB |
| `0x3C0000` | squashfs (`hsqs`) |
| после squashfs | `deadc0de`, затем метаданные sysupgrade |

U-Boot читает первые `fitsize = 0x500000` байт раздела и выполняет `bootm`. Веб-failsafe пишет загруженный файл в раздел `firmware` как есть.

Настройки лежат не в `firmware`, а в отдельном разделе `ubi` (`0x18C0000`, 40 МБ), том `rootfs_data` (UBIFS). JFFS2 на W25N01KV не годится: он программирует страницу 0 блока дважды (cleanmarker в OOB, потом данные), и встроенный ECC чипа такую страницу портит ([issue #1](https://github.com/pabragin/xiaomi-be5000-openwrt/issues/1)).

## PCIe

Радио MT7992 подключено двумя каналами PCIe: `0000:01:00.0` (основной) и `0001:01:00.0` (второй интерфейс). У корневых портов AN7563 по одной линии и максимум 5 GT/s, радио умеет 8 GT/s.

- **Проблема:** после включения каналы поднимаются на 2,5 GT/s и сами не переходят выше. При скачивании радио читает каждый пакет из памяти роутера по PCIe, и на 2,5 GT/s x1 скачивание упиралось примерно в 1 Гбит/с.
- **Решение:** ядро переобучает оба канала на 5 GT/s сразу после включения. Так же делает ядро стока Xiaomi (`mt7512_pcie_rc0_retrain`, `mt7512_pcie_rc1_retrain`).
- **Проверка:** `cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed` → `5.0 GT/s PCIe`; в `dmesg` строка `link retrained to 5.0 GT/s PCIe` для обоих портов.

| PCIe | Скачивание (клиент 2x2 160 МГц) |
|---|---|
| 2,5 GT/s x1 | ~1,05 Гбит/с |
| 5 GT/s x1 | ~1,45 Гбит/с (8 потоков HTTP), 1757 Мбит/с в OpenSpeedTest |

## Поддерживаемые чипы NAND

BL2 в `be5000-bootloader-w25n01kv.bin` (57 шт.):

```
ATO25D1GA BWET08U BWJX08U EM73C044SNB EM73C044SND EM73C044SNF EM73C044VCA EM73C044VCD
EM73D044SNA EM73D044SNC EM73D044SND EM73D044SNF EM73D044VCA EM73D044VCB EM73D044VCD
EM73D044VCG EM73D044VCH EM73E044SNA EM73E044VCA EM73E044VCB EM73F044SNA F50L1G F50L1G41LB
F50L2G41LB FM25G01B FM25G02 FM25G02B FM25S01 FS35ND01GD1F1 FS35ND02GD1F1 FS35ND02GS2F1
GD5F1GQ4UB GD5F2GQ4UB GD5F2GQ4UE9IS GD5F4GQ4UB HYF2GQ4UAACAE MT29F1G01 MT29F2G01 MT29F4G01
MXIC35LF1G MXIC35LF1G24AD MXIC35LF2G MXIC35LF2G14AC MXIC35LF2GE4AD PSU1GS20BN S35ML02G3
TC58CVG0S3H TC58CVG1S3H TC58CVG2S0H W25M02G W25N01G W25N01KV W25N02K W25N04K
XT26G01A XT26G02A XT26G02B
```

Проверить любой другой образ: `python3 scripts/pc/be5000-check-bootloader.py файл.bin --chip <ваш чип>`.
