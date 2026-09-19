#!/command/with-contenv sh
# shellcheck shell=sh
# Runs once at container start, in s6-overlay's cont-init.d phase. The shebang
# has to use with-contenv, or the template's variables are invisible here and
# every default below silently wins over the user's settings.
#
# Fills in defaults so a container started with no settings comes up working
# (metadata in SQLite under /config, objects in /data, generated credentials),
# and creates the file system on first boot instead of a manual `juicefs
# format`. Re-formatting an existing volume loses data, so the check comes
# first and the format runs only when the metadata engine holds nothing.

log_info()  { printf '\033[0;32m[init] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[init] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[init] ERROR: %s\033[0m\n'  "$*" >&2; }

PUID="${PUID:-99}"
PGID="${PGID:-100}"

# Where the metadata lives. SQLite by default, because it needs no second
# container and the file sits on the array where a backup will pick it up.
# Anyone who wants Redis or Postgres puts their URL in this one field:
#   redis://:password@192.168.20.10:6379/1
#   postgres://user:password@192.168.20.10:5432/juicefs?sslmode=disable
META_URL="${META_URL:-sqlite3:///config/juicefs.db}"

# Where the file contents live. 'file' means a plain directory, which for a
# single Unraid box is the sane default; the same field takes s3, minio, b2 and
# the rest of the backends JuiceFS supports.
STORAGE="${STORAGE:-file}"
BUCKET="${BUCKET:-/data/}"
VOLUME_NAME="${VOLUME_NAME:-juicefs}"

mkdir -p /data /config

# The credentials an S3 client uses to talk to this container. Those of a
# remote object store are ACCESS_KEY and SECRET_KEY below.
S3_ROOT_USER="${S3_ROOT_USER:-juicefs}"

# The gateway refuses anything shorter and exits, so catching it here turns a
# container that restarts forever into one clear line in the log.
MIN_LEN=8

if [ -n "${S3_ROOT_PASSWORD}" ]; then
    if [ "${#S3_ROOT_PASSWORD}" -lt "${MIN_LEN}" ]; then
        log_error "The secret key is ${#S3_ROOT_PASSWORD} characters long."
        log_error "JuiceFS requires at least ${MIN_LEN} and refuses to start otherwise."
        log_error "Set a longer value in the template field, then start the container again."
        exit 1
    fi
else
    # -s, not -f: an empty file (a power cut between creating and writing it, a
    # full disk, a restored zero-byte backup) would otherwise pass as an empty
    # password and leave the gateway restarting forever.
    if [ -s /config/.s3_root_password ]; then
        S3_ROOT_PASSWORD="$(cat /config/.s3_root_password)"
        if [ "${#S3_ROOT_PASSWORD}" -lt "${MIN_LEN}" ]; then
            log_warn "The stored secret key is too short to be usable. Generating a new one."
            S3_ROOT_PASSWORD=""
        else
            log_info "Using the generated S3 secret key from /config/.s3_root_password"
        fi
    fi
    if [ -z "${S3_ROOT_PASSWORD}" ]; then
        S3_ROOT_PASSWORD="$(openssl rand -hex 16)"
        printf '%s' "${S3_ROOT_PASSWORD}" > /config/.s3_root_password
        chmod 600 /config/.s3_root_password
        log_warn "No S3_ROOT_PASSWORD was set. Generated one and stored it in"
        log_warn "/config/.s3_root_password. Read it from there, or set the"
        log_warn "field in the template to a value you choose."
        GENERATED=1
    fi
fi

# The ready banner points at the file only when its key is the one in use, not
# at a stale value after someone set their own.
[ -n "${GENERATED:-}" ] && : > /run/key_generated

# Persist for the service script, which runs in its own shell.
printf '%s' "${S3_ROOT_USER}"     > /run/s3_root_user
printf '%s' "${S3_ROOT_PASSWORD}" > /run/s3_root_password
printf '%s' "${META_URL}"         > /run/meta_url

# `juicefs status` succeeds exactly when the metadata engine already holds a
# formatted volume, which keeps this safe to run on every start.
if juicefs status "${META_URL}" >/dev/null 2>&1; then
    log_info "Existing file system found, leaving it untouched"
else
    log_info "No file system in the metadata engine yet, creating '${VOLUME_NAME}'"
    log_info "  metadata: ${META_URL%%://*}://…"
    log_info "  storage:  ${STORAGE} at ${BUCKET}"

    set -- format --storage "${STORAGE}" --bucket "${BUCKET}"
    [ -n "${ACCESS_KEY}" ] && set -- "$@" --access-key "${ACCESS_KEY}"
    [ -n "${SECRET_KEY}" ] && set -- "$@" --secret-key "${SECRET_KEY}"
    [ -n "${TRASH_DAYS}" ] && set -- "$@" --trash-days "${TRASH_DAYS}"

    if juicefs "$@" "${META_URL}" "${VOLUME_NAME}"; then
        log_info "File system '${VOLUME_NAME}' created"
    else
        log_error "Could not create the file system. The gateway will not start."
        log_error "Check META_URL, STORAGE and BUCKET against the log above."
        exit 1
    fi
fi

chown -R "${PUID}:${PGID}" /data /config 2>/dev/null || log_warn "chown failed, check PUID/PGID"

log_info "Init complete"
