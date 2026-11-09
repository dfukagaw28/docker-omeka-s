#!/bin/sh
# Install (or update) Omeka S as systemd services with Podman Quadlet.
#
#   deploy/install-quadlet.sh            # rootless: ~/.config/containers/systemd
#   sudo deploy/install-quadlet.sh --system   # rootful: /etc/containers/systemd
#   deploy/install-quadlet.sh --dry-run DIR   # only render units into DIR
#
# Reads settings from .env in the repository root, builds the Omeka image,
# renders deploy/quadlet/*.in into unit files and (re)starts the services.
# Run it again after editing .env or updating versions.
#
# For rootless services that start at boot without a login session:
#   sudo loginctl enable-linger "$USER"
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="$REPO_DIR/deploy/quadlet"

DRY_RUN=false
case "${1:-}" in
    --system)
        [ "$(id -u)" = 0 ] || { echo "--system requires root" >&2; exit 1; }
        UNIT_DIR=/etc/containers/systemd
        SYSTEMCTL="systemctl" ;;
    --dry-run)
        [ -n "${2:-}" ] || { echo "--dry-run requires a directory" >&2; exit 1; }
        UNIT_DIR="$2"; DRY_RUN=true ;;
    '')
        UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
        SYSTEMCTL="systemctl --user" ;;
    *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac

die() { echo "install-quadlet: $*" >&2; exit 1; }

[ -f "$REPO_DIR/.env" ] || die "$REPO_DIR/.env not found (cp .env.sample .env)"

# Load .env without evaluating it as shell code (values may contain spaces).
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in *[!A-Za-z0-9_]*|'') die "invalid line in .env: $line" ;; esac
    export "$key=$value"
done < "$REPO_DIR/.env"

# Defaults (same as compose.yaml)
: "${COMPOSE_PROJECT_NAME:=omeka-s}"
: "${CONFIG_DIR:=./config/prod}"
: "${TZ:=Asia/Tokyo}"
: "${OMEKA_VERSION:=4.2.1}" "${PHP_VERSION:=8.5}" "${MARIADB_VERSION:=11.8}" "${IIPSRV_VERSION:=1.3}"
: "${OMEKA_PORT:=8001}" "${IIPSRV_PORT:=8002}"
: "${DB_NAME:=omeka}" "${DB_USER:=omeka}"
: "${IIIF_IMAGE_DIR:=./data/ptif}" "${IIPSRV_BASE_URL:=}" "${IIPSRV_CACHE_MB:=10}"
: "${ENABLE_IIPSRV:=false}" "${OMEKA_PUBLIC_HOSTS:=}"
[ -n "${DB_PASSWORD:-}" ] || die "DB_PASSWORD is not set in .env"

# Values end up in systemd unit files, where % and $ have special meaning.
for var in DB_NAME DB_USER DB_PASSWORD; do
    eval "val=\$$var"
    case "$val" in *[!A-Za-z0-9._@+-]*) die "$var may only contain A-Z a-z 0-9 . _ @ + -" ;; esac
done

# Relative paths in .env are relative to the repository.
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$REPO_DIR/${1#./}" ;; esac; }
CONFIG_DIR="$(abspath "$CONFIG_DIR")"
IIIF_IMAGE_DIR="$(abspath "$IIIF_IMAGE_DIR")"
[ -f "$CONFIG_DIR/mariadb.cnf" ] || die "$CONFIG_DIR/mariadb.cnf not found"
PREFIX="$COMPOSE_PROJECT_NAME"
# Names of this server that Omeka fetches (e.g. the host of IIPSRV_BASE_URL): a
# rootless container cannot connect to the host's own public address, so point
# them at the host (host-gateway) inside the Omeka container.
OMEKA_ADD_HOSTS=
for name in $(echo "$OMEKA_PUBLIC_HOSTS" | tr ',' ' '); do
    case "$name" in *[!A-Za-z0-9.-]*|.*|-*) die "invalid name in OMEKA_PUBLIC_HOSTS: $name" ;; esac
    OMEKA_ADD_HOSTS="${OMEKA_ADD_HOSTS}AddHost=$name:host-gateway
"
done
export REPO_DIR CONFIG_DIR IIIF_IMAGE_DIR PREFIX TZ OMEKA_VERSION PHP_VERSION MARIADB_VERSION \
    IIPSRV_VERSION OMEKA_PORT IIPSRV_PORT DB_NAME DB_USER IIPSRV_BASE_URL IIPSRV_CACHE_MB OMEKA_ADD_HOSTS

if [ "$DRY_RUN" = false ]; then
    echo "==> Building localhost/omeka-s:$OMEKA_VERSION-php$PHP_VERSION (PHP $PHP_VERSION)"
    podman build \
        --build-arg "PHP_VERSION=$PHP_VERSION" \
        --build-arg "OMEKA_VERSION=$OMEKA_VERSION" \
        -t "localhost/omeka-s:$OMEKA_VERSION-php$PHP_VERSION" "$REPO_DIR/omeka"
fi

echo "==> Writing units to $UNIT_DIR"
mkdir -p "$UNIT_DIR"
VARS='$PREFIX $REPO_DIR $CONFIG_DIR $TZ $OMEKA_VERSION $PHP_VERSION $MARIADB_VERSION $IIPSRV_VERSION $OMEKA_PORT $IIPSRV_PORT $DB_NAME $DB_USER $DB_PASSWORD $IIIF_IMAGE_DIR $IIPSRV_BASE_URL $IIPSRV_CACHE_MB $OMEKA_ADD_HOSTS'
services="omeka-db.service omeka.service"
for template in "$TEMPLATE_DIR"/*.in; do
    unit="$(basename "$template" .in)"
    if [ "$unit" = omeka-iipsrv.container ]; then
        if [ "$ENABLE_IIPSRV" != true ]; then
            rm -f "$UNIT_DIR/$unit"
            continue
        fi
        if [ "$DRY_RUN" = false ] && [ ! -d "$IIIF_IMAGE_DIR" ]; then
            mkdir -p "$IIIF_IMAGE_DIR" 2>/dev/null || die "IIIF_IMAGE_DIR $IIIF_IMAGE_DIR does not exist and cannot be created by $(id -un); create it, or check that every parent folder is accessible (namei -l $IIIF_IMAGE_DIR)"
        fi
        # The container reads the images as www-data, i.e. as "other" users
        if [ "$DRY_RUN" = false ] && ! ls "$IIIF_IMAGE_DIR" >/dev/null 2>&1; then
            die "cannot read IIIF_IMAGE_DIR $IIIF_IMAGE_DIR as $(id -un) (check: namei -l $IIIF_IMAGE_DIR)"
        fi
        services="$services omeka-iipsrv.service"
    fi
    (umask 077; envsubst "$VARS" < "$template" > "$UNIT_DIR/$unit")
    echo "    $unit"
done

if [ "$DRY_RUN" = true ]; then
    echo "==> Dry run: units written to $UNIT_DIR (nothing built or started)"
    exit 0
fi

echo "==> Starting: $services"
$SYSTEMCTL daemon-reload
# Quadlet units cannot be "enabled"; [Install] WantedBy= starts them at boot.
$SYSTEMCTL restart $services
$SYSTEMCTL --no-pager status $services | grep -E '^\S|Active:' || true

cat <<EOF

Done. Follow the logs with:
  journalctl ${SYSTEMCTL#systemctl} -u omeka.service -f
EOF
