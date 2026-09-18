# Резервное копирование PostgreSQL

Скрипт `postgres-backup.sh` выполняет резервное копирование PostgreSQL в production-ориентированном режиме.

Алгоритм работы:

1. Проверяется окружение и доступность необходимых команд.
2. Проверяется подключение к PostgreSQL.
3. Определяется список доступных баз данных.
4. Отдельно создаётся дамп глобальных объектов PostgreSQL.
5. Для каждой базы создаётся дамп в custom-формате.
6. Каждый дамп сжимается в gzip-архив.
7. Архив проверяется командой `gzip -t`.
8. Архив копируется в `/backups` во временный файл с суффиксом `.tmp`.
9. Временный архив повторно проверяется.
10. После успешной проверки выполняется атомарное переименование `.tmp` в финальное имя.
11. Удаляются архивы старше заданного срока хранения.
12. Возвращается итоговый код завершения и записывается результат в журнал.

## Состав проекта

| Файл | Назначение |
|---|---|
| `postgres-backup.sh` | Основной скрипт резервного копирования |
| `postgresql-backup.conf` | Конфигурация подключения и каталогов |
| `install.sh` | Установка на Linux-сервер |
| `postgresql-backup.logrotate` | Ротация файла журнала |

## Требования

Скрипт рассчитан на Linux и Bash.

Необходимы:

- PostgreSQL client utilities:
  - `psql`;
  - `pg_dump`;
  - `pg_dumpall`;
- `gzip`;
- `flock`;
- `df`;
- `find`;
- `stat`;
- `mktemp`;
- `awk`;
- `logger`.

Пользователь PostgreSQL, указанный в конфигурации, должен иметь права на подключение к серверу, получение списка баз и чтение объектов, которые необходимо резервировать.

Каталог `/backups` должен находиться на отдельном диске или файловой системе. Сам скрипт проверяет существование каталога и возможность записи; контроль факта монтирования отдельного диска должен выполняться средствами операционной системы или мониторинга.

## Установка

Перед установкой проверьте конфигурацию:

```bash
cat postgresql-backup.conf
```

Основные параметры:

```bash
PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="backup_user"

BACKUP_DIR="/backups"
TMP_DIR="/var/tmp/postgresql-backup"
LOG_FILE="/var/log/postgresql-backup/backup.log"
RUN_DIR="/var/lib/backup/run"

SPACE_SAFETY_FACTOR=0.05
BACKUP_RETENTION_DAYS=14
```

Установщик интерактивно запросит пароль и создаст файл `.pgpass`.

Запустите установку из каталога проекта:

```bash
sudo ./install.sh
```

Установщик:

- создаёт системного пользователя `backup`;
- создаёт каталоги для архивов, временных файлов, логов и блокировки;
- устанавливает скрипт в `/usr/local/bin/postgres-backup.sh`;
- устанавливает конфигурацию в `/etc/postgresql-backup.conf`;
- создаёт `/var/lib/backup/.pgpass`;
- устанавливает права доступа;
- устанавливает конфигурацию `logrotate`;
- проверяет подключение к PostgreSQL;
- проверяет доступ к каталогам;
- проверяет синтаксис установленного скрипта.

## Ручной запуск

Скрипт следует запускать от выделенного пользователя `backup`:

```bash
sudo -u backup /usr/local/bin/postgres-backup.sh
```

## Проверка результата

Проверка журнала:

```bash
sudo tail -n 100 /var/log/postgresql-backup/backup.log
```

Проверка сообщений в syslog/journald:

```bash
sudo journalctl -t postgresql-backup --since "1 hour ago"
```

## Планирование запуска

Пример запуска через cron от имени пользователя `backup`:

```cron
15 2 * * * /usr/local/bin/postgres-backup.sh
```
## Через systemd
#### postgresql-backup.service

```bash
[Unit]
Description=PostgreSQL Backup

[Service]
Type=oneshot
User=backup
ExecStart=/usr/local/bin/postgres-backup.sh
```

#### postgresql-backup.timer
```bash
[Unit]
Description=Run PostgreSQL Backup daily

[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true

[Install]
WantedBy=timers.target
```

После создания:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now postgresql-backup.timer
```