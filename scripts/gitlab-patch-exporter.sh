#!/usr/bin/env bash

set -Ceu

git_find_merge_of_to() {
  commit=$1
  branch=${2:-HEAD}
  (
    git rev-list --format=%h "$commit..$branch" --ancestry-path | cat -n
    git rev-list --format=%h "$commit..$branch" --first-parent | cat -n
  ) | sort -k2 -s | uniq -f1 -d | sort -n | tail -1 | cut -f2
}

# git-listup-change-list
# first argument $1 : git revision duration <revision>..<revision>
#   <revision> is a commit hash, branch name, tag or something else
#   example : v15.0.0-ee..v15.1.0-ee
#     In this case, this script will try to find out the commit happen
#     between a tag (or branch named) v15.0.0-ee and v15.1.0-ee
# second argumetn $2 : file path to generate patch
# 
# result : multiple lines
# a line is like below. note that commit date is in iso8601 format, "seconds" precision, timezone will be unified:
#   <commit date in iso8601> <first contained tag> <commit hash> <merge request reference (optional)>
# Here is an example:
#   2022-09-30T11:54:46+09:00 v15.5.0-ee 205492ba805aa8d8064b52046c5d2ef16840d544 gitlab-org/gitlab!98770
git_listup_change_list_between_revisions_for_file() {
  target_revision_duration_string=$1
  target_filepath=$2

  # separate revision range string into begin/end
  # I hope no one use .. in git tag or branch name
  # revision_range_begin=${target_revision_duration_string%\.\.*}
  revision_range_end=${target_revision_duration_string##*\.\.}

  # get list of commit hash that happens between specified duration ignoring merge commits
  # --format %h : short commit hash
  # then get merge commit, check merge request ref
  #   In gitlab.com/gitlab-org/gitlab, merge commit typically contains reference for merge request
  #   ("See merge request gitlab.com/gitlab-org/gitlab!xxxxx", for example).
  #   NOTE:
  #     With various reason (not merge request created for security reason, or merge is done by bot, for example),
  #     but sometimes commit message does not contain any useful message.
  #     So merge_request_ref will be empty string in this case
  #     Here is the example. This merge is done in gitlab-org/gitlab":
  #       2021-10-29T01:06:57+09:00 v14.5.0-ee 9a2d2e0c44ccca0436cba5e26faeb271a18319e3
  #   NOTE:
  #     Additionally, some security fixes are commited directly (without merge)
  #     so we need to check whole commit and then check if merge is happen or not
  # sort result with merge commit and make unique, then sort by date
  IFS_ORG=$IFS
  IFS=$(printf '\n')
  git log --format=format:%h --follow "$target_revision_duration_string" -- "$target_filepath" | while read -r commit; do
    git_find_merge_of_to "$commit" "$revision_range_end"
  done | sort -k3 | uniq | while read -r merge_commit; do
    # Timezone of each commit will be unified by specifying --date option
    merge_commit_info="$(git show --no-patch --format=%cd%n%B --date=iso8601-strict-local "${merge_commit}")"

    merge_date_iso8601=${merge_commit_info%%$'\n'*}

    # merge_request_ref="$(echo "$merge_commit_info" | grep "See merge request")"
    # merge_request_ref="${merge_request_ref/*See merge request /}"
    # # optional : convert url to merge request reference : https://gitlab.com/:repo/-/merge_requests/:id
    # ## remove until :repo
    # merge_request_ref=${merge_request_ref/https:\/\/gitlab\.com\//}
    # ## convert /-/merge_requests/ to ! (gitlab merge request reference prefix)
    # merge_request_ref=${merge_request_ref/\/-\/merge_requests\//!}

    # check first stable release contains the change (ignore pre-release e.g. "v15.4.0-rc42-ee")
    # first_contained_tag="$(git tag --contains "${merge_commit}" --sort=version:refname | grep -v rc | head -n 1)" 

    printf "%s %s\n" "$merge_commit" "${merge_date_iso8601}" #"$merge_request_ref" 
  done
  IFS=$IFS_ORG
}


SCRIPT_DIR="$(cd "$(dirname "$0")" || exit; pwd)"

UPSTREAM_GITALY_CONFIG_TOML="gitaly.git/config/"
GITALY_UPSTREAM_CONFIGS="${UPSTREAM_GITALY_CONFIG_TOML}"

UPSTREAM_GITLAB_DATABASE_YML="config/database.yml.postgresql"
UPSTREAM_GITLAB_GITLAB_YML="config/gitlab.yml.example"
UPSTREAM_GITLAB_PUMA_RB="config/puma.rb.example"
UPSTREAM_GITLAB_RELATIVE_URL_RB="config/initializers/relative_url.rb.sample"
UPSTREAM_GITLAB_RESQUE_YML="config/resque.yml.example"
UPSTREAM_GITLAB_SECRETS_YML="config/secrets.yml.example"
UPSTREAM_GITLAB_SMTP_SETTINGS_RB="config/initializers/smtp_settings.rb.sample"

GITLAB_UPSTREAM_CONFIGS="${UPSTREAM_GITLAB_DATABASE_YML} ${UPSTREAM_GITLAB_GITLAB_YML} ${UPSTREAM_GITLAB_PUMA_RB} ${UPSTREAM_GITLAB_RELATIVE_URL_RB} ${UPSTREAM_GITLAB_RESQUE_YML} ${UPSTREAM_GITLAB_SECRETS_YML} ${UPSTREAM_GITLAB_SMTP_SETTINGS_RB}"

DOCKER_GITLAB_RUNTIME_CONFIG_BASE=assets/runtime/config

GITLAB_CE_TARGET_REVISION_RANGE=$1
PATCH_DESTINATION_DIR="${SCRIPT_DIR}/patches_${GITLAB_CE_TARGET_REVISION_RANGE}/"

echo "comparing $GITLAB_CE_TARGET_REVISION_RANGE"
mkdir -p "${PATCH_DESTINATION_DIR}"
i=0
cd "${SCRIPT_DIR}/../../gitlab.git" || exit
( for config_file in $GITLAB_UPSTREAM_CONFIGS; do
  git_listup_change_list_between_revisions_for_file "${GITLAB_CE_TARGET_REVISION_RANGE}" "${config_file}"
done ) | sort -k2 | uniq | while read -r change; do
  # format : abbreviated_commit_hash commit_date_YYYY-mm-ddTHH:MM:SSZ
  merge_commit="${change%% *}"
  first_contained_tag=$(git tag --contains "${merge_commit}" | grep -v rc | sort --version-sort | head -n 1)
  echo "= Generating patch from merge commit ${merge_commit}"
  ((i++)) || :
  MR_PATCH_DEST_DIR=$(printf "%s/%03d_%s_%s" "${PATCH_DESTINATION_DIR}" "${i}" "${merge_commit}" "${first_contained_tag}")
  mkdir -p "${MR_PATCH_DEST_DIR}"

  # git-format-patch
  # - Specifying number of commits to be exported. By specifying -1, we can generate patches for exact specified commit
  #   By default, git format-patch will generate since specified commit until HEAD
  # FIXME: generated patch only contains changes for gitlab.yml.example
  # shellcheck disable=SC2086
  git format-patch --output-directory "${MR_PATCH_DEST_DIR}" -1 "${merge_commit}" ${GITLAB_UPSTREAM_CONFIGS} | cat
done

# in-repository filepath mapping (upstream vs sameersbn/docker-gitlab)
find "${PATCH_DESTINATION_DIR}" -name "*.patch" -print0 \
| xargs -0 sed -i \
  -e "s:${UPSTREAM_GITLAB_DATABASE_YML}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/database.yml:g" \
  -e "s:${UPSTREAM_GITLAB_GITLAB_YML}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/gitlab.yml:g" \
  -e "s:${UPSTREAM_GITLAB_PUMA_RB}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/puma.rb:g" \
  -e "s:${UPSTREAM_GITLAB_RELATIVE_URL_RB}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/relative_url.rb:g" \
  -e "s:${UPSTREAM_GITLAB_RESQUE_YML}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/resque.yml:g" \
  -e "s:${UPSTREAM_GITLAB_DATABASE_YML}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/database.yml:g" \
  -e "s:${UPSTREAM_GITLAB_SMTP_SETTINGS_RB}:${DOCKER_GITLAB_RUNTIME_CONFIG_BASE}/gitlabhq/smtp_settings.rb:g"
