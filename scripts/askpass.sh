#!/usr/bin/env bash
# GIT_ASKPASS helper: never echo credentials except as git's password/username reply.
set -euo pipefail
prompt="${1:-}"
case "$prompt" in
  *[Uu]sername*) printf '%s\n' "${GITLAB_USERNAME:-oauth2}" ;;
  *) printf '%s\n' "${GITLAB_TOKEN:-}" ;;
esac
