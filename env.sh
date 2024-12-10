#!/usr/bin/env bash

export RUBY_VERSION=3.2.6
export RUBY_SOURCE_SHA256SUM="d9cb65ecdf3f18669639f2638b63379ed6fbb17d93ae4e726d4eb2bf68a48370"
export RUBYGEMS_VERSION=3.5.14
export GOLANG_VERSION=1.23.3
export GITLAB_VERSION=${VERSION}
export GITLAB_SHELL_VERSION=14.39.0
export GITLAB_PAGES_VERSION=17.6.0
export GITALY_SERVER_VERSION=17.6.0

export GITLAB_INSTALL_DIR="${GITLAB_HOME}/gitlab"
export GITLAB_SHELL_INSTALL_DIR="${GITLAB_HOME}/gitlab-shell"

export GITLAB_CLONE_URL=https://gitlab.com/gitlab-org/gitlab-foss.git
export GITLAB_SHELL_URL=https://gitlab.com/gitlab-org/gitlab-shell.git
export GITLAB_PAGES_URL=https://gitlab.com/gitlab-org/gitlab-pages.git
export GITLAB_GITALY_URL=https://gitlab.com/gitlab-org/gitaly.git
