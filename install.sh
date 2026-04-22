#!/usr/bin/env bash
# =============================================================================
#  pmg-quarantine-junk — установочный скрипт
#  Поддерживаемые дистрибутивы: Debian 11/12 (Proxmox Mail Gateway 7/8)
# =============================================================================
set -euo pipefail

# ---------- Цвета ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}=== $* ===${RESET}"; }
ask_yn() {  # ask_yn "вопрос" → 0=yes 1=no
    read -rp "  $1 [y/N]: " _ans
    [[ "${_ans,,}" == "y" ]]
}

# ---------- Константы -------------------------------------------------------
INSTALL_LIB=/usr/local/lib/pmg-quarantine-junk
INSTALL_BIN=/usr/local/bin
INSTALL_ETC=/etc/pmg-quarantine-junk
INSTALL_VAR=/var/lib/pmg-quarantine-junk
INSTALL_LOG=/var/log/pmg-quarantine-junk.log
SYSTEMD_DIR=/etc/systemd/system
LOGROTATE_DIR=/etc/logrotate.d
CRON_FILE=/etc/cron.d/pmg-quarantine-junk

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Должны запускаться от root -------------------------------------
[[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo $0"

# =============================================================================
section "1. Проверка операционной системы"
# =============================================================================

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    info "ОС: $PRETTY_NAME"
    if [[ "$ID" != "debian" ]] && [[ "$ID_LIKE" != *"debian"* ]]; then
        warn "Скрипт тестировался только на Debian. Продолжить? [y/N]"
        read -r answer
        [[ "${answer,,}" == "y" ]] || die "Установка отменена."
    fi
else
    warn "Не удалось определить дистрибутив. Продолжить? [y/N]"
    read -r answer
    [[ "${answer,,}" == "y" ]] || die "Установка отменена."
fi

# =============================================================================
section "2. Проверка PMG"
# =============================================================================

if ! command -v pmgsh &>/dev/null; then
    die "pmgsh не найден. Убедитесь, что Proxmox Mail Gateway установлен."
fi
PMG_VER=$(dpkg -l proxmox-mailgateway 2>/dev/null | awk '/^ii/{print $3}')
[[ -z "$PMG_VER" ]] && PMG_VER=$(pmgversion 2>/dev/null | awk '{print $1}')
[[ -z "$PMG_VER" ]] && PMG_VER="версия неизвестна"
ok "PMG обнаружен: $PMG_VER"

# Проверяем доступность БД PMG
if ! perl -MPMG::DBTools -e 'PMG::DBTools::open_ruledb()' &>/dev/null; then
    die "Не удалось подключиться к БД PMG (Proxmox_ruledb). Проверьте, запущен ли postgresql."
fi
ok "База данных PMG доступна"

# Проверяем наличие нужных PMG Perl-модулей
for mod in PMG::Quarantine PMG::DBTools PMG::Utils; do
    if ! perl -M"$mod" -e1 &>/dev/null 2>&1; then
        die "Perl-модуль $mod не найден. Установка PMG неполная?"
    fi
done
ok "PMG Perl-модули присутствуют"

# =============================================================================
section "3. Проверка и установка Python 3"
# =============================================================================

PYTHON=""
for candidate in python3.11 python3.10 python3.9 python3; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" --version 2>&1 | awk '{print $2}')
        major=$(echo "$ver" | cut -d. -f1)
        minor=$(echo "$ver" | cut -d. -f2)
        if [[ "$major" -ge 3 && "$minor" -ge 9 ]]; then
            PYTHON="$candidate"
            ok "Python найден: $PYTHON ($ver)"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    info "Python 3.9+ не найден, устанавливаем..."
    apt-get update -qq
    apt-get install -y python3 python3-dev
    PYTHON=python3
    ok "Python установлен: $($PYTHON --version)"
fi

# =============================================================================
section "4. Проверка и установка pip"
# =============================================================================

if ! "$PYTHON" -m pip --version &>/dev/null 2>&1; then
    info "pip не найден, устанавливаем..."
    # Сначала пробуем apt
    if apt-get install -y python3-pip &>/dev/null 2>&1; then
        ok "pip установлен через apt"
    else
        # Fallback: get-pip.py (apt недоступен или не содержит python3-pip)
        warn "apt не смог установить python3-pip — загружаем get-pip.py с bootstrap.pypa.io."
        warn "Файл выполняется без проверки контрольной суммы. Нажмите Ctrl+C, если это неприемлемо."
        sleep 3
        TMP_PIP=$(mktemp --suffix=.py)
        if command -v curl &>/dev/null; then
            curl -sSL https://bootstrap.pypa.io/get-pip.py -o "$TMP_PIP"
        elif command -v wget &>/dev/null; then
            wget -qO "$TMP_PIP" https://bootstrap.pypa.io/get-pip.py
        else
            apt-get install -y curl
            curl -sSL https://bootstrap.pypa.io/get-pip.py -o "$TMP_PIP"
        fi
        "$PYTHON" "$TMP_PIP" --quiet
        rm -f "$TMP_PIP"
        ok "pip установлен через get-pip.py"
    fi
fi
ok "pip: $("$PYTHON" -m pip --version | awk '{print $1,$2}')"

# =============================================================================
section "5. Установка Python-зависимостей"
# =============================================================================

REQUIRED_PKGS=(psycopg2-binary flask gunicorn "bleach>=6.2.0" tinycss2)

for pkg in "${REQUIRED_PKGS[@]}"; do
    pkg_name="${pkg%%[>=<!]*}"  # bleach>=6.2.0 → bleach
    pkg_name="${pkg_name%%-*}"  # psycopg2-binary → psycopg2
    if "$PYTHON" -c "import ${pkg_name//-/_}" &>/dev/null 2>&1; then
        ok "Python-пакет уже установлен: $pkg"
    else
        info "Устанавливаем Python-пакет: $pkg ..."
        "$PYTHON" -m pip install "$pkg" --quiet --break-system-packages \
            || "$PYTHON" -m pip install "$pkg" --quiet
        ok "Установлен: $pkg"
    fi
done

# =============================================================================
section "6. Сбор параметров конфигурации"
# =============================================================================

echo
info "Введите параметры установки (Enter — оставить значение по умолчанию)"
echo

# PMG hostname — берём из конфига PMG, иначе системный FQDN
default_pmg_hostname=$(perl -e 'use PMG::Config; my $c=PMG::Config->new(); print $c->get("spamquar","hostname")//"";' 2>/dev/null)
[[ -z "$default_pmg_hostname" ]] && default_pmg_hostname=$(hostname -f 2>/dev/null || hostname)
read -rp "  PMG hostname (публичный FQDN сервера) [$default_pmg_hostname]: " PMG_HOSTNAME
PMG_HOSTNAME="${PMG_HOSTNAME:-$default_pmg_hostname}"

# Почтовый сервер — берём relay и relayport прямо из конфига PMG
MAIL_HOST=$(perl -e 'use PMG::Config; my $c=PMG::Config->new(); print $c->get("mail","relay")//"";' 2>/dev/null)
MAIL_PORT=$(perl -e 'use PMG::Config; my $c=PMG::Config->new(); print $c->get("mail","relayport")//"";' 2>/dev/null)
[[ -z "$MAIL_HOST" ]] && MAIL_HOST="127.0.0.1"
[[ -z "$MAIL_PORT" ]] && MAIL_PORT="25"
ok "SMTP relay из конфига PMG: $MAIL_HOST:$MAIL_PORT"

# Адрес отправителя уведомлений (имя < адрес >)
default_postmaster="Антиспам-сервер <postmaster@${PMG_HOSTNAME#*.}>"
read -rp "  Имя и e-mail отправителя уведомлений [$default_postmaster]: " MAIL_FROM
MAIL_FROM="${MAIL_FROM:-$default_postmaster}"

# Порт action-сервера
echo
warn "Порт action-сервера должен быть доступен снаружи (пользователи нажимают кнопки из браузера)."
info "Не забудьте открыть его на внешнем файрволе/роутере (например, Mikrotik)."
read -rp "  Порт HTTPS action-сервера [8765]: " ACTION_PORT
ACTION_PORT="${ACTION_PORT:-8765}"

# Интервал cron
read -rp "  Интервал запуска notifier в минутах [5]: " CRON_INTERVAL
CRON_INTERVAL="${CRON_INTERVAL:-5}"
if ! [[ "$CRON_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$CRON_INTERVAL" -lt 1 ]] || [[ "$CRON_INTERVAL" -gt 60 ]]; then
    warn "Некорректное значение '$CRON_INTERVAL', используем 5 минут"
    CRON_INTERVAL=5
fi

# TTL токенов
read -rp "  Срок действия ссылок в письмах, дней [7]: " TOKEN_TTL
TOKEN_TTL="${TOKEN_TTL:-7}"
if ! [[ "$TOKEN_TTL" =~ ^[0-9]+$ ]] || [[ "$TOKEN_TTL" -lt 1 ]]; then
    warn "Некорректное значение '$TOKEN_TTL', используем 7 дней"
    TOKEN_TTL=7
fi

# Процент отображения тела письма
read -rp "  Показывать тело письма в уведомлении, % (0=нет, 100=полностью) [100]: " BODY_PERCENT
BODY_PERCENT="${BODY_PERCENT:-100}"
if ! [[ "$BODY_PERCENT" =~ ^[0-9]+$ ]]; then
    warn "Некорректное значение '$BODY_PERCENT', используем 100"
    BODY_PERCENT=100
elif [[ "$BODY_PERCENT" -gt 100 ]]; then
    warn "Значение '$BODY_PERCENT' > 100, обрезаем до 100"
    BODY_PERCENT=100
fi

# Минимальный порог для усечения тела (короткие письма показываются целиком)
read -rp "  Минимальный размер письма для усечения, символов [1000]: " BODY_MIN_CHARS
BODY_MIN_CHARS="${BODY_MIN_CHARS:-1000}"
if ! [[ "$BODY_MIN_CHARS" =~ ^[0-9]+$ ]]; then
    warn "Некорректное значение '$BODY_MIN_CHARS', используем 1000"
    BODY_MIN_CHARS=1000
fi

# SSL-сертификат — используем тот же, что PMG применяет для веб-интерфейса (порт 8006)
SSL_CERT="/etc/pmg/pmg-api.pem"

if [[ ! -f "$SSL_CERT" ]]; then
    warn "SSL-сертификат PMG не найден: $SSL_CERT"
    warn "Action-сервер будет запущен без SSL (только для внутренней сети / за reverse proxy)."
    warn "Когда сертификат появится — укажите его путь в /etc/pmg-quarantine-junk/config.ini (ssl_cert, ssl_key)."
    USE_SSL="false"
else
    USE_SSL="true"
    ok "SSL-сертификат: $SSL_CERT (тот же, что используется PMG для порта 8006)"
fi

PUBLIC_URL="https://${PMG_HOSTNAME}:${ACTION_PORT}"
if [[ "$USE_SSL" == "false" ]]; then
    PUBLIC_URL="http://${PMG_HOSTNAME}:${ACTION_PORT}"
fi

echo
info "Параметры конфигурации:"
echo "  PMG hostname:     $PMG_HOSTNAME"
echo "  Почтовый сервер:  $MAIL_HOST:$MAIL_PORT"
echo "  Отправитель:      $MAIL_FROM"
echo "  Action-сервер:    $PUBLIC_URL"
echo "  SSL:              $USE_SSL"
echo "  Cron интервал:    */$CRON_INTERVAL минут"
echo "  TTL токенов:      $TOKEN_TTL дней"
echo "  Показ тела:       $BODY_PERCENT% (порог: $BODY_MIN_CHARS симв.)"
echo
read -rp "Продолжить установку? [Y/n]: " confirm
[[ "${confirm,,}" != "n" ]] || { info "Установка отменена."; exit 0; }

# =============================================================================
section "7. Создание пользователя и директорий"
# =============================================================================

# Системный пользователь для action-сервера (не root)
if ! id pmg-quarantine &>/dev/null; then
    adduser --system --group --no-create-home --shell /usr/sbin/nologin pmg-quarantine
    ok "Пользователь pmg-quarantine создан"
else
    ok "Пользователь pmg-quarantine уже существует"
fi

# SSL-сертификат PMG принадлежит группе www-data — добавляем pmg-quarantine в неё
if getent group www-data &>/dev/null; then
    usermod -aG www-data pmg-quarantine
    ok "pmg-quarantine добавлен в группу www-data (доступ к SSL-сертификату PMG)"
fi

for dir in "$INSTALL_LIB" "$INSTALL_ETC" "$INSTALL_VAR"; do
    mkdir -p "$dir"
    ok "Директория: $dir"
done

# VAR-директория должна принадлежать pmg-quarantine: SQLite создаёт там journal-файлы
chown pmg-quarantine:pmg-quarantine "$INSTALL_VAR"
chmod 750 "$INSTALL_VAR"

# state.db — создаём заранее с правильным владельцем
touch "$INSTALL_VAR/state.db"
chown pmg-quarantine:pmg-quarantine "$INSTALL_VAR/state.db"
chmod 600 "$INSTALL_VAR/state.db"

touch "$INSTALL_LOG"
chown pmg-quarantine:pmg-quarantine "$INSTALL_LOG"
chmod 640 "$INSTALL_LOG"
ok "Лог-файл: $INSTALL_LOG"

# =============================================================================
section "8. Генерация HMAC-секрета"
# =============================================================================

SECRET_FILE="$INSTALL_ETC/secret.key"
if [[ -f "$SECRET_FILE" ]]; then
    warn "Секрет уже существует ($SECRET_FILE) — оставляем без изменений."
    warn "Если хотите перегенерировать — удалите файл и запустите установку повторно."
    warn "ВНИМАНИЕ: старые ссылки в уже отправленных письмах перестанут работать!"
else
    python3 -c "import secrets; open('$SECRET_FILE','w').write(secrets.token_hex(64))"
    chown root:pmg-quarantine "$SECRET_FILE"
    chmod 640 "$SECRET_FILE"
    ok "HMAC-секрет сгенерирован: $SECRET_FILE"
fi

# =============================================================================
section "9. Установка файлов"
# =============================================================================

# Библиотека — 640 root:pmg-quarantine
install -m 640 -o root -g pmg-quarantine "$SCRIPT_DIR/lib/common.py" "$INSTALL_LIB/common.py"
ok "Библиотека: $INSTALL_LIB/common.py"

# Бинарники — 750 root:pmg-quarantine (читают только root и сервисный пользователь)
install -m 750 -o root -g pmg-quarantine "$SCRIPT_DIR/bin/pmg-quarantine-do-action"     "$INSTALL_BIN/"
install -m 750 -o root -g pmg-quarantine "$SCRIPT_DIR/bin/pmg-quarantine-notifier"      "$INSTALL_BIN/"
install -m 750 -o root -g pmg-quarantine "$SCRIPT_DIR/bin/pmg-quarantine-action-server" "$INSTALL_BIN/"
install -m 750 -o root -g pmg-quarantine "$SCRIPT_DIR/bin/pmg-quarantine-gen-ticket"    "$INSTALL_BIN/"
ok "Исполняемые файлы установлены в $INSTALL_BIN/"

# Systemd unit
cp "$SCRIPT_DIR/systemd/pmg-quarantine-action-server.service" "$SYSTEMD_DIR/"
ok "Systemd unit: $SYSTEMD_DIR/pmg-quarantine-action-server.service"

# Logrotate
cp "$SCRIPT_DIR/logrotate/pmg-quarantine-junk" "$LOGROTATE_DIR/"
ok "Logrotate: $LOGROTATE_DIR/pmg-quarantine-junk"

# =============================================================================
section "10. Создание конфига"
# =============================================================================

CONFIG_FILE="$INSTALL_ETC/config.ini"

if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP"
    warn "Существующий конфиг сохранён как $BACKUP"
fi

cat > "$CONFIG_FILE" <<EOF
# pmg-quarantine-junk — автоматически сгенерирован install.sh
# $(date)

[general]
log_level = INFO

[pmg]
hostname  = ${PMG_HOSTNAME}
port      = 8006
db_host   = /var/run/postgresql
db_name   = Proxmox_ruledb
db_user   = root
db_port   = 5432
spool_dir = /var/spool/pmg

[tokens]
ttl_days = ${TOKEN_TTL}

[action_server]
public_url = ${PUBLIC_URL}
bind_host  = 0.0.0.0
port       = ${ACTION_PORT}
ssl        = ${USE_SSL}
ssl_cert   = ${SSL_CERT}
ssl_key    = ${SSL_CERT}

[smtp]
host     = ${MAIL_HOST}
port     = ${MAIL_PORT}
starttls = false
user     =
password =

[notifications]
mail_from      = ${MAIL_FROM}
body_percent   = ${BODY_PERCENT}
body_min_chars = ${BODY_MIN_CHARS}
EOF

chown root:pmg-quarantine "$CONFIG_FILE"
chmod 640 "$CONFIG_FILE"
ok "Конфиг: $CONFIG_FILE"

# =============================================================================
section "11. Настройка cron"
# =============================================================================

if [[ "$CRON_INTERVAL" -eq 1 ]]; then
    CRON_SCHEDULE="* * * * *"
else
    CRON_SCHEDULE="*/${CRON_INTERVAL} * * * *"
fi

cat > "$CRON_FILE" <<EOF
# pmg-quarantine-junk notifier
# Запускается каждые ${CRON_INTERVAL} мин. — сканирует карантин, отправляет уведомления
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
${CRON_SCHEDULE} root /usr/local/bin/pmg-quarantine-notifier >> /var/log/pmg-quarantine-junk.log 2>&1
EOF

ok "Cron: $CRON_FILE (каждые $CRON_INTERVAL мин.)"

# =============================================================================
section "12. Настройка sudo для action-сервера"
# =============================================================================

SUDOERS_FILE="/etc/sudoers.d/pmg-quarantine-junk"
cat > "$SUDOERS_FILE" <<'EOF'
# pmg-quarantine-junk: разрешаем action-серверу (pmg-quarantine) запускать
# pmg-quarantine-do-action от root (необходимо для доступа к PMG Perl-модулям)
pmg-quarantine ALL=(root) NOPASSWD: /usr/local/bin/pmg-quarantine-do-action
EOF
chmod 440 "$SUDOERS_FILE"
ok "Sudoers: $SUDOERS_FILE"

# =============================================================================
section "13. Firewall (локальный) + rate limiting"
# =============================================================================

RATE_LIMIT=30   # максимум новых соединений в минуту с одного IP на порт action-сервера

if command -v nft &>/dev/null; then
    NFT_CONF=/etc/nftables.conf

    # Добавляем правило rate limiting если его ещё нет
    if ! nft list ruleset 2>/dev/null | grep -q "port${ACTION_PORT}_limit"; then
        # Создаём таблицу/цепочку если нет, иначе только добавляем правило
        if ! nft list table inet filter &>/dev/null 2>&1; then
            nft add table inet filter
            nft add chain inet filter input '{ type filter hook input priority filter; }'
        fi
        nft add rule inet filter input \
            tcp dport "$ACTION_PORT" ct state new \
            meter "port${ACTION_PORT}_limit" \
            "{ ip saddr limit rate over ${RATE_LIMIT}/minute }" drop
        ok "nftables rate limiting: порт $ACTION_PORT — макс. $RATE_LIMIT новых соединений/мин с одного IP"
    else
        ok "nftables rate limiting для порта $ACTION_PORT уже настроен"
    fi

    # Сохраняем в /etc/nftables.conf
    if [[ -f "$NFT_CONF" ]]; then
        # Вставляем правило в секцию chain input если файл существует
        if ! grep -q "port${ACTION_PORT}_limit" "$NFT_CONF"; then
            sed -i "/chain input {/a\\\\t\\ttcp dport ${ACTION_PORT} ct state new meter port${ACTION_PORT}_limit { ip saddr limit rate over ${RATE_LIMIT}/minute } drop" "$NFT_CONF"
            ok "Правило rate limiting добавлено в $NFT_CONF"
        fi
        systemctl enable nftables &>/dev/null || true
        ok "nftables включён в автозапуск"
    else
        warn "Файл $NFT_CONF не найден — правило активно до перезагрузки."
        warn "Добавьте вручную в конфиг nftables:"
        warn "  tcp dport $ACTION_PORT ct state new meter port${ACTION_PORT}_limit { ip saddr limit rate over ${RATE_LIMIT}/minute } drop"
    fi

elif command -v iptables &>/dev/null; then
    # Fallback: iptables (для систем без nftables)
    if iptables -C INPUT -p tcp --dport "$ACTION_PORT" -j ACCEPT &>/dev/null 2>&1; then
        ok "Порт $ACTION_PORT уже открыт в iptables"
    else
        iptables -A INPUT -p tcp --dport "$ACTION_PORT" -m state --state NEW \
            -m recent --set
        iptables -A INPUT -p tcp --dport "$ACTION_PORT" -m state --state NEW \
            -m recent --update --seconds 60 --hitcount "$RATE_LIMIT" -j DROP
        ok "iptables rate limiting: порт $ACTION_PORT — макс. $RATE_LIMIT соединений/мин с одного IP"

        if command -v iptables-save &>/dev/null && [[ -f /etc/iptables/rules.v4 ]]; then
            iptables-save > /etc/iptables/rules.v4
            ok "Правила сохранены в /etc/iptables/rules.v4"
        fi
    fi
else
    warn "ни nftables, ни iptables не найдены. Убедитесь, что порт $ACTION_PORT открыт вручную."
fi

# =============================================================================
section "14. Ночные отчёты PMG о карантине"

# PMG может отправлять пользователям сводку карантина по расписанию (reportstyle).
# Наша система уведомляет о каждом письме в реальном времени —
# дублирующий ночной отчёт становится избыточным.

CURRENT_REPORTSTYLE=$(perl -e '
use PMG::Config;
my $c = PMG::Config->new();
print $c->get("spamquar", "reportstyle") // "none";
' 2>/dev/null)

if [[ -z "$CURRENT_REPORTSTYLE" ]]; then
    warn "Не удалось прочитать настройку reportstyle из PMG::Config — пропуск."
elif [[ "$CURRENT_REPORTSTYLE" == "none" ]]; then
    ok "Отчёты о карантине для пользователей уже отключены (reportstyle = none)"
else
    echo
    warn "В настройках PMG включены отчёты о карантине для пользователей."
    info "  Текущее значение: reportstyle = $CURRENT_REPORTSTYLE"
    info "  Это означает, что пользователи будут получать сводку карантина по расписанию PMG."
    info "  Поскольку pmg-quarantine-junk уведомляет о каждом письме в реальном времени,"
    info "  ночные отчёты PMG становятся избыточными."
    echo
    if ask_yn "Установить reportstyle = none (отключить ночные отчёты PMG, рекомендуется)?"; then
        perl -e '
use PMG::Config;
my $c = PMG::Config->new();
$c->set("spamquar", "reportstyle", "none");
$c->write();
print "OK\n";
' 2>&1
        ok "reportstyle установлен в none — ночные отчёты PMG отключены"
        echo
        warn "Если захотите вернуть ночные отчёты PMG:"
        warn "  В GUI: Quarantine → Options → Спам-отчёт → выбрать нужный стиль"
        warn "  Или: perl -e 'use PMG::Config; my \$c=PMG::Config->new(); \$c->set(\"spamquar\",\"reportstyle\",\"custom\"); \$c->write();'"
    else
        warn "reportstyle оставлен: $CURRENT_REPORTSTYLE"
        warn "Пользователи будут получать ДВА уведомления:"
        warn "  1. Письмо в реальном времени (pmg-quarantine-notifier)"
        warn "  2. Отчёт PMG согласно настройке reportstyle = $CURRENT_REPORTSTYLE"
    fi
fi

section "15. Запуск systemd-сервиса"
# =============================================================================

systemctl daemon-reload
systemctl enable pmg-quarantine-action-server
systemctl restart pmg-quarantine-action-server

sleep 2

if systemctl is-active --quiet pmg-quarantine-action-server; then
    ok "Сервис запущен: pmg-quarantine-action-server"
else
    error "Сервис не запустился! Проверьте логи:"
    error "  journalctl -u pmg-quarantine-action-server -n 30"
    error "  cat $INSTALL_LOG"
fi

# =============================================================================
section "16. Проверка работоспособности"
# =============================================================================

sleep 1
CHECK_PROTO="$( [[ "$USE_SSL" == "true" ]] && echo "https" || echo "http" )"
CHECK_URL="${CHECK_PROTO}://127.0.0.1:${ACTION_PORT}/action"
if command -v curl &>/dev/null; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$CHECK_URL" 2>/dev/null || true)
    if [[ "$HTTP_CODE" == "400" ]]; then
        ok "Action-сервер отвечает: $CHECK_URL → HTTP $HTTP_CODE (ожидаемо без токена)"
    elif [[ -n "$HTTP_CODE" && "$HTTP_CODE" != "000" ]]; then
        ok "Action-сервер отвечает: $CHECK_URL → HTTP $HTTP_CODE"
    else
        warn "Action-сервер не ответил (возможно, ещё стартует). Проверьте: journalctl -u pmg-quarantine-action-server -n 20"
    fi
fi

# =============================================================================
section "17. Первый запуск notifier (тест)"
# =============================================================================

info "Запускаем pmg-quarantine-notifier для проверки..."
if /usr/local/bin/pmg-quarantine-notifier; then
    ok "Notifier отработал без ошибок"
else
    warn "Notifier завершился с ошибкой. Проверьте конфиг и лог: $INSTALL_LOG"
fi

# =============================================================================
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          pmg-quarantine-junk установлен!             ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  Конфиг:       ${BOLD}$CONFIG_FILE${RESET}"
echo -e "  Лог:          ${BOLD}$INSTALL_LOG${RESET}"
echo -e "  Action URL:   ${BOLD}$PUBLIC_URL/action${RESET}"
echo -e "  Cron:         ${BOLD}каждые $CRON_INTERVAL мин.${RESET}"
echo
echo -e "  Полезные команды:"
echo -e "    systemctl status pmg-quarantine-action-server"
echo -e "    journalctl -u pmg-quarantine-action-server -f"
echo -e "    tail -f $INSTALL_LOG"
echo -e "    /usr/local/bin/pmg-quarantine-notifier   # ручной запуск"
echo
echo -e "  Для удаления: ${BOLD}$SCRIPT_DIR/uninstall.sh${RESET}"
echo
