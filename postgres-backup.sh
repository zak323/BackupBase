#!/bin/bash

set -Eeuo pipefail
umask 077

CONFIG_FILE="/etc/postgresql-backup.conf"

# ------------------------------------------------------------
# Конфигурация
# ------------------------------------------------------------

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"
cd /

HOSTNAME=$(hostname)

LOCK_FILE="${RUN_DIR}/backup.lock"

# ------------------------------------------------------------
# Журналирование
# ------------------------------------------------------------

log() {
    local level="$1"
    shift

    local message
    local priority

    message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"

    echo "$message" >> "$LOG_FILE"

    case "$level" in
        INFO|OK)
            priority="info"
            ;;
        WARN)
            priority="warning"
            ;;
        ERROR)
            priority="err"
            ;;
        *)
            priority="info"
            ;;
    esac

    logger -t postgresql-backup -p "user.${priority}" "$*" || true
}

info() {
    log "INFO" "$@"
}

success() {
    log "OK" "$@"
}

warn() {
    log "WARN" "$@"
}

error() {
    log "ERROR" "$@"
}

# ------------------------------------------------------------
# Проверка наличия необходимых команд
# ------------------------------------------------------------

REQUIRED_COMMANDS=(
    pg_dump
    pg_dumpall
    psql
    gzip
    find
    stat
    df
    logger
    mktemp
    cp
    mv
    rm
    awk
    grep
    date
    hostname
    flock
)

for command in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        error "Required command not found: $command"
        exit 1
    fi
done

# ------------------------------------------------------------
# Очистка
# ------------------------------------------------------------

CURRENT_TMP=""

cleanup_current_tmp() {
    if [[ -n "${CURRENT_TMP:-}" && -e "$CURRENT_TMP" ]]; then
        if rm -rf -- "$CURRENT_TMP"; then
            CURRENT_TMP=""
        else
            error "Failed to remove temporary directory: $CURRENT_TMP"
            return 1
        fi
    fi

    return 0
}

cleanup() {
    cleanup_current_tmp || true
}

trap cleanup EXIT

# ------------------------------------------------------------
# Неожиданные ошибки
# ------------------------------------------------------------

on_error() {
    local exit_code=$?

    error "Backup process stopped unexpectedly. Exit code: $exit_code"

    exit "$exit_code"
}

trap on_error ERR

# ------------------------------------------------------------
# Блокировка
# ------------------------------------------------------------

if [[ ! -d "$RUN_DIR" ]]; then
    error "Runtime directory does not exist: $RUN_DIR"
    exit 1
fi

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    error "Backup is already running"
    exit 1
fi

# ------------------------------------------------------------
# Базовая проверка
# ------------------------------------------------------------

if [[ ! -d "$BACKUP_DIR" ]]; then
    error "Backup directory does not exist: $BACKUP_DIR"
    exit 1
fi

if [[ ! -w "$BACKUP_DIR" ]]; then
    error "Backup directory is not writable: $BACKUP_DIR"
    exit 1
fi

if [[ ! -d "$TMP_DIR" ]]; then
    error "Temporary directory does not exist: $TMP_DIR"
    exit 1
fi

if [[ ! -w "$TMP_DIR" ]]; then
    error "Temporary directory is not writable: $TMP_DIR"
    exit 1
fi

# ------------------------------------------------------------
# Проверка учетных данных PostgreSQL
# ------------------------------------------------------------

check_postgres_credentials() {

    local error_message

    if error_message=$(
        psql \
            -X \
            -A \
            -t \
            -q \
            -h "$PGHOST" \
            -p "$PGPORT" \
            -U "$PGUSER" \
            -d "template1" \
            -c "SELECT 1;" \
            2>&1
    ); then

        success "PostgreSQL connection verified"
        return 0
    fi

    if grep -qi "password authentication failed" <<< "$error_message"; then
        error "PostgreSQL authentication failed for user '$PGUSER'"
        return 1
    fi

    if grep -qi "role .* does not exist" <<< "$error_message"; then
        error "PostgreSQL user does not exist: $PGUSER"
        return 1
    fi

    error "PostgreSQL connection failed"

    return 1
}

# ------------------------------------------------------------
# Проверка свободного места на диске
# ------------------------------------------------------------

check_disk_space() {

    local path="$1"
    local required_bytes="$2"

    local free_kb
    local free_bytes
    local required_mib
    local free_mib

    free_kb=$(df -Pk "$path" | awk 'NR==2 {print $4}')
    free_bytes=$((free_kb * 1024))

    if (( free_bytes < required_bytes )); then

        required_mib=$((required_bytes / 1024 / 1024))
        free_mib=$((free_bytes / 1024 / 1024))

        error "Not enough free space on $path: required=${required_mib} MiB, available=${free_mib} MiB"

        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Выбор административной базы для подключения
# ------------------------------------------------------------

select_admin_database() {

    if psql \
        -X \
        -A \
        -t \
        -q \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U "$PGUSER" \
        -d "postgres" \
        -c "SELECT 1;" \
        >/dev/null 2>&1
    then

        PGDATABASE="postgres"
        return 0
    fi

    if psql \
        -X \
        -A \
        -t \
        -q \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U "$PGUSER" \
        -d "template1" \
        -c "SELECT 1;" \
        >/dev/null 2>&1
    then

        PGDATABASE="template1"
        return 0
    fi

    error "Cannot connect to either 'postgres' or 'template1'"
    return 1
}

# ------------------------------------------------------------
# Получение списка баз данных
# ------------------------------------------------------------

get_databases() {

    local databases

    if ! databases=$(
        psql \
            -X \
            -A \
            -t \
            -q \
            -h "$PGHOST" \
            -p "$PGPORT" \
            -U "$PGUSER" \
            -d "$PGDATABASE" \
            -c "
                SELECT datname
                FROM pg_database
                WHERE datallowconn = true
                  AND datistemplate = false
                  AND datname NOT IN ('postgres', 'template0', 'template1')
                ORDER BY datname;
            "
    ); then

        error "Failed to get database list"
        return 1
    fi

    if [[ -z "$databases" ]]; then
        error "Database list is empty"
        return 1
    fi

    printf '%s\n' "$databases"
}

# ------------------------------------------------------------
# Резервное копирование одной базы данных
# ------------------------------------------------------------

backup_database() {

    local database="$1"
    local is_globals="$2"
    local backup_name="$database"

    if [[ ! "$is_globals" =~ ^(true|false)$ ]]; then
        error "Invalid global objects flag: $is_globals"
        return 1
    fi

    if [[ "$is_globals" == "false" && ! "$database" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Unsupported database name for filesystem path: $database"
        return 1
    fi

    if [[ "$is_globals" == "true" ]]; then
        backup_name="global objects"
    fi

    info "Backup started: $backup_name"

    if ! CURRENT_TMP=$(mktemp -d "$TMP_DIR/${database}.XXXXXX"); then
        error "Failed to create temporary directory: $backup_name"
        return 1
    fi

    local dump_file
    local archive_file

    if [[ "$is_globals" == "true" ]]; then
        dump_file="$CURRENT_TMP/globals.sql"
        archive_file="$CURRENT_TMP/globals.sql.gz"
    else
        dump_file="$CURRENT_TMP/${database}.dump"
        archive_file="$CURRENT_TMP/${database}.dump.gz"
    fi

    # --------------------------------------------------------
    # Создание дампа
    # --------------------------------------------------------

    if [[ "$is_globals" == "true" ]]; then

        local required_globals_space

        required_globals_space=$((100 * 1024 * 1024))

        if ! check_disk_space "$TMP_DIR" "$required_globals_space"; then
            error "Not enough temporary disk space for global objects"
            cleanup_current_tmp
            return 1
        fi

        if ! pg_dumpall \
            --globals-only \
            -h "$PGHOST" \
            -p "$PGPORT" \
            -U "$PGUSER" \
            > "$dump_file"
        then
            error "Global objects dump failed"
            cleanup_current_tmp
            return 1
        fi

    else

        local database_size_bytes
        local required_tmp_bytes

        if ! database_size_bytes=$(
            psql \
                -X \
                -A \
                -t \
                -q \
                -h "$PGHOST" \
                -p "$PGPORT" \
                -U "$PGUSER" \
                -d "$database" \
                -c "SELECT pg_database_size(current_database());"
        ); then
            error "Failed to determine database size: $database"
            cleanup_current_tmp
            return 1
        fi

        required_tmp_bytes=$(awk \
            -v size="$database_size_bytes" \
            -v factor="$SPACE_SAFETY_FACTOR" \
            'BEGIN { printf "%.0f", size * (1 + factor) }'
        )

        if ! check_disk_space "$TMP_DIR" "$required_tmp_bytes"; then
            error "Not enough temporary disk space for database dump: $database"
            cleanup_current_tmp
            return 1
        fi

        if ! pg_dump \
            -Fc \
            --no-owner \
            --no-privileges \
            -h "$PGHOST" \
            -p "$PGPORT" \
            -U "$PGUSER" \
            -d "$database" \
            -f "$dump_file"
        then
            error "Dump failed: $database"
            cleanup_current_tmp
            return 1
        fi

    fi

    if [[ ! -s "$dump_file" ]]; then
        error "Dump is empty: $backup_name"
        cleanup_current_tmp
        return 1
    fi

    success "Dump created: $backup_name"

    # --------------------------------------------------------
    # Сжатие
    # --------------------------------------------------------

    if ! gzip -c "$dump_file" > "$archive_file"; then
        error "Compression failed: $backup_name"
        cleanup_current_tmp
        return 1
    fi

    if [[ ! -s "$archive_file" ]]; then
        error "Archive is empty: $backup_name"
        cleanup_current_tmp
        return 1
    fi

    success "Archive created: $backup_name"

    # --------------------------------------------------------
    # Проверка целостности архива
    # --------------------------------------------------------

    if ! gzip -t "$archive_file" 2>/dev/null; then
        error "Archive integrity check failed: $backup_name"
        cleanup_current_tmp
        return 1
    fi

    success "Archive integrity verified: $backup_name"

    # --------------------------------------------------------
    # Подготовка конечного имени файла
    # --------------------------------------------------------

    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    local final_file

    if [[ "$is_globals" == "true" ]]; then
        final_file="${BACKUP_DIR}/globals_${timestamp}.sql.gz"
    else
        final_file="${BACKUP_DIR}/${database}_${timestamp}.dump.gz"
    fi

    # --------------------------------------------------------
    # Копирование проверенного архива в /backups
    # --------------------------------------------------------

    local temp_final_file
    temp_final_file="${final_file}.tmp"

    local archive_size_bytes
    local required_backup_bytes

    archive_size_bytes=$(stat -c '%s' "$archive_file")

    required_backup_bytes=$(awk \
        -v size="$archive_size_bytes" \
        -v factor="$SPACE_SAFETY_FACTOR" \
        'BEGIN { printf "%.0f", size * (1 + factor) }'
    )

    if ! check_disk_space "$BACKUP_DIR" "$required_backup_bytes"; then
        error "Not enough backup disk space: $backup_name"
        cleanup_current_tmp
        return 1
    fi

    if ! cp -- "$archive_file" "$temp_final_file"; then
        error "Failed to copy backup to $BACKUP_DIR: $backup_name"
        rm -f -- "$temp_final_file"
        cleanup_current_tmp
        return 1
    fi

    success "Backup copied: $backup_name"

    # --------------------------------------------------------
    # Проверка после копирования
    # --------------------------------------------------------

    if ! gzip -t "$temp_final_file" 2>/dev/null; then
        error "Backup verification failed after copy: $backup_name"
        rm -f -- "$temp_final_file"
        cleanup_current_tmp
        return 1
    fi

    if ! mv -- "$temp_final_file" "$final_file"; then
        error "Failed to finalize backup: $backup_name"
        rm -f -- "$temp_final_file"
        cleanup_current_tmp
        return 1
    fi

    success "Backup verification completed: $backup_name"

    # --------------------------------------------------------
    # Очистка временных файлов
    # --------------------------------------------------------

    if ! cleanup_current_tmp; then
        return 1
    fi

    success "Backup completed: $backup_name"

    return 0
}

# ------------------------------------------------------------
# Удаление старых резервных копий
# ------------------------------------------------------------

cleanup_old_backups() {

    local database="$1"
    local is_globals="$2"
    local pattern

    if [[ ! "$is_globals" =~ ^(true|false)$ ]]; then
        error "Invalid global objects flag: $is_globals"
        return 1
    fi

    if [[ "$is_globals" == "true" ]]; then
        pattern="globals_*.sql.gz"
    else
        pattern="${database}_*.dump.gz"
    fi

    if ! find "$BACKUP_DIR" \
        -type f \
        -name "$pattern" \
        -mtime +"$BACKUP_RETENTION_DAYS" \
        -delete
    then

        error "Failed to remove old backups: $database"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Основная функция
# ------------------------------------------------------------

main() {

    info "PostgreSQL backup started on $HOSTNAME"

    # --------------------------------------------------------
    # Первоначальные проверки
    # --------------------------------------------------------

    if ! check_postgres_credentials; then
        return 1
    fi

    if ! select_admin_database; then
        return 1
    fi

    local databases
    if ! databases=$(get_databases); then
        return 1
    fi

    local total=0
    local successful=0
    local failed=0

    # --------------------------------------------------------
    # Резервное копирование глобальных объектов
    # --------------------------------------------------------

    total=$((total + 1))

    if backup_database "GLOBALS" "true"; then
        successful=$((successful + 1))

        if ! cleanup_old_backups "GLOBALS" "true"; then
            warn "Retention cleanup failed: global objects"
        fi

    else
        failed=$((failed + 1))
        error "Backup failed: global objects"
    fi

    # --------------------------------------------------------
    # Резервное копирование баз данных
    # --------------------------------------------------------

    while IFS= read -r database; do

        [[ -z "$database" ]] && continue

        total=$((total + 1))

        if backup_database "$database" "false"; then
            successful=$((successful + 1))

            if ! cleanup_old_backups "$database" "false"; then
                warn "Retention cleanup failed: $database"
            fi

        else
            failed=$((failed + 1))
            error "Backup failed: $database"
        fi

    done <<< "$databases"

    # --------------------------------------------------------
    # Итоговый результат
    # --------------------------------------------------------

    info "Backup finished: total=$total successful=$successful failed=$failed"

    if (( failed > 0 )); then
        error "Backup completed with errors"
        return 1
    fi

    success "All database backups completed successfully"

    return 0
}

if ! main "$@"; then
    exit 1
fi