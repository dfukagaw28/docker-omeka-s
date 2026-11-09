#!/bin/sh
# Entrypoint for the Omeka S container.
#  1. Writes config/database.ini from environment variables.
#  2. On first start, installs Omeka S and activates bundled modules.
#     On later starts, runs pending core migrations and module upgrades.
#  3. Hands off to the stock php-apache entrypoint.
set -eu

OMEKA_DIR=/var/www/html
SETUP="php /usr/local/share/omeka/init/omeka-setup.php"

# Read a variable from VAR or from the file named by VAR_FILE.
file_env() {
    var="$1"; default="${2:-}"
    eval "val=\${$var:-}"
    eval "file=\${${var}_FILE:-}"
    if [ -n "$file" ]; then
        val="$(cat "$file")"
    fi
    [ -n "$val" ] || val="$default"
    export "$var=$val"
}

file_env DB_HOST db
file_env DB_PORT 3306
file_env DB_NAME omeka
file_env DB_USER omeka
file_env DB_PASSWORD
file_env OMEKA_ADMIN_PASSWORD

if [ -z "$DB_PASSWORD" ]; then
    echo "omeka-entrypoint: DB_PASSWORD (or DB_PASSWORD_FILE) is required" >&2
    exit 1
fi
case "$DB_PASSWORD" in
    *\"*) echo "omeka-entrypoint: DB_PASSWORD must not contain double quotes" >&2; exit 1 ;;
esac

cat > "$OMEKA_DIR/config/database.ini" <<EOF
user     = "$DB_USER"
password = "$DB_PASSWORD"
dbname   = "$DB_NAME"
host     = "$DB_HOST"
port     = "$DB_PORT"
EOF
chown www-data:www-data "$OMEKA_DIR/config/database.ini"
chmod 600 "$OMEKA_DIR/config/database.ini"

# Serve Omeka under a sub-path as well (e.g. /omeka), for a proxy that keeps
# the prefix. Omeka's .htaccess handles Apache aliases, and builds its URLs
# (including IIIF manifests) from the request path.
BASE_PATH="${OMEKA_BASE_PATH:-}"
BASE_PATH="${BASE_PATH%/}"
BASE_CONF=/etc/apache2/conf-enabled/omeka-base-path.conf
if [ -n "$BASE_PATH" ]; then
    case "$BASE_PATH" in
        /*/*|*[!A-Za-z0-9/._-]*|/.|/..|[!/]*)
            echo "omeka-entrypoint: OMEKA_BASE_PATH must be one path segment like /omeka (got '$OMEKA_BASE_PATH')" >&2
            exit 1 ;;
    esac
    if [ -e "$OMEKA_DIR$BASE_PATH" ]; then
        echo "omeka-entrypoint: OMEKA_BASE_PATH $BASE_PATH is a folder of Omeka; choose another name" >&2
        exit 1
    fi
    echo "Alias $BASE_PATH $OMEKA_DIR" > "$BASE_CONF"
else
    rm -f "$BASE_CONF"
fi

# A freshly created volume (or a bind mount) may not be owned by www-data.
if [ "$(stat -c %U "$OMEKA_DIR/files")" != "www-data" ]; then
    chown www-data:www-data "$OMEKA_DIR/files"
fi

if [ "${1:-}" = "apache2-foreground" ] && [ "${OMEKA_AUTO_SETUP:-true}" = "true" ]; then
    # Each step runs in its own PHP process, because Omeka decides whether it
    # is installed (and which modules exist) once, at bootstrap.
    runuser -u www-data -- $SETUP wait-db
    runuser -u www-data -- $SETUP install
    runuser -u www-data -- $SETUP migrate
    runuser -u www-data -- $SETUP modules
fi

exec docker-php-entrypoint "$@"
