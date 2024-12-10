ARG VERSION=17.6.0
ARG GOLANG_VERSION=1.23.3

FROM golang:${GOLANG_VERSION} AS builder_gitlab_shell
COPY ./env.sh ./env.sh
RUN <<EOR
    source ./env.sh
    # install gitlab-shell
    echo "Downloading gitlab-shell v.${GITLAB_SHELL_VERSION}..."
    mkdir -p ${GITLAB_SHELL_INSTALL_DIR}
    wget -cq ${GITLAB_SHELL_URL} -O ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2
    tar xf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2 --strip 1 -C ${GITLAB_SHELL_INSTALL_DIR}
    rm -rf ${GITLAB_BUILD_DIR}/gitlab-shell-${GITLAB_SHELL_VERSION}.tar.bz2
    chown -R ${GITLAB_USER}: ${GITLAB_SHELL_INSTALL_DIR}

    cd ${GITLAB_SHELL_INSTALL_DIR}
    exec_as_git cp -a config.yml.example config.yml

    echo "Compiling gitlab-shell golang executables..."
    exec_as_git bundle config set --local deployment 'true'
    exec_as_git bundle config set --local with 'development test'
    exec_as_git bundle install -j"$(nproc)"
    exec_as_git "PATH=$PATH" make verify setup

    # remove unused repositories directory created by gitlab-shell install
    rm -rf ${GITLAB_HOME}/repositories
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitaly
COPY ./env.sh ./env.sh
RUN <<EOR
    source ./env.sh
    GITLAB_GITALY_BUILD_DIR=/tmp/gitaly
    # download and build gitaly
    echo "Downloading gitaly v.${GITALY_SERVER_VERSION}..."
    git clone -q -b v${GITALY_SERVER_VERSION} --depth 1 ${GITLAB_GITALY_URL} ${GITLAB_GITALY_BUILD_DIR}

    # install gitaly
    make -C ${GITLAB_GITALY_BUILD_DIR} install
    mkdir -p ${GITLAB_GITALY_INSTALL_DIR}
    # The following line causes some issues. However, according to
    # <https://gitlab.com/gitlab-org/gitaly/-/merge_requests/5512> and 
    # <https://gitlab.com/gitlab-org/gitaly/-/merge_requests/5671> there seems to
    # be some attempts to remove ruby from gitaly.
    #
    # cp -a ${GITLAB_GITALY_BUILD_DIR}/ruby ${GITLAB_GITALY_INSTALL_DIR}/
    cp -a ${GITLAB_GITALY_BUILD_DIR}/config.toml.example ${GITLAB_GITALY_INSTALL_DIR}/config.toml
    rm -rf ${GITLAB_GITALY_INSTALL_DIR}/ruby/vendor/bundle/ruby/**/cache
    chown -R ${GITLAB_USER}: ${GITLAB_GITALY_INSTALL_DIR}

    # install git bundled with gitaly.
    make -C ${GITLAB_GITALY_BUILD_DIR} git GIT_PREFIX=/usr/local

    # clean up
    rm -rf ${GITLAB_GITALY_BUILD_DIR}
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitlab_pages
COPY ./env.sh ./env.sh
RUN <<EOR
    source ./env.sh
    # download gitlab-pages
    GITLAB_PAGES_BUILD_DIR=/tmp/gitlab-pages
    echo "Downloading gitlab-pages v.${GITLAB_PAGES_VERSION}..."
    git clone -q -b v${GITLAB_PAGES_VERSION} --depth 1 ${GITLAB_PAGES_URL} ${GITLAB_PAGES_BUILD_DIR}
    make -C ${GITLAB_PAGES_BUILD_DIR}
EOR

FROM golang:${GOLANG_VERSION} AS builder_gitlab_workhorse
COPY ./env.sh ./env.sh
RUN <<EOR
    source ./env.sh
    # build gitlab-workhorse
    echo "Build gitlab-workhorse"
    git config --global --add safe.directory /home/git/gitlab
    make -C ${GITLAB_WORKHORSE_BUILD_DIR} install
    # clean up
    rm -rf ${GITLAB_WORKHORSE_BUILD_DIR}
EOR

FROM ubuntu:focal-20241011 AS main
COPY ./env.sh ./env.sh

RUN source ./env.sh \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
    wget ca-certificates apt-transport-https gnupg2 \
 && apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/*

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
      sudo supervisor logrotate locales curl \
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

COPY --from=builder_gitlab_shell ${GITLAB_SHELL_INSTALL_DIR} ${GITLAB_SHELL_INSTALL_DIR}
COPY --from=builder_gitaly ${GITLAB_GITALY_INSTALL_DIR} ${GITLAB_GITALY_INSTALL_DIR}
COPY --from=builder_gitaly /usr/local/bin/git /usr/local/bin/git
COPY --from=builder_gitlab_pages ${GITLAB_PAGES_BUILD_DIR}/gitlab-pages /usr/local/bin/gitlab-pages
 
COPY assets/build/ ${GITLAB_BUILD_DIR}/
RUN bash ${GITLAB_BUILD_DIR}/install.sh

COPY assets/runtime/ ${GITLAB_RUNTIME_DIR}/
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod 755 /sbin/entrypoint.sh

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
