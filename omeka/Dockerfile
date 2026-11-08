# syntax=docker/dockerfile:1
ARG PHP_VERSION=8.5
FROM docker.io/library/php:${PHP_VERSION}-apache

ARG OMEKA_VERSION=4.2.1

LABEL org.opencontainers.image.source="https://github.com/dfukagaw28/docker-omeka-s"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# System packages and PHP extensions.
# - imagemagick: Omeka's thumbnailer (CLI "convert")
# - intl, zip: used by Daniel-KM modules
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        imagemagick \
        unzip \
        libicu-dev \
        libzip-dev \
    ; \
    exts="pdo_mysql intl zip"; \
    # OPcache is compiled in since PHP 8.5
    php -m | grep -q '^Zend OPcache$' || exts="$exts opcache"; \
    docker-php-ext-install -j"$(nproc)" $exts; \
    rm -rf /var/lib/apt/lists/*

RUN a2enmod rewrite remoteip headers

COPY fetch-release.sh /usr/local/bin/fetch-release

# Omeka S core
RUN set -eux; \
    fetch-release "https://github.com/omeka/omeka-s/releases/download/v${OMEKA_VERSION}/omeka-s-${OMEKA_VERSION}.zip" /tmp/omeka.zip; \
    unzip -q /tmp/omeka.zip -d /tmp; \
    rm -rf /var/www/html; \
    mv /tmp/omeka-s /var/www/html; \
    rm /tmp/omeka.zip

# Modules
COPY modules.txt /usr/local/share/omeka/modules.txt
RUN set -eux; \
    grep -Ev '^\s*(#|$)' /usr/local/share/omeka/modules.txt | while read -r name version url; do \
        name="${name#!}"; \
        url="${url:-https://github.com/Daniel-KM/Omeka-S-module-${name}/releases/download/${version}/${name}-${version}.zip}"; \
        fetch-release "$url" /tmp/module.zip; \
        unzip -q /tmp/module.zip -d /var/www/html/modules/; \
        rm /tmp/module.zip; \
        test -f "/var/www/html/modules/${name}/config/module.ini"; \
    done

COPY php.ini /usr/local/etc/php/conf.d/omeka.ini
COPY apache-omeka.conf /etc/apache2/conf-enabled/omeka.conf
COPY local.config.php /var/www/html/config/local.config.php
COPY init/ /usr/local/share/omeka/init/
COPY docker-entrypoint.sh /usr/local/bin/omeka-entrypoint

RUN set -eux; \
    chmod +x /usr/local/bin/omeka-entrypoint; \
    chown -R www-data:www-data /var/www/html/files /var/www/html/config /var/www/html/modules /var/www/html/themes /var/www/html/logs

VOLUME /var/www/html/files

ENTRYPOINT ["omeka-entrypoint"]
CMD ["apache2-foreground"]
