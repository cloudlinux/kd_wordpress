# Version: 0.0.1
FROM debian:jessie

MAINTAINER Igor Savenko "bliss@cloudlinux.com"

ENV NGINX_VERSION 1.11.5-1~jessie

RUN apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 \
    && echo "deb http://nginx.org/packages/mainline/debian/ jessie nginx" >> /etc/apt/sources.list \
    && apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install \
    --no-install-recommends --no-install-suggests -y \
                                        ca-certificates \
                                        nginx=${NGINX_VERSION} \
                                        gettext-base \
                                        runit \
                                        curl \
                                        libedit2 \
                                        libsqlite3-0 \
                                        libxml2 \
                                        xz-utils \
                                        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i -e "s/keepalive_timeout\s*65/keepalive_timeout 15/" \
              -e "/keepalive_timeout/a \\\tclient_max_body_size 100m;" \
              -e '/^user/ {s/nginx/www-data/}' \
              -e "/worker_processes/a daemon off;" /etc/nginx/nginx.conf \
    && rm -f /etc/nginx/conf.d/default.conf

ENV PHPIZE_DEPS autoconf file g++ gcc libc-dev make pkg-config re2c
ENV PHP_INI_DIR /usr/local/etc/php
ENV GPG_KEYS 0BD78B5F97500D450838F95DFE857D9A90D90EC1 6E4F6AB321FDC07F2C332E3AC2BF0BC433CFC8B3
ENV PHP_VERSION 5.6.26
ENV PHP_FILENAME php-5.6.26.tar.xz
ENV PHP_SHA256 203a854f0f243cb2810d1c832bc871ff133eccdf1ff69d32846f93bc1bef58a8

RUN test -d $PHP_INI_DIR/conf.d || mkdir -p $PHP_INI_DIR/conf.d

RUN set -xe \
    && cd /usr/src \
    && curl -fSL "https://secure.php.net/get/$PHP_FILENAME/from/this/mirror" -o php.tar.xz \
    && echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c - \
    && curl -fSL "https://secure.php.net/get/$PHP_FILENAME.asc/from/this/mirror" -o php.tar.xz.asc \
    && export GNUPGHOME="$(mktemp -d)" \
    && for key in $GPG_KEYS; do \
        gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
    done \
    && gpg --batch --verify php.tar.xz.asc php.tar.xz \
    && rm -rf "$GNUPGHOME"

COPY docker-php-source /usr/local/bin/

RUN set -xe && buildDeps="libcurl4-openssl-dev libedit-dev libsqlite3-dev libssl-dev libxml2-dev" \
    && apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y $PHPIZE_DEPS $buildDeps --no-install-recommends && rm -rf /var/lib/apt/lists/* \
    && docker-php-source extract \
    && cd /usr/src/php \
    && ./configure \
        --with-config-file-path="$PHP_INI_DIR" \
        --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
        --disable-cgi \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-curl \
        --with-libedit \
        --with-openssl \
        --with-zlib \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
    && make -j"$(nproc)" && make install \
    && { find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; } \
    && make clean && docker-php-source delete \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $buildDeps

COPY docker-php-ext-* /usr/local/bin/

COPY runit/ /usr/src/runit

COPY service/ /etc/service

COPY conf/default.conf /etc/nginx/conf.d

RUN set -ex && cd /usr/local/etc \
    && mkdir pools.d \
    && echo 'include=etc/pools.d/*.conf' > php-fpm.conf \
    && { \
        echo '[global]'; \
        echo 'error_log = /proc/self/fd/2'; \
        echo 'daemonize = no'; \
        echo; \
        echo '[www]'; \
        echo 'access.log = /proc/self/fd/2'; \
        echo 'clear_env = no'; \
        echo 'catch_workers_output = yes'; \
        echo 'listen = /run/php/php-fpm.sock'; \
        echo 'user = www-data'; \
        echo 'group = www-data'; \
        echo 'listen.owner = www-data'; \
        echo 'listen.group = www-data'; \
        echo 'pm = ondemand'; \
        echo 'pm.max_children = 3'; \
        echo 'pm.process_idle_timeout = 10s'; \
    } > pools.d/www.conf \
    && cd /usr/src/runit && make -j"$(nproc)" && make install && make clean && rm -rf /usr/src/runit

ENV WORDPRESS_VERSION 4.6.1
ENV WORDPRESS_MAIL_VERSION 0.9.6
ENV WORDPRESS_SHA1 027e065d30a64720624a7404a1820e6c6fff1202

WORKDIR /var/www/html

RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y libpng12-dev libjpeg-dev \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr \
    && docker-php-ext-install gd mysqli opcache \
    && { \
        echo 'opcache.memory_consumption=64'; \
        echo 'opcache.interned_strings_buffer=4'; \
        echo 'opcache.max_accelerated_files=2000'; \
        echo 'opcache.revalidate_freq=2'; \
        echo 'opcache.fast_shutdown=1'; \
        echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini \
    && set -x \
    && curl -o wordpress.tar.gz -fSL "https://wordpress.org/wordpress-${WORDPRESS_VERSION}.tar.gz" \
    && echo "$WORDPRESS_SHA1 *wordpress.tar.gz" | sha1sum -c - \
    && tar -xzf wordpress.tar.gz -C /tmp/ \
    && rm wordpress.tar.gz \
    && cp -pr /tmp/wordpress/. /var/www/html/ \
    && rm -r /tmp/wordpress \
    && curl -fSL https://downloads.wordpress.org/plugin/wp-mail-smtp.${WORDPRESS_MAIL_VERSION}.zip -o /tmp/wp-mail-smtp.zip \
    && unzip /tmp/wp-mail-smtp.zip -d /var/www/html/wp-content/plugins/ \
    && rm /tmp/wp-mail-smtp.zip \
    && chown -R www-data:www-data /var/www/html/ \
    && mkdir /run/php && chown -R www-data:www-data /run/php \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

VOLUME /var/www/html

EXPOSE 80 443

CMD ["/sbin/runit-docker"]
