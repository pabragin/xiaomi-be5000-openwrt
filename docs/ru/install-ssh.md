# Установка OpenWrt по SSH

[← README](../../README.ru.md) · [English](../en/install-ssh.md)

> [!IMPORTANT]
> **Коротко.** Шаги: проверка → бэкап → калибровка → загрузчик → прошивка через веб-failsafe → первая настройка. Все записи скрипт сверяет обратным чтением. Ни один шаг не требует знать, какой U-Boot стоит сейчас. Шаги 1–4 одной командой делает [`install.sh`](../../install.sh), здесь они расписаны по отдельности.

## Содержание

1. [Готово, когда](#готово-когда)
2. [Шаг 0. Подготовка](#шаг-0-подготовка)
3. [Шаг 1. Проверка](#шаг-1-проверка)
   - [Подходит ли загрузчик к вашему чипу NAND](#подходит-ли-загрузчик-к-вашему-чипу-nand)
4. [Шаг 2. Бэкап](#шаг-2-бэкап)
5. [Шаг 3. Калибровка Wi-Fi](#шаг-3-калибровка-wi-fi)
6. [Шаг 4. Загрузчик](#шаг-4-загрузчик)
7. [Шаг 5. Прошивка через веб-failsafe](#шаг-5-прошивка-через-веб-failsafe)
8. [Шаг 6. Первая настройка](#шаг-6-первая-настройка)
9. [Если раздел READ-ONLY](#если-раздел-read-only)
10. [Если что-то пошло не так](#если-что-то-пошло-не-так)

## Готово, когда

- [ ] Бэкап всех разделов лежит на ПК, файл `SHA256SUMS` сошёлся.
- [ ] `be5000-install.sh check` пишет `already contains MT7992 calibration`.
- [ ] Роутер включается из розетки **без UART** и загружает OpenWrt.
- [ ] `cat /sys/class/ieee80211/phy0/macaddress` показывает MAC с наклейки роутера, а не случайный.

## Шаг 0. Подготовка

| Что | Зачем |
|---|---|
| root по SSH | все записи идут из системы, которая стоит на роутере |
| `ssh` и `curl` на ПК | `python3` только для восстановления по UART и `be5000-check-bootloader.py` |
| кабель ПК ↔ LAN-порт | веб-failsafe работает только по проводу |
| USB-UART 3.3 В | страховка: если запись загрузчика оборвётся, роутер поднимается только по UART |
| [OpenWrt для BE5000](https://github.com/pabragin/xiaomi-be5000-openwrt/releases/latest) | `openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin` из последнего релиза ([описание сборки](../../firmware/openwrt/README.md)). `install.sh` сам скачивает его в `firmware/openwrt/` и сверяет с `SHA256SUMS` |

```sh
git clone https://github.com/pabragin/xiaomi-be5000-openwrt && cd xiaomi-be5000-openwrt
R=root@192.168.31.1     # сток Xiaomi; на OpenWrt обычно root@192.168.1.1
```

## Шаг 1. Проверка

```sh
ssh $R 'cat > /tmp/be5000-install.sh' < scripts/router/be5000-install.sh
ssh $R sh /tmp/be5000-install.sh check
```

Пример (роутер уже на OpenWrt с новой разметкой):

```
>>> MTD partitions (index name offset size flags; flag 0x400 = writable)
  mtd0  u-boot         off=0x00000000 size=0x00060000 RO
  mtd1  u-boot-env     off=0x00060000 size=0x00020000 rw
  mtd2  art            off=0x00080000 size=0x00040000 rw
  mtd3  firmware       off=0x000c0000 size=0x01800000 rw
  mtd4  kernel         off=0x00000000 size=0x003c0000 rw (inside firmware)
  mtd5  rootfs         off=0x003c0000 size=0x01440000 rw (inside firmware)
  mtd6  rootfs_data    off=0x00ac0000 size=0x00d40000 rw (inside firmware)
  mtd7  ubi-data       off=0x018c0000 size=0x05d20000 rw
>>> Kernel log:
  [    1.297809] spi-nand spi0.0: Winbond SPI NAND was found.
  [    1.303181] spi-nand spi0.0: 128 MiB, block size: 128 KiB, page size: 2048, OOB size: 96
  [    3.287615] mtdblock: MTD device 'rootfs' is NAND, please consider using UBI block devices instead.
>>> MTD geometry: page=2048 oob=96 (sysfs) oob=96 (kernel log) erase=131072
>>> Result: vendor=Winbond chip=W25N01KV
  SUPPORTED: the BL2 of be5000-bootloader-w25n01kv.bin knows W25N01KV
  Note: xinyooo v2026.05/06 bootloaders and the X-WRT preloader do NOT know W25N01KV
>>> Detected flash layout: replacement
  bootloader partition: mtd0 'u-boot' size=0x60000 READ-ONLY
  calibration block 0xA0000: mtd2 'art' +0x20000, already contains MT7992 calibration, rw
```

| Строка | Что смотреть |
|---|---|
| `Detected flash layout` | `stock` — заводская разметка, `replacement` — разметка xinyooo/iscle, `unknown` — остановитесь и откройте issue |
| `Result` и `SUPPORTED` | чип должен быть в [списке BL2](../en/technical.md#supported-nand-chips) (англ.). При `NOT SUPPORTED` остановитесь; при `NOT IDENTIFIED` прочитайте маркировку на микросхеме |
| `bootloader partition … READ-ONLY` | шаг 4 из этой системы не выполнить, см. [READ-ONLY](#если-раздел-read-only) |
| `calibration block … has data` | блок `0xA0000` занят чем-то неизвестным. Остановитесь: скрипт не будет его стирать |
| `Factory EEPROM header: 9279` | (только сток) калибровка на месте, её можно переносить |

### Подходит ли загрузчик к вашему чипу NAND

Это главное, что нужно проверить **до** записи загрузчика. Если BL2 не знает ваш чип, роутер не загрузится ни разу.

```sh
ssh $R sh /tmp/be5000-install.sh nand
```

```
>>> Kernel log:
  [    1.297809] spi-nand spi0.0: Winbond SPI NAND was found.
  [    1.303181] spi-nand spi0.0: 128 MiB, block size: 128 KiB, page size: 2048, OOB size: 96
  [    3.287615] mtdblock: MTD device 'rootfs' is NAND, please consider using UBI block devices instead.
>>> MTD geometry: page=2048 oob=96 (sysfs) oob=96 (kernel log) erase=131072
>>> Result: vendor=Winbond chip=W25N01KV
  SUPPORTED: the BL2 of be5000-bootloader-w25n01kv.bin knows W25N01KV
  Note: xinyooo v2026.05/06 bootloaders and the X-WRT preloader do NOT know W25N01KV
```

Команда `bootloader` запускает ту же проверку сама и **не пишет**, если чип не подходит. Если чип не удалось определить, она попросит сверить маркировку и перезапустить с `BE5000_NAND_OK=1`.

То же вручную, встроенными средствами:

```sh
dmesg | grep -iE 'nand|oob|mfr_id|W25N|GD5F|F50L|EM73'   # производитель, размер OOB, иногда модель или JEDEC ID
cat /sys/class/mtd/mtd0/oobsize                    # размер OOB (на стоке Xiaomi бывает неверным)
cat /sys/class/mtd/mtd0/writesize                  # размер страницы
```

| Признак | Чип | Наш загрузчик | Загрузчики xinyooo v2026.05–06, preloader X-WRT |
|---|---|---|---|
| Winbond, страница 2048, **OOB 96** или ID `EF AE 21` | W25N01KV | ✅ | ❌ PANIC |
| Winbond, страница 2048, **OOB 64** или ID `EF AA 21` | W25N01GV | ✅ | ✅ |
| ID `C8 01` (в логе стока: `spi_nand_probe: mfr_id=0xc8, dev_id=0x1`) | F50L1G41LB | ✅ | ✅ |
| ESMT, OOB 64, другой ID | EM73… и другие | ✅ если модель есть в [списке](../en/technical.md#supported-nand-chips) (англ.) | ✅ если модель есть в списке |
| не определяется | — | прочитайте маркировку на 8-ногой микросхеме рядом с SoC | — |

> [!NOTE]
> W25N01KV и W25N01GV ядро называет одинаково: «Winbond SPI NAND, 128 MiB». Различить их можно только по OOB (96 и 64 байта) или по JEDEC ID.

> [!WARNING]
> Стоковое ядро Xiaomi показывает в `/sys/class/mtd/mtd0/oobsize` значение 64 даже для W25N01KV. Верный размер OOB есть в логе ядра. Скрипт берёт его оттуда, а 64 из одного только sysfs не считает доказательством: чип останется неопределённым, и для записи загрузчика понадобится сверить маркировку и задать `BE5000_NAND_OK=1`.

## Шаг 2. Бэкап

```sh
sh scripts/pc/be5000-backup.sh $R
```

Скрипт качает каждый `/dev/mtdN` на ПК и сверяет SHA-256 с роутером. Блок, который роутер не может прочитать (бэд-блок), бэкап не останавливает: такой раздел читается заново поблочно, вместо бэд-блока сохраняется 0xFF, а сам блок записывается в `bad-blocks.txt`. В папке `be5000-backup-<дата>/` будут `mtdN-<имя>.bin`, `proc_mtd.txt`, `sysfs_mtd.txt`, `dmesg.txt` и `SHA256SUMS`.

> [!WARNING]
> В бэкапе ваша калибровка, MAC-адреса и серийный номер. Не публикуйте его. Без него прошивку Xiaomi не вернуть.

## Шаг 3. Калибровка Wi-Fi

```sh
ssh $R sh /tmp/be5000-install.sh calibration
```

```
>>> calibration built from Factory: Wi-Fi base MAC 50:4f:3b:7a:30:76, md5 …
>>> writing calibration into mtd1 'u-boot-env' at +0x20000 (whole partition rewritten, other blocks unchanged)
>>> mtd1 written and verified (…)
```

Что делает команда:
1. Находит заводской раздел Factory (`0x180000`) и читает его в `/tmp/be5000-Factory.bin`.
2. Проверяет подпись `92 79` (MT7992) и базовый MAC. Если после первых 7680 байт EEPROM в разделе есть данные, останавливается.
3. Собирает блок 128 КБ: EEPROM + `FF`.
4. Находит раздел, в который попадает `0xA0000` (на стоке `u-boot-env`, на новой разметке `art`), убеждается, что блок пустой, переписывает раздел с изменённым вторым блоком и проверяет результат чтением.

| Случай | Команда |
|---|---|
| Сток Xiaomi, Factory на месте | `be5000-install.sh calibration` |
| Калибровка уже в `0xA0000` (OpenWrt xinyooo/iscle) | та же команда ответит `calibration already in place` |
| Factory уже затёрт, есть бэкап | `ssh $R 'cat > /tmp/Factory.bin' < Factory.bin` и `be5000-install.sh calibration /tmp/Factory.bin` (4 МБ дамп или готовый блок 128 КБ) |
| OpenWrt в RAM (initramfs) на заводском флеше | команда находит заводские данные `Factory` внутри `firmware` и пишет блок в `art`: в этой сборке раздел доступен на запись |

## Шаг 4. Загрузчик

```sh
ssh $R 'cat > /tmp/be5000-bootloader-w25n01kv.bin' < firmware/bootloader/be5000-bootloader-w25n01kv.bin
ssh $R sh /tmp/be5000-install.sh bootloader /tmp/be5000-bootloader-w25n01kv.bin
ssh $R cat /tmp/be5000-mtd0-old-bootloader.bin > be5000-backup-<дата>/old-bootloader.bin   # старый загрузчик на ПК
```

Скрипт проверит FIP-заголовок образа, сохранит старый загрузчик в `/tmp`, запишет новый и сверит его чтением.

> [!CAUTION]
> С этого момента и до шага 5 **не выключайте питание**, пока скрипт не напишет `written and verified`. Если запись оборвалась — [восстановление по UART](recovery-uart.md).

## Шаг 5. Прошивка через веб-failsafe

1. Перезагрузите роутер (`ssh $R reboot` или выключить и включить).
2. U-Boot попробует загрузить OpenWrt из раздела `firmware`. Там пока данные стока, поэтому загрузка не пройдёт, и через пару секунд поднимется страница восстановления.
3. Подключите ПК кабелем к LAN-порту и задайте ему адрес вручную: `192.168.1.10`, маска `255.255.255.0`.
4. Откройте `http://192.168.1.1`, выберите образ из шага 0 (`firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin`), нажмите **Upload**.
5. На странице подтверждения сверьте, что размер совпадает с загруженным файлом, и нажмите **Proceed**. U-Boot стирает свой раздел `firmware` (64 МБ, вместе с началом раздела настроек `ubi-data`) и записывает образ. Это занимает **3–5 минут**: страница может перестать отвечать, питание не выключайте. Потом роутер сам перезагрузится в OpenWrt.
6. На первой загрузке OpenWrt форматирует раздел `ubi-data` и создаёт в нём том `rootfs_data` для настроек. В консоли будут `- formatting UBI on mtdN -` и `- creating rootfs_data UBI volume -`, в `dmesg` строки `ubi_rootfs_data:`, затем `mount_root: switching to ubifs overlay`.

> [!TIP]
> **macOS:** если `192.168.1.1` перестал открываться после перезагрузки роутера, macOS потерял маршрут на этом интерфейсе. Задайте адрес в «Настройки → Сеть → (адаптер) → Подробнее → TCP/IP → Вручную», а не через `ifconfig alias`.

## Шаг 6. Первая настройка

```sh
ssh root@192.168.1.1
passwd
cat /sys/class/ieee80211/phy0/macaddress   # MAC с наклейки, не случайный
```

Wi-Fi по умолчанию выключен. В LuCI (`http://192.168.1.1`) задайте страну, имя сети и пароль, затем включите радио.

Обновления дальше ставятся обычным `sysupgrade` из OpenWrt, см. [С прошлого релиза этой сборки](../../README.ru.md#с-прошлого-релиза-этой-сборки).

## Если раздел READ-ONLY

| Где | Что делать |
|---|---|
| OpenWrt из этого репозитория, установленный или в RAM | `art` доступен на запись (проверено), шаг 3 работает. `u-boot` только для чтения: загрузчик пишется через [UART](recovery-uart.md) |
| OpenWrt iscle/xinyooo | там `u-boot` и `art` только для чтения. Вариант без разборки: `kmod-mtd-rw` и `insmod mtd-rw i_want_a_brick=1` (не проверялся). Надёжный вариант: для калибровки загрузить initramfs из релиза по TFTP, загрузчик через [UART](recovery-uart.md). Для перехода на этот образ шаг с загрузчиком вообще не нужен: достаточно `sysupgrade -n` ([README](../../README.ru.md#с-openwrt-xinyooo-или-iscle)) |
| Сток Xiaomi | разделы загрузчика и калибровки на стоке доступны на запись (проверено), этот случай не возникает. Если всё же `READ-ONLY` — [UART](recovery-uart.md), затем шаг 5 этой инструкции |

## Если что-то пошло не так

| Симптом | Причина | Решение |
|---|---|---|
| После шага 4 роутер не появляется в сети, светодиод не меняется | загрузчик не стартует | [UART](recovery-uart.md) |
| `192.168.1.1` не открывается, но роутер жив | у ПК нет адреса в `192.168.1.0/24`, или кабель в порту 2.5G | задайте ПК `192.168.1.10/24`, используйте гигабитный LAN-порт |
| failsafe пишет `not a valid firmware image for this board` | загружен не тот файл | нужен `squashfs-sysupgrade.bin` для `xiaomi_be5000` |
| Wi-Fi со случайным MAC, в `dmesg` `eeprom load fail` | калибровки нет в `0xA0000` | повторите шаг 3: `be5000-install.sh calibration`, с `Factory.bin` или `calibration.bin` из бэкапа, если заводских данных уже нет |
