#!/command/with-contenv sh
# shellcheck shell=sh
# =============================================================================
# 10-config.sh — container initialization
# Runs once at container start (s6-overlay cont-init.d phase, stage 2).
#
# The shebang MUST use 'with-contenv', otherwise the variables the Unraid
# template sets are not visible here and every default below would silently
# win over the user's settings.
#
# What this does:
#   1. Fill in defaults so a container started with no settings at all still
#      comes up working: metadata in a SQLite file under /config, objects in
#      /data, credentials generated and written down.
#   2. Create the file system on first boot. Upstream expects this as a manual
#      `juicefs format` in a console; doing it here is the main reason this
#      image exists.
#   3. Leave an existing file system completely alone. Re-formatting an
#      existing volume is how you lose data, so the check comes first and the
#      format only runs when the metadata engine holds nothing.
# =============================================================================

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

# --- credentials for the S3 gateway -----------------------------------------
# These are what an S3 client uses to talk to this container. They are NOT the
# credentials of a remote object store; those are ACCESS_KEY / SECRET_KEY below.
S3_ROOT_USER="${S3_ROOT_USER:-juicefs}"

# The gateway refuses anything shorter and exits, so catching it here turns a
# container that restarts forever into one clear line in the log.
MINDEST=8

if [ -n "${S3_ROOT_PASSWORD}" ]; then
    if [ "${#S3_ROOT_PASSWORD}" -lt "${MINDEST}" ]; then
        log_error "The secret key is ${#S3_ROOT_PASSWORD} characters long."
        log_error "JuiceFS requires at least ${MINDEST} and refuses to start otherwise."
        log_error "Set a longer value in the template field, then start the container again."
        exit 1
    fi
else
    # -s, not -f: a file that exists but is empty (a power cut between creating
    # and writing it, a full disk, a backup that restored a zero-byte file)
    # would otherwise be read as an empty password, reported as a success, and
    # leave the gateway restarting forever.
    if [ -s /config/.s3_root_password ]; then
        S3_ROOT_PASSWORD="$(cat /config/.s3_root_password)"
        if [ "${#S3_ROOT_PASSWORD}" -lt "${MINDEST}" ]; then
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
        ERZEUGT=ja
    fi
fi

# The ready banner should only point at the file when the key in it is the one
# actually in use. Otherwise it sends someone who set their own key off to read
# a stale value.
[ -n "${ERZEUGT:-}" ] && : > /run/key_generated

# Persist for the service script, which runs in its own shell.
printf '%s' "${S3_ROOT_USER}"     > /run/s3_root_user
printf '%s' "${S3_ROOT_PASSWORD}" > /run/s3_root_password
printf '%s' "${META_URL}"         > /run/meta_url

# --- create the file system, but only if there is none ----------------------
# `juicefs status` succeeds exactly when the metadata engine already holds a
# formatted volume. Asking first is what keeps this safe to run on every start.
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
