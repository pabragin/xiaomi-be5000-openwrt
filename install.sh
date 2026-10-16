#!/bin/sh
# One-command install from the PC: NAND check, full backup, Wi-Fi calibration,
# bootloader. Asks for the router password once and asks YES before writing.
#   sh install.sh [root@192.168.31.1]
set -eu

R=${1:-root@192.168.31.1}
cd "$(dirname "$0")"
BL=firmware/bootloader/be5000-bootloader-w25n01kv.bin
OUT=be5000-backup-$(date +%Y%m%d-%H%M%S)
CTL=${TMPDIR:-/tmp}/be5000-ssh-$$
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=600"
SSH="ssh $SSH_OPTS"
SCP="scp -O $SSH_OPTS"

step() { printf '\n=== %s\n' "$*"; }
fail() { printf '\nСТОП: %s\nНичего страшного: роутер не тронут, если не сказано обратное.\n' "$*" >&2; exit 1; }
trap 'ssh $SSH_OPTS -O exit "$R" 2>/dev/null || true' EXIT

step "1/5 Подключение к $R (введите пароль роутера один раз)"
$SSH "$R" true || fail "не удалось зайти по SSH на $R. Проверьте адрес и пароль: sh install.sh root@АДРЕС"
$SCP scripts/router/be5000-install.sh "$BL" "$R:/tmp/" >/dev/null

step "2/5 Проверка чипа памяти"
$SSH "$R" sh /tmp/be5000-install.sh nand | tee "/tmp/be5000-nand-$$.txt"
grep -q SUPPORTED: "/tmp/be5000-nand-$$.txt" && ! grep -q 'NOT SUPPORTED' "/tmp/be5000-nand-$$.txt" \
	|| fail "загрузчик не знает ваш чип памяти или чип не определился. Откройте issue и приложите вывод выше"
rm -f "/tmp/be5000-nand-$$.txt"

step "3/5 Бэкап всего флеша в папку $OUT (несколько минут)"
sh scripts/pc/be5000-backup.sh "$R" "$OUT" || fail "бэкап не сошёлся, повторите"

echo
echo "Дальше запись во флеш. Бэкап: $(pwd)/$OUT — сохраните его в надёжное место."
printf 'Напечатайте YES и нажмите Enter, чтобы продолжить: '
read -r ans
[ "$ans" = YES ] || fail "отменено"

step "4/5 Калибровка Wi-Fi"
$SSH "$R" sh /tmp/be5000-install.sh calibration || fail "калибровка не записана. Загрузчик ещё не тронут, роутер работает как раньше"

step "5/5 Загрузчик (не выключайте питание!)"
$SSH "$R" sh /tmp/be5000-install.sh bootloader "/tmp/$(basename "$BL")" \
	|| fail "загрузчик не записан. НЕ перезагружайте роутер и откройте issue с выводом выше"
$SCP "$R:/tmp/be5000-mtd*-old-bootloader.bin" "$OUT/" >/dev/null 2>&1 || true
$SSH "$R" reboot || true

cat <<EOF

Готово, роутер перезагружается. Осталось залить прошивку через браузер:
  1. Подключите ПК кабелем к порту LAN роутера (не к порту 2.5G).
  2. Задайте ПК адрес вручную: IP 192.168.1.10, маска 255.255.255.0.
  3. Через минуту откройте http://192.168.1.1
  4. Выберите файл $(pwd)/firmware/openwrt/openwrt-airoha-an7563-xiaomi_be5000-squashfs-sysupgrade.bin,
     нажмите Upload, затем Proceed. Ждите 5 минут, питание не выключайте.
  5. Верните ПК автоматический адрес (DHCP) и откройте http://192.168.1.1 снова.
EOF
