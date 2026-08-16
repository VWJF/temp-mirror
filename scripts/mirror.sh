#!/usr/bin/env bash
# Push-mirror the GitHub event's ref to GitLab. Event-driven; never git push --mirror.
set -euo pipefail

ZERO_SHA="0000000000000000000000000000000000000000"

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

redact() {
  sed -e "s#${GITLAB_TOKEN}#***#g" -e "s#${GITLAB_USERNAME}:[^@/]*@#${GITLAB_USERNAME}:***@#g"
}

run_git() {
  local err
  if ! err="$("$@" 2>&1)"; then
    printf '%s\n' "$err" | redact >&2
    return 1
  fi
  if [[ -n "$err" ]]; then
    printf '%s\n' "$err" | redact
  fi
  return 0
}

require_cmd git
require_cmd jq
require_cmd gh

[[ -n "${GITLAB_URL:-}" ]] || die "gitlab_url is required."
[[ -n "${GITLAB_TOKEN:-}" ]] || die "gitlab_token is required."
[[ -n "${GITHUB_EVENT_PATH:-}" ]] || die "GITHUB_EVENT_PATH is not set."
[[ -f "$GITHUB_EVENT_PATH" ]] || die "Event payload not found at $GITHUB_EVENT_PATH"

GITLAB_USERNAME="${GITLAB_USERNAME:-oauth2}"
ONLY_PROTECTED_BRANCHES="${ONLY_PROTECTED_BRANCHES:-true}"
KEEP_DIVERGENT_REFS="${KEEP_DIVERGENT_REFS:-true}"
ACTION_PATH="${ACTION_PATH:-${GITHUB_ACTION_PATH:-}}"
REPO="${GITHUB_REPOSITORY:-}"
[[ -n "$REPO" ]] || die "GITHUB_REPOSITORY is not set."

DEFAULT_BRANCH="$(jq -r '.repository.default_branch // empty' "$GITHUB_EVENT_PATH")"
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"

# Auth is process-scoped only (env + git -c). Do not git config --global/--local
# credential helpers: self-hosted runners reuse the machine and workspace.
gitlab_host="$(printf '%s' "$GITLAB_URL" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' | cut -d/ -f1 | cut -d@ -f2)"
ASKPASS="${ACTION_PATH}/scripts/askpass.sh"
chmod +x "$ASKPASS" 2>/dev/null || true
export GIT_ASKPASS="$ASKPASS"
export GITLAB_USERNAME GITLAB_TOKEN
export GIT_TERMINAL_PROMPT=0

# Literal ${GITLAB_TOKEN} in the helper so `ps` does not contain the secret.
# The helper runs in a shell that expands the env var at prompt time.
git() {
  command git \
    -c "safe.directory=*" \
    -c "lfs.activitytimeout=240" \
    -c "credential.https://${gitlab_host}.username=${GITLAB_USERNAME}" \
    -c "credential.https://${gitlab_host}.helper=!f() { echo \"password=\${GITLAB_TOKEN}\"; }; f" \
    "$@"
}

cleanup_credentials() {
  unset GIT_ASKPASS GITLAB_TOKEN GITLAB_USERNAME
}
trap cleanup_credentials EXIT

if git remote get-url gitlab >/dev/null 2>&1; then
  git remote set-url gitlab "$GITLAB_URL"
else
  git remote add gitlab "$GITLAB_URL"
fi

# --- Event parsing -----------------------------------------------------------

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
REF_KIND=""
REF_NAME=""
FULL_REF=""
DELETED="false"
SOURCE_SHA=""

parse_event() {
  case "$EVENT_NAME" in
    push)
      FULL_REF="$(jq -r '.ref // empty' "$GITHUB_EVENT_PATH")"
      DELETED="$(jq -r '.deleted // false' "$GITHUB_EVENT_PATH")"
      SOURCE_SHA="$(jq -r '.after // empty' "$GITHUB_EVENT_PATH")"
      local before
      before="$(jq -r '.before // empty' "$GITHUB_EVENT_PATH")"
      if [[ "$DELETED" == "true" ]]; then
        SOURCE_SHA="$before"
      fi
      case "$FULL_REF" in
        refs/heads/*)
          REF_KIND="branch"
          REF_NAME="${FULL_REF#refs/heads/}"
          ;;
        refs/tags/*)
          REF_KIND="tag"
          REF_NAME="${FULL_REF#refs/tags/}"
          ;;
        *)
          die "Unrecognized push ref: ${FULL_REF:-<empty>}"
          ;;
      esac
      ;;
    create)
      REF_KIND="$(jq -r '.ref_type // empty' "$GITHUB_EVENT_PATH")"
      REF_NAME="$(jq -r '.ref // empty' "$GITHUB_EVENT_PATH")"
      DELETED="false"
      SOURCE_SHA="${GITHUB_SHA:-}"
      case "$REF_KIND" in
        branch) FULL_REF="refs/heads/${REF_NAME}" ;;
        tag) FULL_REF="refs/tags/${REF_NAME}" ;;
        *) die "Unrecognized create ref_type: ${REF_KIND:-<empty>}" ;;
      esac
      ;;
    delete)
      REF_KIND="$(jq -r '.ref_type // empty' "$GITHUB_EVENT_PATH")"
      REF_NAME="$(jq -r '.ref // empty' "$GITHUB_EVENT_PATH")"
      DELETED="true"
      SOURCE_SHA=""
      case "$REF_KIND" in
        branch) FULL_REF="refs/heads/${REF_NAME}" ;;
        tag) FULL_REF="refs/tags/${REF_NAME}" ;;
        *) die "Unrecognized delete ref_type: ${REF_KIND:-<empty>}" ;;
      esac
      ;;
    workflow_dispatch)
      REF_NAME="$(jq -r '.inputs.ref // empty' "$GITHUB_EVENT_PATH")"
      DELETED="false"
      if [[ -z "$REF_NAME" ]]; then
        REF_KIND="branch"
        REF_NAME="$DEFAULT_BRANCH"
        FULL_REF="refs/heads/${REF_NAME}"
      elif [[ "$REF_NAME" == refs/tags/* ]]; then
        REF_KIND="tag"
        REF_NAME="${REF_NAME#refs/tags/}"
        FULL_REF="refs/tags/${REF_NAME}"
      elif [[ "$REF_NAME" == refs/heads/* ]]; then
        REF_KIND="branch"
        REF_NAME="${REF_NAME#refs/heads/}"
        FULL_REF="refs/heads/${REF_NAME}"
      else
        REF_KIND="branch"
        FULL_REF="refs/heads/${REF_NAME}"
      fi
      ;;
    *)
      die "Unsupported event: ${EVENT_NAME:-<empty>}. Expected push, create, delete, or workflow_dispatch."
      ;;
  esac

  [[ -n "$REF_KIND" && -n "$REF_NAME" && -n "$FULL_REF" ]] \
    || die "Could not determine the ref to mirror from event '${EVENT_NAME}'."
}

# Prints "true", "false", or "unknown".
branch_protection_state() {
  local branch="$1"
  local json="" rules_len="" protected="false"
  local branch_ok=0 rules_ok=0

  if json="$(gh api "repos/${REPO}/branches/${branch}" 2>/dev/null)"; then
    branch_ok=1
    protected="$(printf '%s' "$json" | jq -r '.protected // false')"
    if [[ "$protected" == "true" ]]; then
      printf 'true'
      return 0
    fi
  fi

  if rules_len="$(gh api "repos/${REPO}/rules/branches/${branch}" --jq 'length' 2>/dev/null)"; then
    rules_ok=1
    if [[ "$rules_len" -gt 0 ]]; then
      printf 'true'
      return 0
    fi
  fi

  if [[ $branch_ok -eq 1 || $rules_ok -eq 1 ]]; then
    printf 'false'
    return 0
  fi

  printf 'unknown'
}

ensure_protected_or_skip() {
  [[ "$REF_KIND" == "branch" ]] || return 0
  is_true "$ONLY_PROTECTED_BRANCHES" || return 0

  local state
  state="$(branch_protection_state "$REF_NAME")"
  case "$state" in
    true)
      log "Branch '${REF_NAME}' is protected on GitHub; continuing."
      ;;
    false)
      log "Skipping '${REF_NAME}': only_protected_branches is true and this branch is not protected on GitHub."
      exit 0
      ;;
    *)
      die "Could not determine protection status for branch '${REF_NAME}'. Failing closed (will not push all refs). Grant github_token access to read branches and rulesets."
      ;;
  esac
}

gitlab_ls_remote() {
  local spec="$1"
  git ls-remote --quiet gitlab "$spec" 2>/dev/null | awk '{print $1; exit}'
}

fetch_github_objects() {
  run_git git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune || true
  run_git git fetch origin '+refs/tags/*:refs/tags/*' || true
}

resolve_source_sha() {
  if [[ "$DELETED" == "true" ]]; then
    return 0
  fi

  case "$REF_KIND" in
    branch)
      run_git git fetch origin "${REF_NAME}" || true
      if git rev-parse --verify "refs/remotes/origin/${REF_NAME}" >/dev/null 2>&1; then
        SOURCE_SHA="$(git rev-parse "refs/remotes/origin/${REF_NAME}")"
      fi
      ;;
    tag)
      run_git git fetch origin "refs/tags/${REF_NAME}:refs/tags/${REF_NAME}" || true
      if git rev-parse --verify "refs/tags/${REF_NAME}" >/dev/null 2>&1; then
        SOURCE_SHA="$(git rev-parse "refs/tags/${REF_NAME}")"
      fi
      ;;
  esac

  if [[ -z "$SOURCE_SHA" || "$SOURCE_SHA" == "$ZERO_SHA" ]]; then
    SOURCE_SHA="${GITHUB_SHA:-}"
  fi

  [[ -n "$SOURCE_SHA" && "$SOURCE_SHA" != "$ZERO_SHA" ]] \
    || die "Could not resolve the source SHA for ${FULL_REF}."
}

is_merged_into_default() {
  local sha="$1"
  [[ -n "$sha" && "$sha" != "$ZERO_SHA" ]] || return 1

  run_git git fetch origin "${DEFAULT_BRANCH}" || true
  local default_sha
  if git rev-parse --verify "refs/remotes/origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    default_sha="$(git rev-parse "refs/remotes/origin/${DEFAULT_BRANCH}")"
  else
    return 1
  fi

  git cat-file -e "${sha}^{commit}" 2>/dev/null || run_git git fetch origin "$sha" || true
  git cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$sha" "$default_sha"
}

handle_delete() {
  if [[ "$REF_KIND" == "tag" ]]; then
    log "Tag '${REF_NAME}' was deleted on GitHub. Not pruning tags on GitLab (GitLab push-mirror behavior)."
    exit 0
  fi

  if is_true "$KEEP_DIVERGENT_REFS"; then
    log "keep_divergent_refs is true: leaving dest-only ref '${FULL_REF}' on GitLab untouched."
    exit 0
  fi

  local dest
  dest="$(gitlab_ls_remote "$FULL_REF" || true)"
  if [[ -z "$dest" ]]; then
    log "GitLab does not have ${FULL_REF}; nothing to delete."
    exit 0
  fi

  if [[ -z "$SOURCE_SHA" || "$SOURCE_SHA" == "$ZERO_SHA" ]]; then
    log "No deleted-branch SHA in the event; cannot prove the branch was merged. Leaving '${REF_NAME}' on GitLab."
    exit 0
  fi

  if is_merged_into_default "$SOURCE_SHA"; then
    log "Branch '${REF_NAME}' was deleted on GitHub and is merged into '${DEFAULT_BRANCH}'. Deleting on GitLab."
    run_git git push gitlab --delete "$FULL_REF" \
      || die "GitLab rejected deleting ${FULL_REF}. See the message above (protected branch, permissions, or LFS)."
    log "Deleted ${FULL_REF} on GitLab."
    exit 0
  fi

  log "Branch '${REF_NAME}' was deleted on GitHub but is not merged into '${DEFAULT_BRANCH}' (git ancestry). Leaving it on GitLab."
  exit 0
}

handle_update() {
  if command -v git-lfs >/dev/null 2>&1; then
    run_git git lfs fetch origin "$SOURCE_SHA" || run_git git lfs fetch origin "$REF_NAME" || true
  fi

  local dest
  dest="$(gitlab_ls_remote "$FULL_REF" || true)"

  if [[ -n "$dest" && "$dest" == "$SOURCE_SHA" ]]; then
    log "GitLab ${FULL_REF} already at ${SOURCE_SHA}. No-op."
    exit 0
  fi

  local src_spec="${SOURCE_SHA}:${FULL_REF}"
  if [[ "$REF_KIND" == "tag" ]] && git rev-parse --verify "refs/tags/${REF_NAME}" >/dev/null 2>&1; then
    src_spec="refs/tags/${REF_NAME}"
  fi

  if [[ -z "$dest" ]]; then
    log "Creating GitLab ${FULL_REF} at ${SOURCE_SHA}."
    run_git git push gitlab "$src_spec" \
      || die "GitLab rejected creating ${FULL_REF}. See the message above (protected branch, LFS objects missing, file too large, or permissions)."
    log "Updated GitLab ${FULL_REF} to ${SOURCE_SHA}."
    return 0
  fi

  if is_true "$KEEP_DIVERGENT_REFS"; then
    log "Pushing ${SOURCE_SHA} → GitLab ${FULL_REF} (fast-forward only; keep_divergent_refs=true)."
    if ! run_git git push gitlab "$src_spec"; then
      die "GitLab ref ${FULL_REF} has diverged (GitHub=${SOURCE_SHA}, GitLab=${dest}). keep_divergent_refs is true, so this Action will not overwrite. Integrate the two tips on one machine, push to one remote, and let mirroring copy. See FAQ.md."
    fi
    log "Updated GitLab ${FULL_REF} to ${SOURCE_SHA}."
    return 0
  fi

  log "Pushing ${SOURCE_SHA} → GitLab ${FULL_REF} (force; keep_divergent_refs=false)."
  run_git git push --force gitlab "$src_spec" \
    || die "GitLab rejected the force-push of ${FULL_REF}. See the message above (protected branch, LFS objects missing, file too large, or permissions)."
  log "Updated GitLab ${FULL_REF} to ${SOURCE_SHA}."
}

parse_event
log "Event=${EVENT_NAME} kind=${REF_KIND} ref=${FULL_REF} deleted=${DELETED} sha=${SOURCE_SHA:-<none>}"

ensure_protected_or_skip
fetch_github_objects

if [[ "$DELETED" == "true" ]]; then
  handle_delete
fi

resolve_source_sha
handle_update
