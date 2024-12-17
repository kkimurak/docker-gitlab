ARG VERSION=17.6.0
ARG GOLANG_VERSION=1.23.3

FROM golang:${GOLANG_VERSION} AS builder_gitlab_shell
COPY env.sh /tmp/env.sh
RUN <<EOR
    chmod +x /tmp/env.sh && . /tmp/env.sh
    # install gitlab-shell
    echo "Downloading gitlab-shell v.${GITLAB_SHELL_VERSION}..."
    GITLAB_SHELL_BUILD_DIR=/tmp/gitlab-shell
    git clone -q -b v${GITLAB_SHELL_VERSION} --depth 1 ${GITLAB_SHELL_URL} ${GITLAB_SHELL_BUILD_DIR}

    cd ${GITLAB_SHELL_BUILD_DIR}
    cp -a config.yml.example config.yml

    echo "Compiling gitlab-shell golang executables..."
    PATH="$PATH" make verify setup

    # remove unused repositories directory created by gitlab-shell install
    rm -rf ${GITLAB_HOME}/repositories
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitaly
COPY env.sh /tmp/env.sh
RUN <<EOR
    chmod +x /tmp/env.sh && . /tmp/env.sh
    GITLAB_GITALY_BUILD_DIR=/tmp/gitaly
    # download and build gitaly
    echo "Downloading gitaly v.${GITALY_SERVER_VERSION}..."
    git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}

    # add repository to support libssl 1.x
    # echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list.d/bullseye.list

    # install dependency
    GITALY_BUILD_DEPENDENCIES="cmake libssl-dev pkg-config"
    GITALY_GIT_BUILD_DEPENDENCIES="dh-autoreconf libcurl4-gnutls-dev libexpat1-dev gettext libz-dev libssl-dev asciidoc libffi-dev xmlto docbook2x install-info libpcre2-dev"

    apt-get update
    # fixme : libssl-dev is libssl 3.x on latest debian (bookworm)
    # and may not compatible with 1.x (used in gitlab image)
    apt-get install -y --no-install-recommends ${GITALY_BUILD_DEPENDENCIES} ${GITALY_GIT_BUILD_DEPENDENCIES}
        
    # install gitaly
    make -C ${GITLAB_GITALY_BUILD_DIR} install
    mkdir -p ${GITLAB_GITALY_INSTALL_DIR}
    cp -a ${GITLAB_GITALY_BUILD_DIR}/config.toml.example ${GITLAB_GITALY_INSTALL_DIR}/config.toml
    rm -rf ${GITLAB_GITALY_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache

    # install git bundled with gitaly.
    make -C ${GITLAB_GITALY_BUILD_DIR} git GIT_PREFIX=/usr/local
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitlab_pages
COPY env.sh /tmp/env.sh
RUN <<EOR
    chmod +x /tmp/env.sh && . /tmp/env.sh
    printenv
    # download gitlab-pages
    GITLAB_PAGES_BUILD_DIR=/tmp/gitlab-pages
    echo "Downloading gitlab-pages v.${GITLAB_PAGES_VERSION}..."
    git clone -q -b v${GITLAB_PAGES_VERSION} --depth 1 ${GITLAB_PAGES_URL} ${GITLAB_PAGES_BUILD_DIR}
    make -C ${GITLAB_PAGES_BUILD_DIR}
EOR

FROM ubuntu:focal-20241011 AS main_base
ARG VERSION
ENV VERSION=${VERSION} \
    GITLAB_USER="git" \
    GITLAB_HOME="/home/git" \
    GITLAB_LOG_DIR="/var/log/gitlab" \
    GITLAB_CACHE_DIR="/etc/docker-gitlab" \
    RAILS_ENV=production \
    NODE_ENV=production

ENV GITLAB_BUILD_DIR="${GITLAB_CACHE_DIR}/build" \
    GITLAB_DATA_DIR="${GITLAB_HOME}/data" \
    GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab" \
    GITLAB_RUNTIME_DIR="${GITLAB_CACHE_DIR}/runtime" \
    GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell"

COPY env.sh /tmp/env.sh
COPY assets/build/ ${GITLAB_BUILD_DIR}/
COPY assets/runtime/ ${GITLAB_RUNTIME_DIR}/

RUN <<EOR
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        sudo git wget ca-certificates apt-transport-https gnupg2
    apt-get upgrade -y
    rm -rf /var/lib/apt/lists/*
EOR

RUN <<EOR
    export VERSION=${VERSION}
    chmod +x /tmp/env.sh && . /tmp/env.sh

    # add ${GITLAB_USER} user
    adduser --disabled-login --gecos 'GitLab' ${GITLAB_USER}
    passwd -d ${GITLAB_USER}

    exec_as_git() {
        if [ $(whoami) = "${GITLAB_USER}" ]; then
            "$@"
        else
            sudo -HEu ${GITLAB_USER} "$@"
        fi
    }

    # configure git for ${GITLAB_USER}
    exec_as_git git config --global core.autocrlf input
    exec_as_git git config --global gc.auto 0
    exec_as_git git config --global repack.writeBitmaps true
    exec_as_git git config --global receive.advertisePushOptions true
    exec_as_git git config --global advice.detachedHead false
    exec_as_git git config --global --add safe.directory /home/git/gitlab

    # shallow clone gitlab-foss
    echo "Cloning gitlab-foss v.${GITLAB_VERSION}..."
    exec_as_git git clone -q -b v${GITLAB_VERSION} --depth 1 ${GITLAB_CLONE_URL} ${GITLAB_INSTALL_DIR}
    
    find "${GITLAB_BUILD_DIR}/patches/gitlabhq" -name "*.patch" | while read -r patch_file; do
      printf "Applying patch %s for gitlab-foss...\n" "${patch_file}"
      exec_as_git git -C ${GITLAB_INSTALL_DIR} apply --ignore-whitespace < "${patch_file}"
    done

    # remove HSTS config from the default headers, we configure it in nginx
    exec_as_git sed -i "/headers\['Strict-Transport-Security'\]/d" ${GITLAB_INSTALL_DIR}/app/controllers/application_controller.rb
    
    # revert `rake gitlab:setup` changes from gitlabhq/gitlabhq@a54af831bae023770bf9b2633cc45ec0d5f5a66a
    exec_as_git sed -i 's/db:reset/db:setup/' ${GITLAB_INSTALL_DIR}/lib/tasks/gitlab/setup.rake
    
    # change SSH_ALGORITHM_PATH - we have moved host keys in ${GITLAB_DATA_DIR}/ssh/ to persist them
    exec_as_git sed -i "s:/etc/ssh/:/${GITLAB_DATA_DIR}/ssh/:g" ${GITLAB_INSTALL_DIR}/app/models/instance_configuration.rb
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitlab_workhorse
COPY --from=main_base /home/git/gitlab/workhorse /tmp/workhorse
RUN <<EOR
    # build gitlab-workhorse
    echo "Build gitlab-workhorse"
    git config --global --add safe.directory /tmp/workhorse
    make -C /tmp/workhorse install
EOR

FROM main_base AS main

RUN set -ex && \
    mkdir -p /etc/apt/keyrings \
 && wget --quiet -O - https://keyserver.ubuntu.com/pks/lookup?op=get\&search=0xe1dd270288b4e6030699e45fa1715d88e1df1f24 | gpg --dearmor -o /etc/apt/keyrings/git-core.gpg\
 && echo "deb [signed-by=/etc/apt/keyrings/git-core.gpg] http://ppa.launchpad.net/git-core/ppa/ubuntu focal main" >> /etc/apt/sources.list \
 && wget --quiet -O - https://keyserver.ubuntu.com/pks/lookup?op=get\&search=0x8b3981e7a6852f782cc4951600a6f0a3c300ee8c | gpg --dearmor -o /etc/apt/keyrings/nginx-stable.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nginx-stable.gpg] http://ppa.launchpad.net/nginx/stable/ubuntu focal main" >> /etc/apt/sources.list \
 && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/postgres.gpg \
 && echo 'deb [signed-by=/etc/apt/keyrings/postgres.gpg] http://apt.postgresql.org/pub/repos/apt/ focal-pgdg main' > /etc/apt/sources.list.d/pgdg.list \
 && wget --quiet -O - https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main' > /etc/apt/sources.list.d/nodesource.list \
 && wget --quiet -O - https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor -o /etc/apt/keyrings/yarn.gpg \
 && echo 'deb [signed-by=/etc/apt/keyrings/yarn.gpg] https://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list \
 && set -ex \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
      supervisor logrotate locales curl \
      nginx openssh-server postgresql-contrib redis-tools \
      postgresql-client-13 postgresql-client-14 postgresql-client-15 postgresql-client-16 \
      python3 python3-docutils nodejs yarn gettext-base graphicsmagick \
      libpq5 zlib1g libyaml-0-2 libssl1.1 \
      libgdbm6 libreadline8 libncurses5 libffi7 \
      libxml2 libxslt1.1 libcurl4 libicu66 libre2-dev tzdata unzip libimage-exiftool-perl \
      libmagic1 \
 && update-locale LANG=C.UTF-8 LC_MESSAGES=POSIX \
 && locale-gen en_US.UTF-8 \
 && DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales \
 && rm -rf /var/lib/apt/lists/*

RUN bash ${GITLAB_BUILD_DIR}/install.sh

COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod 755 /sbin/entrypoint.sh

COPY --from=builder_gitlab_shell /tmp/gitlab-shell ${GITLAB_SHELL_INSTALL_DIR}
COPY --from=builder_gitaly /tmp/gitaly /home/gitaly
COPY --from=builder_gitaly /usr/local/bin/git /usr/local/bin/git
COPY --from=builder_gitlab_pages /tmp/gitlab-pages/bin/gitlab-pages /usr/local/bin/gitlab-pages
# executables are listed in gitlab/workhorse/Makefile as EXE_ALL = gitlab-resize-image gitlab-zip-cat gitlab-zip-metadata gitlab-workhorse
# will be installed to /usr/local/bin by default
COPY --from=builder_gitlab_workhorse /usr/local/bin/* /usr/local/bin/
 
ENV prometheus_multiproc_dir="/dev/shm"

ARG BUILD_DATE
ARG VCS_REF

LABEL \
    maintainer="sameer@damagehead.com" \
    org.label-schema.schema-version="1.0" \
    org.label-schema.build-date=${BUILD_DATE} \
    org.label-schema.name=gitlab \
    org.label-schema.vendor=damagehead \
    org.label-schema.url="https://github.com/sameersbn/docker-gitlab" \
    org.label-schema.vcs-url="https://github.com/sameersbn/docker-gitlab.git" \
    org.label-schema.vcs-ref=${VCS_REF} \
    com.damagehead.gitlab.license=MIT

EXPOSE 22/tcp 80/tcp 443/tcp

RUN ln -s /etc/ssl/certs/ca-certificates.crt /usr/lib/ssl/cert.pem

VOLUME ["${GITLAB_DATA_DIR}", "${GITLAB_LOG_DIR}","${GITLAB_HOME}/gitlab/node_modules"]
WORKDIR ${GITLAB_INSTALL_DIR}
ENTRYPOINT ["/sbin/entrypoint.sh"]
CMD ["app:start"]
