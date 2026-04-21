#!/usr/bin/env bash
# pmg-quarantine-junk — удаление
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
info()  { echo -e "$*"; }

[[ $EUID -eq 0 ]] || { echo "Запустите от root" >&2; exit 1; }

echo -e "${RED}${BOLD}Удаление pmg-quarantine-junk${RESET}"
echo
warn "Будут удалены:"
echo "  /usr/local/bin/pmg-quarantine-{notifier,action-server,do-action}"
echo "  /usr/local/lib/pmg-quarantine-junk/"
echo "  /etc/systemd/system/pmg-quarantine-action-server.service"
echo "  /etc/cron.d/pmg-quarantine-junk"
echo "  /etc/logrotate.d/pmg-quarantine-junk"
echo
warn "НЕ будут удалены (сохраняются):"
echo "  /etc/pmg-quarantine-junk/   (конфиг и секрет)"
echo "  /var/lib/pmg-quarantine-junk/  (база состояния)"
echo "  /var/log/pmg-quarantine-junk.log  (логи)"
echo
read -rp "Продолжить? [y/N]: " confirm
[[ "${confirm,,}" == "y" ]] || { info "Отменено."; exit 0; }

# Останавливаем сервис
if systemctl is-active --quiet pmg-quarantine-action-server 2>/dev/null; then
    systemctl stop pmg-quarantine-action-server
    ok "Сервис остановлен"
fi
if systemctl is-enabled --quiet pmg-quarantine-action-server 2>/dev/null; then
    systemctl disable pmg-quarantine-action-server
    ok "Сервис отключён из автозапуска"
fi

# Удаляем файлы
files=(
    /usr/local/bin/pmg-quarantine-notifier
    /usr/local/bin/pmg-quarantine-action-server
    /usr/local/bin/pmg-quarantine-do-action
    /usr/local/bin/pmg-quarantine-gen-ticket
    /etc/systemd/system/pmg-quarantine-action-server.service
    /etc/cron.d/pmg-quarantine-junk
    /etc/logrotate.d/pmg-quarantine-junk
    /etc/sudoers.d/pmg-quarantine-junk
)
for f in "${files[@]}"; do
    [[ -e "$f" ]] && { rm -f "$f"; ok "Удалён: $f"; } || true
done

[[ -d /usr/local/lib/pmg-quarantine-junk ]] && {
    rm -rf /usr/local/lib/pmg-quarantine-junk
    ok "Удалена директория: /usr/local/lib/pmg-quarantine-junk"
}

systemctl daemon-reload

# Удаляем системного пользователя
if id pmg-quarantine &>/dev/null; then
    deluser --system pmg-quarantine 2>/dev/null || true
    ok "Пользователь pmg-quarantine удалён"
fi

echo
echo -e "${GREEN}Удаление завершено.${RESET}"
echo "Конфиг, база и логи сохранены. Для полного удаления:"
echo "  rm -rf /etc/pmg-quarantine-junk /var/lib/pmg-quarantine-junk /var/log/pmg-quarantine-junk.log"
