#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_FILE='/etc/backup-toolkit/job.conf'
CHECK_CONFIG=0
SOURCE_MOUNTED_BY_US=0
TARGET_MOUNTED_BY_US=0

usage() {
    cat <<'EOF'
Usage:
  backup-job.sh [--config FILE] [--check-config]

Modes are selected in the trusted job configuration:
  sync     mirror/copy a mounted SMB source with rsync
  archive  create a timestamped tar.gz archive with SHA-256 sidecar

The script must run as root for actual backup execution. --check-config performs
configuration validation only and does not mount shares or copy data.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

validate_trusted_file() {
    local file=$1 description=$2 owner mode

    [[ -f $file ]] || fatal "$description not found: $file"
    [[ ! -L $file ]] || fatal "$description must not be a symbolic link: $file"

    owner=$(stat -c '%u' -- "$file")
    [[ $owner == 0 ]] || fatal "$description must be owned by root: $file"

    mode=$(stat -c '%a' -- "$file")
    [[ $mode =~ ^[0-7]{3,4}$ ]] || fatal "Unable to validate permissions for $file"
    if (( (8#$mode & 022) != 0 )); then
        fatal "$description must not be writable by group/others: $file"
    fi
}

validate_credentials_file() {
    local file=$1 owner mode

    [[ -f $file ]] || fatal "CIFS credentials file not found: $file"
    [[ ! -L $file ]] || fatal "CIFS credentials file must not be a symbolic link: $file"

    owner=$(stat -c '%u' -- "$file")
    [[ $owner == 0 ]] || fatal "CIFS credentials file must be owned by root: $file"

    mode=$(stat -c '%a' -- "$file")
    [[ $mode =~ ^[0-7]{3,4}$ ]] || fatal "Unable to validate permissions for $file"
    if (( (8#$mode & 077) != 0 )); then
        fatal "CIFS credentials file must be mode 0600 (no group/other access): $file"
    fi
}

validate_relative_path() {
    local value=$1 label=$2
    [[ -n $value ]] || fatal "$label must not be empty."
    [[ $value != /* ]] || fatal "$label must be relative: $value"
    [[ $value != '..' && $value != ../* && $value != */../* && $value != */.. ]] \
        || fatal "$label must not contain '..': $value"
}

cleanup() {
    local rc=$?
    set +e

    if ((TARGET_MOUNTED_BY_US == 1)) && mountpoint -q -- "$TARGET_MOUNT"; then
        umount -- "$TARGET_MOUNT" || log "WARN: failed to unmount target: $TARGET_MOUNT"
    fi
    if ((SOURCE_MOUNTED_BY_US == 1)) && mountpoint -q -- "$SOURCE_MOUNT"; then
        umount -- "$SOURCE_MOUNT" || log "WARN: failed to unmount source: $SOURCE_MOUNT"
    fi

    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

while (($# > 0)); do
    case $1 in
        --config)
            (($# >= 2)) || fatal '--config requires a value.'
            CONFIG_FILE=$2
            shift 2
            ;;
        --check-config)
            CHECK_CONFIG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown argument: $1"
            ;;
    esac
done

JOB_NAME='smb-backup'
MODE='sync'
SOURCE_SHARE=''
SOURCE_MOUNT='/mnt/backup-source'
SOURCE_CREDENTIALS=''
TARGET_SHARE=''
TARGET_MOUNT='/mnt/backup-target'
TARGET_CREDENTIALS=''
TARGET_SUBDIR='backup'
CIFS_VERSION='3.1.1'
RSYNC_DELETE='false'
ARCHIVE_PREFIX='backup'
RETENTION_DAYS='30'
LOCK_FILE='/run/lock/backup-toolkit.lock'
INCLUDE_PATHS=( '.' )

validate_trusted_file "$CONFIG_FILE" 'Job configuration'
# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ $JOB_NAME =~ ^[A-Za-z0-9._-]+$ ]] || fatal 'JOB_NAME may contain only letters, numbers, dot, underscore and dash.'
[[ $MODE == 'sync' || $MODE == 'archive' ]] || fatal "MODE must be 'sync' or 'archive'."
[[ $SOURCE_SHARE == //*/* ]] || fatal 'SOURCE_SHARE must be a UNC path such as //server/share.'
[[ $TARGET_SHARE == //*/* ]] || fatal 'TARGET_SHARE must be a UNC path such as //server/share.'
[[ $SOURCE_MOUNT == /* && $TARGET_MOUNT == /* ]] || fatal 'Mount points must be absolute paths.'
[[ $SOURCE_MOUNT != "$TARGET_MOUNT" ]] || fatal 'Source and target mount points must differ.'
[[ -n $SOURCE_CREDENTIALS && -n $TARGET_CREDENTIALS ]] || fatal 'Both CIFS credentials file paths are required.'
[[ $CIFS_VERSION =~ ^[0-9]+\.[0-9]+([.][0-9]+)?$ ]] || fatal 'CIFS_VERSION has an invalid format.'
[[ $RSYNC_DELETE == 'true' || $RSYNC_DELETE == 'false' ]] || fatal "RSYNC_DELETE must be 'true' or 'false'."
[[ $ARCHIVE_PREFIX =~ ^[A-Za-z0-9._-]+$ ]] || fatal 'ARCHIVE_PREFIX contains unsupported characters.'
[[ $RETENTION_DAYS =~ ^[0-9]+$ ]] || fatal 'RETENTION_DAYS must be a non-negative integer.'
[[ $LOCK_FILE == /* ]] || fatal 'LOCK_FILE must be an absolute path.'
validate_relative_path "$TARGET_SUBDIR" 'TARGET_SUBDIR'

if ((${#INCLUDE_PATHS[@]} == 0)); then
    fatal 'INCLUDE_PATHS must contain at least one relative path.'
fi
for include_path in "${INCLUDE_PATHS[@]}"; do
    validate_relative_path "$include_path" 'INCLUDE_PATHS entry'
done

if ((CHECK_CONFIG == 1)); then
    printf 'Configuration OK: job=%s mode=%s source=%s target=%s/%s\n' \
        "$JOB_NAME" "$MODE" "$SOURCE_SHARE" "$TARGET_SHARE" "$TARGET_SUBDIR"
    exit 0
fi

((EUID == 0)) || fatal 'Backup execution must run as root.'

require_command flock
require_command mount
require_command mountpoint
require_command stat
require_command umount
require_command find
require_command sha256sum

validate_credentials_file "$SOURCE_CREDENTIALS"
validate_credentials_file "$TARGET_CREDENTIALS"

install -d -m 0750 -- "$(dirname -- "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || fatal "Another backup job is already running (lock: $LOCK_FILE)."

install -d -m 0750 -- "$SOURCE_MOUNT" "$TARGET_MOUNT"

if ! mountpoint -q -- "$SOURCE_MOUNT"; then
    log "Mounting source read-only: $SOURCE_SHARE"
    mount -t cifs "$SOURCE_SHARE" "$SOURCE_MOUNT" \
        -o "credentials=${SOURCE_CREDENTIALS},vers=${CIFS_VERSION},ro,iocharset=utf8,file_mode=0640,dir_mode=0750,nosuid,nodev,noexec"
    SOURCE_MOUNTED_BY_US=1
fi

if ! mountpoint -q -- "$TARGET_MOUNT"; then
    log "Mounting target read-write: $TARGET_SHARE"
    mount -t cifs "$TARGET_SHARE" "$TARGET_MOUNT" \
        -o "credentials=${TARGET_CREDENTIALS},vers=${CIFS_VERSION},rw,iocharset=utf8,file_mode=0640,dir_mode=0750,nosuid,nodev,noexec"
    TARGET_MOUNTED_BY_US=1
fi

mountpoint -q -- "$SOURCE_MOUNT" || fatal "Source is not mounted: $SOURCE_MOUNT"
mountpoint -q -- "$TARGET_MOUNT" || fatal "Target is not mounted: $TARGET_MOUNT"

TARGET_DIR="${TARGET_MOUNT%/}/${TARGET_SUBDIR}"
install -d -m 0750 -- "$TARGET_DIR"

run_sync() {
    local -a rsync_args
    require_command rsync

    rsync_args=(
        -rlt
        --human-readable
        --stats
        --partial
    )
    if [[ $RSYNC_DELETE == 'true' ]]; then
        rsync_args+=( --delete-delay )
    fi

    log "Starting rsync job: $SOURCE_MOUNT/ -> $TARGET_DIR/"
    rsync "${rsync_args[@]}" -- "$SOURCE_MOUNT/" "$TARGET_DIR/"
    log 'Rsync completed successfully.'
}

run_archive() {
    local timestamp archive_name temp_archive final_archive include_path
    local -a tar_paths=()

    require_command tar

    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    archive_name="${ARCHIVE_PREFIX}-${timestamp}.tar.gz"
    final_archive="${TARGET_DIR}/${archive_name}"
    temp_archive="${TARGET_DIR}/.${archive_name}.partial"

    for include_path in "${INCLUDE_PATHS[@]}"; do
        [[ -e "${SOURCE_MOUNT%/}/${include_path}" ]] \
            || fatal "Archive include path does not exist: $include_path"
        tar_paths+=( "$include_path" )
    done

    [[ ! -e $final_archive && ! -e $temp_archive ]] || fatal "Archive already exists: $final_archive"

    log "Creating archive: $final_archive"
    tar -C "$SOURCE_MOUNT" -czf "$temp_archive" -- "${tar_paths[@]}"
    tar -tzf "$temp_archive" >/dev/null
    mv -- "$temp_archive" "$final_archive"

    (
        cd "$TARGET_DIR"
        sha256sum -- "$archive_name" > "${archive_name}.sha256"
    )
    log "Archive created and verified: $final_archive"

    if ((RETENTION_DAYS > 0)); then
        log "Applying archive retention: ${RETENTION_DAYS} day(s)."
        find "$TARGET_DIR" -maxdepth 1 -type f \
            \( -name "${ARCHIVE_PREFIX}-*.tar.gz" -o -name "${ARCHIVE_PREFIX}-*.tar.gz.sha256" \) \
            -mtime "+${RETENTION_DAYS}" -delete
    fi
}

case $MODE in
    sync) run_sync ;;
    archive) run_archive ;;
esac

log "Backup job completed: $JOB_NAME"
