#!/bin/bash

set -e

# ------------------------------------------------------------
# Резервное копирование PostgreSQL - установка в продакшене
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Пользователи
# ------------------------------------------------------------

BACKUP_USER="backup"
BACKUP_GROUP="backup"

# ------------------------------------------------------------
# Каталоги
# ------------------------------------------------------------

BACKUP_DIR="/backups"
TMP_DIR="/var/tmp/postgresql-backup"
LOG_DIR="/var/log/postgresql-backup"
LOG_FILE="${LOG_DIR}/backup.log"
RUN_DIR="/var/lib/backup/run"


BACKUP_HOME="/var/lib/backup"
PGPASS_FILE="${BACKUP_HOME}/.pgpass"

# ------------------------------------------------------------
# Пути установки
# ------------------------------------------------------------

INSTALL_SCRIPT="/usr/local/bin/postgres-backup.sh"
CONFIG_FILE="/etc/postgresql-backup.conf"
LOGROTATE_FILE="/etc/logrotate.d/postgresql-backup"

# ------------------------------------------------------------
# Подключение к PostgreSQL
# ------------------------------------------------------------

PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="backup_user"

# ------------------------------------------------------------
# Проверка root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: this installer must be run as root"
    echo
    echo "Run:"
    echo "  sudo $0"
    exit 1
fi

# ------------------------------------------------------------
# Проверка необходимых файлов
# ------------------------------------------------------------

if [[ ! -f "${SCRIPT_DIR}/postgres-backup.sh" ]]; then
    echo "ERROR: postgres-backup.sh not found"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/postgresql-backup.conf" ]]; then
    echo "ERROR: postgresql-backup.conf not found"
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/postgresql-backup.logrotate" ]]; then
    echo "ERROR: postgresql-backup.logrotate not found"
    exit 1
fi

# ------------------------------------------------------------
# Создание системного пользователя для резервного копирования
# ------------------------------------------------------------

echo "Checking backup user..."

if id "${BACKUP_USER}" >/dev/null 2>&1; then

    echo "User '${BACKUP_USER}' already exists."

else

    echo "Creating user '${BACKUP_USER}'..."

    useradd \
        --system \
        --home-dir "${BACKUP_HOME}" \
        --create-home \
        --shell /usr/sbin/nologin \
        "${BACKUP_USER}"

fi

# ------------------------------------------------------------
# Проверка пользователя резервного копирования
# ------------------------------------------------------------

if ! id "${BACKUP_USER}" >/dev/null 2>&1; then
    echo "ERROR: failed to create user '${BACKUP_USER}'"
    exit 1
fi

# ------------------------------------------------------------
# Создание каталогов
# ------------------------------------------------------------

echo "Creating directories..."

mkdir -p "${BACKUP_DIR}"
mkdir -p "${TMP_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${RUN_DIR}"
mkdir -p "${BACKUP_HOME}"

# ------------------------------------------------------------
# Установка владельца
# ------------------------------------------------------------

echo "Setting ownership..."

chown "${BACKUP_USER}:${BACKUP_GROUP}" "${BACKUP_DIR}"
chown "${BACKUP_USER}:${BACKUP_GROUP}" "${TMP_DIR}"
chown "${BACKUP_USER}:${BACKUP_GROUP}" "${LOG_DIR}"
chown "${BACKUP_USER}:${BACKUP_GROUP}" "${BACKUP_HOME}"
chown "${BACKUP_USER}:${BACKUP_GROUP}" "${RUN_DIR}"

# ------------------------------------------------------------
# Установка прав доступа
# ------------------------------------------------------------

echo "Setting permissions..."

chmod 750 "${BACKUP_DIR}"
chmod 700 "${TMP_DIR}"
chmod 750 "${LOG_DIR}"
chmod 750 "${RUN_DIR}"
chmod 750 "${BACKUP_HOME}"

# ------------------------------------------------------------
# Установка скрипта резервного копирования
# ------------------------------------------------------------

echo "Installing backup script..."

install \
    -o root \
    -g "${BACKUP_GROUP}" \
    -m 750 \
    "${SCRIPT_DIR}/postgres-backup.sh" \
    "${INSTALL_SCRIPT}"

# ------------------------------------------------------------
# Установка конфигурации
# ------------------------------------------------------------

echo "Installing configuration..."

install \
    -o root \
    -g "${BACKUP_GROUP}" \
    -m 640 \
    "${SCRIPT_DIR}/postgresql-backup.conf" \
    "${CONFIG_FILE}"

# ------------------------------------------------------------
# Создание файла журнала
# ------------------------------------------------------------

echo "Creating log file..."

touch "${LOG_FILE}"

chown "${BACKUP_USER}:${BACKUP_GROUP}" "${LOG_FILE}"
chmod 640 "${LOG_FILE}"

# ------------------------------------------------------------
# Установка конфигурации logrotate
# ------------------------------------------------------------

echo "Installing logrotate configuration..."

install \
    -o root \
    -g root \
    -m 644 \
    "${SCRIPT_DIR}/postgresql-backup.logrotate" \
    "${LOGROTATE_FILE}"

# ------------------------------------------------------------
# Создание .pgpass для PostgreSQL
# ------------------------------------------------------------

echo
echo "PostgreSQL credentials"
echo "----------------------"
echo "Host:     ${PGHOST}"
echo "Port:     ${PGPORT}"
echo "User:     ${PGUSER}"
echo

read -r -s -p "Enter PostgreSQL password for ${PGUSER}: " PG_PASSWORD
echo

if [[ -z "${PG_PASSWORD}" ]]; then
    echo "ERROR: PostgreSQL password cannot be empty"
    exit 1
fi

echo "Creating ${PGPASS_FILE}..."

printf '%s:%s:*:%s:%s\n' \
    "${PGHOST}" \
    "${PGPORT}" \
    "${PGUSER}" \
    "${PG_PASSWORD}" \
    > "${PGPASS_FILE}"

unset PG_PASSWORD

chown "${BACKUP_USER}:${BACKUP_GROUP}" "${PGPASS_FILE}"
chmod 600 "${PGPASS_FILE}"

# ------------------------------------------------------------
# Проверка .pgpass
# ------------------------------------------------------------

echo "Checking PostgreSQL credentials..."

if ! sudo -u "${BACKUP_USER}" \
    env PGPASSFILE="${PGPASS_FILE}" \
    psql \
        -h "${PGHOST}" \
        -p "${PGPORT}" \
        -U "${PGUSER}" \
        -d postgres \
        -c "SELECT current_user;" \
        >/dev/null 2>&1
then

    echo
    echo "ERROR: PostgreSQL authentication failed."
    echo
    echo "Check:"
    echo "  - PostgreSQL is running"
    echo "  - user '${PGUSER}' exists"
    echo "  - password is correct"
    echo "  - pg_hba.conf allows this connection"
    echo

    exit 1
fi

echo "PostgreSQL credentials: OK"

# ------------------------------------------------------------
# Проверка каталогов резервных копий
# ------------------------------------------------------------

echo "Checking backup directories..."

if ! sudo -u "${BACKUP_USER}" test -w "${BACKUP_DIR}"; then
    echo "ERROR: ${BACKUP_USER} cannot write to ${BACKUP_DIR}"
    exit 1
fi

if ! sudo -u "${BACKUP_USER}" test -w "${TMP_DIR}"; then
    echo "ERROR: ${BACKUP_USER} cannot write to ${TMP_DIR}"
    exit 1
fi

if ! sudo -u "${BACKUP_USER}" test -w "${LOG_DIR}"; then
    echo "ERROR: ${BACKUP_USER} cannot write to ${LOG_DIR}"
    exit 1
fi

echo "Backup directories: OK"

# ------------------------------------------------------------
# Проверка синтаксиса установленного скрипта
# ------------------------------------------------------------

echo "Checking backup script syntax..."

bash -n "${INSTALL_SCRIPT}"

echo "Backup script syntax: OK"

# ------------------------------------------------------------
# Результат
# ------------------------------------------------------------

echo
echo "============================================================"
echo "PostgreSQL backup installation completed successfully"
echo "============================================================"
echo
echo "Linux user:"
echo "  ${BACKUP_USER}"
echo
echo "Backup directory:"
echo "  ${BACKUP_DIR}"
echo
echo "Temporary directory:"
echo "  ${TMP_DIR}"
echo
echo "Log directory:"
echo "  ${LOG_DIR}"
echo
echo "Log file:"
echo "  ${LOG_FILE}"
echo
echo "Runtime directory:"
echo "  ${RUN_DIR}"
echo
echo "PostgreSQL credentials:"
echo "  ${PGPASS_FILE}"
echo
echo "Backup script:"
echo "  ${INSTALL_SCRIPT}"
echo
echo "Configuration:"
echo "  ${CONFIG_FILE}"
echo
echo "Logrotate:"
echo "  ${LOGROTATE_FILE}"
echo
echo "Run backup:"
echo "  sudo -u ${BACKUP_USER} ${INSTALL_SCRIPT}"
echo
