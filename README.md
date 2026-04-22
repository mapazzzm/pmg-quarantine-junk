# pmg-quarantine-junk

Система интерактивных уведомлений о карантине для **Proxmox Mail Gateway (PMG)**.

Вместо безликого ночного отчёта пользователь получает письмо **во Входящие** сразу после попадания сообщения в карантин. Письмо содержит превью заблокированного сообщения и две кнопки действия:

| Кнопка | Действие |
|--------|----------|
| ✅ **Не спам — доставить** | Отправитель → Whitelist PMG, письмо доставляется из карантина |
| ✖ **Спам — заблокировать** | Отправитель → Blacklist PMG, письмо удаляется из карантина |

Нажатие кнопки открывает страницу с результатом — никакой авторизации от пользователя не требуется. Страница автоматически закрывается через несколько секунд (если браузер это разрешает).

---

## Требования

| Компонент | Версия |
|-----------|--------|
| Proxmox Mail Gateway | 7.x / 8.x |
| Debian | 11 (Bullseye) / 12 (Bookworm) |
| Python | 3.9+ (устанавливается автоматически) |
| PostgreSQL | входит в стандартную установку PMG |

Почтовый сервер для доставки уведомлений: **любой SMTP-relay** (Carbonio, Zimbra, Postfix и т.п.).

---

## Быстрая установка

Выполните на сервере PMG от root:

```bash
git clone https://github.com/mapazzzm/pmg-quarantine-junk.git
cd pmg-quarantine-junk
bash install.sh
```

Или однострочником без клонирования:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mapazzzm/pmg-quarantine-junk/main/install.sh)
```

> Скрипт задаёт несколько вопросов (hostname, порт, адрес отправителя) и делает всё остальное автоматически.

---

## Что делает установочный скрипт

1. Проверяет ОС (Debian/Ubuntu), наличие PMG, доступность базы данных
2. Устанавливает Python 3 и pip, если отсутствуют
3. Устанавливает Python-зависимости: `psycopg2-binary`, `flask`, `gunicorn`, `bleach`, `tinycss2`
4. Спрашивает параметры: hostname PMG, адрес отправителя, порт action-сервера
5. Автоматически читает из конфига PMG: relay-сервер, SSL-сертификат
6. Создаёт системного пользователя `pmg-quarantine` для запуска action-сервера
7. Генерирует уникальный HMAC-секрет для подписи токенов
8. Устанавливает файлы в стандартные системные пути с правильными правами
9. Настраивает `sudo` — строго ограниченный доступ к одному бинарнику
10. Создаёт конфиг `/etc/pmg-quarantine-junk/config.ini`
11. Включает и запускает systemd-сервис `pmg-quarantine-action-server`
12. Добавляет cron-задание (по умолчанию каждые 5 минут, настраивается)
13. Предлагает отключить штатные ночные отчёты PMG (они станут дублирующими)
14. Выполняет тестовый прогон notifier и health-check action-сервера

---

## Архитектура

```
Cron (*/5 минут)
  └─► pmg-quarantine-notifier
        ├─ Читает CMailStore + CMSReceivers (PostgreSQL / Proxmox_ruledb)
        ├─ Разбирает .eml из /var/spool/pmg/spam/
        ├─ Генерирует HMAC-SHA256 токены (TTL 7 дней)
        ├─ Отправляет HTML-письмо во Входящие (SMTP → почтовый сервер)
        └─ Запоминает уведомлённые ID (SQLite) — повторов нет

Пользователь нажимает кнопку в письме
  └─► HTTPS GET https://pmg.example.com:8765/action?token=...
        └─► pmg-quarantine-action-server (Flask, systemd)
              ├─ Проверяет HMAC-подпись и срок действия токена
              ├─ Проверяет, не использован ли токен повторно (SQLite)
              ├─ Вызывает pmg-quarantine-do-action <id> <whitelist|blacklist>
              │     └─► PMG::Quarantine Perl-модули (прямой вызов без API)
              └─► Возвращает HTML-страницу с результатом действия
```

---

## Содержимое уведомления

Каждое письмо-уведомление содержит:

- **Кнопки действий** — вверху письма, чтобы не нужно было скроллить
- **Реквизиты** — От кого, Тема, Дата оригинального письма
- **Вложения** — список файлов с именами, типами и размерами (если есть)
- **Тело письма** — текст/HTML с сохранением форматирования (ссылки и изображения удалены в целях безопасности)
- **Ссылка на карантин PMG** — с автоматической авторизацией (как в штатных отчётах PMG)

Отображение тела письма управляется двумя параметрами:

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `body_percent` | Какой процент текста показывать (0 = не показывать, 100 = полностью) | `100` |
| `body_min_chars` | Если тело письма короче этого числа символов — показывается целиком, `body_percent` игнорируется | `1000` |

---

## Настройка файрвола

Action-сервер слушает на порту **8765** (настраивается). Этот порт должен быть доступен снаружи — пользователи нажимают кнопки из браузера.

**Локальный rate limiting** настраивается автоматически при установке:
- На системах с **nftables** (Debian 11+): правило `limit rate over 30/minute` на порт action-сервера — защита от DoS-флуда с одного IP
- На системах с **iptables**: аналогичное правило через `--hitcount`

Откройте порт на **внешнем роутере/файрволе** (Mikrotik, pfSense и т.п.):

```
Назначение: IP_вашего_PMG:8765
Протокол: TCP
Направление: входящий (из интернета)
```

---

## Файловая структура после установки

```
/usr/local/bin/
  pmg-quarantine-notifier         ← cron-скрипт сканирования карантина
  pmg-quarantine-action-server    ← HTTPS-сервис обработки нажатий кнопок
  pmg-quarantine-do-action        ← Perl: прямой вызов PMG::Quarantine
  pmg-quarantine-gen-ticket       ← Perl: генерация авто-auth ссылки PMG

/usr/local/lib/pmg-quarantine-junk/
  common.py                       ← общие утилиты (токены, SQLite, SMTP)

/etc/pmg-quarantine-junk/
  config.ini                      ← конфигурация (root:pmg-quarantine 640)
  secret.key                      ← HMAC-секрет (root:pmg-quarantine 640)

/var/lib/pmg-quarantine-junk/
  state.db                        ← SQLite: уведомлённые ID, использованные токены (pmg-quarantine 600)

/var/log/pmg-quarantine-junk.log  ← единый лог (logrotate: 14 дней)

/etc/systemd/system/
  pmg-quarantine-action-server.service

/etc/sudoers.d/
  pmg-quarantine-junk             ← sudo: pmg-quarantine → do-action (только этот бинарник)

/etc/cron.d/
  pmg-quarantine-junk
```

---

## Конфигурация

Файл: `/etc/pmg-quarantine-junk/config.ini`  
Пример: [`config/config.ini.example`](config/config.ini.example)

Обязательные параметры:

| Параметр | Описание |
|----------|----------|
| `[pmg] hostname` | FQDN PMG-сервера (публичный) |
| `[action_server] public_url` | Публичный URL action-сервера, вставляется в письма |
| `[smtp] host` | IP/hostname SMTP-сервера для отправки уведомлений |
| `[notifications] mail_from` | Адрес отправителя уведомлений |
| `[notifications] body_percent` | Процент тела письма в уведомлении (0–100, по умолчанию 100) |
| `[notifications] body_min_chars` | Порог (символов): короче — показывать целиком (по умолчанию 1000) |

После изменения конфига:

```bash
systemctl restart pmg-quarantine-action-server
```

---

## Управление

```bash
# Статус сервиса
systemctl status pmg-quarantine-action-server

# Логи в реальном времени
journalctl -u pmg-quarantine-action-server -f
tail -f /var/log/pmg-quarantine-junk.log

# Ручной запуск notifier (для теста)
/usr/local/bin/pmg-quarantine-notifier

# Проверка доступности action-сервера (должен вернуть HTTP 400)
curl -sk -o /dev/null -w "%{http_code}" https://pmg.example.com:8765/action
```

---

## Безопасность

- **Непривилегированный процесс**: action-сервер работает от системного пользователя `pmg-quarantine`, а не от root
- **Минимальный sudo**: `pmg-quarantine` может запускать через sudo строго один бинарник — `pmg-quarantine-do-action`
- **HMAC-SHA256**: все ссылки в письмах подписаны уникальным секретом, хранящимся только на сервере
- **TTL токенов**: по умолчанию 7 дней (настраивается в `[tokens] ttl_days`)
- **Атомарная защита от повтора**: используется `INSERT OR IGNORE` в SQLite — исключает состояние гонки (TOCTOU) при одновременных нажатиях
- **Разделение действий**: токен для whitelist не сработает как blacklist и наоборот
- **Без PMG API**: действия выполняются через прямой вызов Perl-модулей PMG — не открывает дополнительных сетевых поверхностей атаки
- **SSL**: action-сервер использует тот же Let's Encrypt сертификат, что и веб-интерфейс PMG
- **Production WSGI**: action-сервер работает на **gunicorn** (2 воркера) — не Flask dev-server; защищён от slowloris и конкурентных запросов
- **Ограничение запросов**: gunicorn настроен с `limit_request_line`, `limit_request_fields`, `limit_request_field_size` — отклоняет аномально большие HTTP-запросы
- **Rate limiting**: nftables/iptables ограничивают число новых соединений с одного IP (30/мин) — защита от DoS на уровне ОС
- **HTML-санитайзер**: тело письма в уведомлении очищается через **bleach** (Mozilla) — battle-tested библиотека; удаляет скрипты, ссылки, трекеры, опасные CSS-свойства
- **Права на файлы**: бинарники `750 root:pmg-quarantine`, конфиги и библиотека `640 root:pmg-quarantine` — исходный код недоступен посторонним пользователям системы
- **Валидация токенов**: quarantine_id проверяется regex `^C\d+R\d+T\d+$`, pmail — как email-адрес; невалидные значения отклоняются до выполнения любых действий

---

## Удаление

```bash
bash uninstall.sh
```

Конфиг, база данных и логи сохраняются. Для полного удаления:

```bash
rm -rf /etc/pmg-quarantine-junk /var/lib/pmg-quarantine-junk /var/log/pmg-quarantine-junk.log
```

---

## Лицензия

MIT
