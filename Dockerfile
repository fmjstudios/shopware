#syntax=docker/dockerfile:1.4

ARG PHP_VERSION=8.2
FROM php:$PHP_VERSION-fpm-alpine as base

# container settings
ARG USER=shopware
ARG PUID=1101
ARG PGID=1101
ARG PORT=9161

# install `install-php-extensions` to install extensions (and composer) with all dependencies included
# install Shopware required PHP extensions and the latest version of Composer
# ref: https://github.com/mlocati/docker-php-extension-installer
# ref: https://developer.shopware.com/docs/guides/installation/requirements.html
RUN curl -sSLf \
        -o /usr/local/bin/install-php-extensions \
        https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions && \
    chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
        @composer \
        bcmath \
        gd \
        intl \
        mysqli \
        pdo_mysql \
        pcntl \
        sockets \
        bz2 \
        gmp \
        soap \
        zip \
        ffi \
        redis \
        opcache \
        apcu \
        amqp \
        sodium \
        opentelemetry \
        grpc

# install base dependencies
RUN apk add --no-cache \
    bash=~5.2 \
    nginx=~1.26 \
    supervisor=~4.2 \
    jq=~1.7 \
    trurl \
    envsubst \
    acl

# define core environment variables (php-cli, php-fpm, utils.sh)
ENV PORT=${PORT} \
    DATABASE_TIMEOUT=120 \
    PHP_ERROR_REPORTING="E_ALL & ~E_DEPRECATED & ~E_STRICT" \
    PHP_DISPLAY_ERRORS="Off" \
    PHP_MAX_UPLOAD_SIZE="32M" \
    PHP_MAX_EXECUTION_TIME=60 \
    PHP_MEMORY_LIMIT="512M" \
    PHP_SESSION_COOKIE_LIFETIME=0 \
    PHP_SESSION_GC_MAXLIFETIME=1440 \
    PHP_SESSION_HANDLER="files" \
    PHP_SESSION_SAVE_PATH="" \
    PHP_OPCACHE_ENABLE_CLI=0 \
    PHP_OPCACHE_FILE_OVERRIDE=1 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
    PHP_OPCACHE_INTERNED_STRINGS_BUFFER=20 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=10000 \
    PHP_OPCACHE_MEMORY_CONSUMPTION=128 \
    PHP_OPCACHE_FILE_CACHE="" \
    PHP_OPCACHE_FILE_CACHE_ONLY=0 \
    PHP_REALPATH_CACHE_TTL="4096k" \
    PHP_REALPATH_CACHE_SIZE=3600 \
    PHP_FPM_PM="dynamic" \
    PHP_FPM_LISTEN="${PORT}" \
    PHP_FPM_MAX_CHILDREN=15 \
    PHP_FPM_START_SERVERS=5 \
    PHP_FPM_MIN_SPARE_SERVERS=2 \
    PHP_FPM_MAX_SPARE_SERVERS=5 \
    PHP_FPM_MAX_SPAWN_RATE=2 \
    PHP_FPM_PROCESS_IDLE_TIMEOUT=10s \
    PHP_FPM_MAX_REQUESTS=0 \
    PHP_FPM_STATUS_PATH="/-/fpm/status" \
    PHP_FPM_PING_PATH="/-/fpm/ping" \
    PHP_FPM_ACCESS_LOG="/proc/self/fd/2" \
    PHP_FPM_ERROR_LOG="/proc/self/fd/2" \
    PHP_FPM_LOG_LEVEL="notice" \
    PHP_FPM_DAEMONIZE="no" \
    PHP_FPM_RLIMIT_FILES=8192 \
    PHP_FPM_LOG_LIMIT=8192

# PHP
RUN rm -rf /usr/local/etc/php/php.ini*
COPY --chmod=644 docker/conf/php/php.ini /usr/local/etc/php
COPY --chmod=644 docker/conf/php/docker-php.ini /usr/local/etc/php/conf.d

# PHP-FPM
RUN rm -rf /usr/local/etc/php-fpm.d/* && \
    rm -rf /usr/local/etc/php-fpm.conf*

COPY --chmod=644 docker/conf/php-fpm/php-fpm.conf /usr/local/etc
COPY --chmod=644 docker/conf/php-fpm/www.conf /usr/local/etc/php-fpm.d

# Supervisor
RUN mkdir -p /etc/supervisor /etc/supervisor/conf.d
COPY --chmod=644 docker/conf/supervisor/supervisord.conf /etc/supervisor

# create and own required directories
RUN <<EOF
mkdir -p /var/log/php-fpm /var/log/php /var/log/supervisor /var/www/html /run/php
chmod -R 755 /run/php
chown -R ${PUID}:${PGID} /var/log/php-fpm /var/log/php /var/log/supervisor /var/www/html /run/php
EOF

FROM base as system

ARG USER
ARG PORT
ARG PUID
ARG PGID

# create (unprivileged) shopware user
RUN \
	# Use "useradd ${USER}" for Debian-based distros
	adduser -D ${USER} -u ${PUID}; \
  addgroup -g ${PGID} -S; \
	# Give write access to /var/www/html
	chown -R ${USER}:${USER} /var/www/html

# add container executables and library scripts
COPY --chmod=755 docker/bin/swctl /usr/local/bin
COPY --chmod=644 docker/lib/utils.sh /usr/local/lib/utils.sh

# add a healthcheck
# ref: https://developer.shopware.com/docs/guides/hosting/installation-updates/cluster-setup.html#health-check
HEALTHCHECK --start-period=3m --timeout=5s --interval=10s --retries=75 \
   CMD curl --fail "http://localhost:${PORT:-9161}/api/_info/health-check" || exit 1

# prepare image for volumes - has to be done before we copy sources
VOLUME [ "/var/www/html/files", "/var/www/html/public/theme", "/var/www/html/public/media", "/var/www/html/public/thumbnail", "/var/www/html/public/public" ]

# create and own directories required by volumes
RUN <<EOF
mkdir -p /var/www/html/files /var/www/html/public/theme /var/www/html/public/media /var/www/html/public/thumbnail /var/www/html/public/public
chown -R ${USER}:${USER} /var/www/html/files /var/www/html/public/theme /var/www/html/public/media /var/www/html/public/thumbnail /var/www/html/public/public
EOF

# install shopware-cli
RUN apk add --no-cache bash && \
    curl -1sLf 'https://dl.cloudsmith.io/public/friendsofshopware/stable/setup.alpine.sh' | bash && \
    apk add --no-cache shopware-cli

# Define Shopware's default settings
ENV APP_ENV=dev \
    APP_SECRET="" \
    APP_URL="https://shopware.internal" \
    APP_URL_CHECK_DISABLED=1 \
    INSTANCE_ID="" \
    LOCK_DSN=flock \
    MAILER_DSN=null://localhost \
    DATABASE_URL=mysql://shopware:shopware@127.0.0.1:3306/shopware \
    BLUE_GREEN_DEPLOYMENT=0 \
    # HTTP caching settings (disabled by default)
    SHOPWARE_HTTP_CACHE_ENABLED=0 \
    SHOPWARE_HTTP_DEFAULT_TTL=7200 \
    SHOPWARE_CACHE_ID=docker \
    SHOPWARE_SKIP_WEBINSTALLER=1 \
    STOREFRONT_PROXY_URL=${APP_URL:-"https://shopware.internal"} \
    # disable ElasticSearch/OpenSearch by default
    SHOPWARE_ES_ENABLED=0 \
    OPENSEARCH_URL="http://opensearch:9200" \
    SHOPWARE_ES_INDEXING_ENABLED=0 \
    SHOPWARE_ES_INDEX_PREFIX="sw" \
    SHOPWARE_ES_THROW_EXCEPTION=1 \
    # force the use of the Composer-based plugin loader
    # ref: https://developer.shopware.com/docs/guides/hosting/installation-updates/deployments/build-w-o-db.html#compiling-the-administration-without-database
    COMPOSER_PLUGIN_LOADER=1 \
    COMPOSER_HOME="/tmp/composer" \
    # disable OpenTelemetry by default
    OTEL_PHP_AUTOLOAD_ENABLED=false \
    OTEL_PHP_DISABLED_INSTRUMENTATIONS=shopware \
    OTEL_SERVICE_NAME=shopware \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_EXPORTER_OTLP_ENDPOINT=https://otel-collector:4317 \
    # S3 configuration
    SHOPWARE_S3_BUCKET=shop-cdn-fmjstudios \
    SHOPWARE_S3_REGION=eu-north-1 \
    SHOPWARE_S3_ACCESS_KEY=CHANGEME \
    SHOPWARE_S3_SECRET_KEY=CHANGEME \
    SHOPWARE_S3_ENDPOINT="https://s3.eu-north-1.amazonaws.com" \
    SHOPWARE_S3_CDN_URL="https://shop.cdn.fmj.services" \
    # settings for installation via deployment-helper
    INSTALL_LOCALE=en-GB \
    INSTALL_CURRENCY=EUR \
    INSTALL_ADMIN_USERNAME=admin \
    INSTALL_ADMIN_PASSWORD=shopware


# switch to unprivileged user
USER ${USER}

# execute 'swctl' by default
ENTRYPOINT ["swctl"]

# -------------------------------------
# DEVELOPMENT Image
# -------------------------------------
FROM system as dev

# (re)-instantiate ARGs
ARG USER
ARG PUID
ARG PGID

# copy all (non-ignored) sources
WORKDIR /var/www/html
COPY --link --chown=${PUID}:${PGID} . ./
RUN rm -rf ./docker # remove non-ignorable docker dir

ENV APP_ENV=dev

RUN --mount=type=secret,id=composer_auth,dst=./auth.json \
    --mount=type=cache,target=/home/${USER}/.composer \
    --mount=type=cache,target=/home/${USER}/.npm \
    shopware-cli project ci --with-dev-dependencies .

# switch to unprivileged user
USER ${USER}
CMD ["run"]

# -------------------------------------
# PRODUCTION Image
# -------------------------------------
FROM system as prod

# (re)-instantiate ARGs
ARG USER
ARG PUID
ARG PGID
ARG PORT

# doc-root
WORKDIR /var/www/html
COPY --link --chown=${PUID}:${PGID} . ./

# overwrite defaults
ENV APP_ENV=prod \
    SHOPWARE_HTTP_CACHE_ENABLED=1 \
    APP_URL_CHECK_DISABLED=0

# production build
RUN \
    --mount=type=secret,id=composer_auth,dst=./auth.json \
    --mount=type=cache,target=/home/${USER}/.composer \
    --mount=type=cache,target=/home/${USER}/.npm \
    shopware-cli project ci .

# (re)-own files
USER root
RUN \
    #chown -R ${PUID}:${PGID} . && \
    find . -type f -exec chmod 644 {} + && \
    find . -type d -exec chmod 755 {} + && \
    setfacl -PRd -m user:${USER}:rwx,group:${USER}:rw,other::r ./files ./var ./public

# switch to unprivileged user
USER ${USER}
CMD ["run"]
EXPOSE ${PORT}
