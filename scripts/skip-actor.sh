#!/usr/bin/env bash
# Exit 0 and set skip=true if GITHUB_ACTOR is in SKIP_GITHUB_ACTORS.
set -euo pipefail

if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  echo "GITHUB_OUTPUT is not set; this script must run in GitHub Actions." >&2
  exit 1
fi

actor="${ACTOR:-${GITHUB_ACTOR:-}}"
if [[ -z "${SKIP_GITHUB_ACTORS:-}" || -z "$actor" ]]; then
  echo "skip=false" >>"$GITHUB_OUTPUT"
  exit 0
fi

# Split on commas or newlines; trim whitespace; compare case-insensitively.
normalized_actor="$(printf '%s' "$actor" | tr '[:upper:]' '[:lower:]')"
while IFS= read -r raw; do
  entry="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$entry" ]] && continue
  normalized_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized_entry" == "$normalized_actor" ]]; then
    echo "Skipping mirror: github.actor '${actor}' is in skip_github_actors."
    echo "skip=true" >>"$GITHUB_OUTPUT"
    exit 0
  fi
done < <(printf '%s\n' "$SKIP_GITHUB_ACTORS" | tr ',' '\n')

echo "skip=false" >>"$GITHUB_OUTPUT"
