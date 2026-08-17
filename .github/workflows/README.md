# Workflows

This repository is a **caller** of the reusable Action in [VWJF/mirroring](https://github.com/VWJF/mirroring). The Action definition does not live here.

## `push-mirror.yml`

Push-mirrors the triggering GitHub ref to GitLab (`GITLAB_URL`).

- Triggers: `push`, tag `create`, `workflow_dispatch`
- Action: `VWJF/mirroring@feat/github-gitlab-push-mirror` (move to a tag or `@main` after that branch is merged)
- Concurrency is per ref; in-progress runs are **not** cancelled

### Required GitHub configuration

**Secret** (Settings → Secrets and variables → Actions → Secrets):

- `GITLAB_TOKEN` — GitLab project or personal access token with `write_repository`. For a project access token, the token **role** must be Developer or Maintainer, not only those scopes.

**Variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Required | Meaning |
| --- | --- | --- |
| `GITLAB_URL` | yes | HTTPS clone URL, e.g. `https://gitlab.rcg.sfu.ca/<user>/temp-mirror.git` |
| `GITLAB_USERNAME` | no | Default `oauth2` (or the project-access-token bot username) |
| `ONLY_PROTECTED_BRANCHES` | no | Default `true` in the Action; this test pair may set `false` |
| `KEEP_DIVERGENT_REFS` | no | Default `true` (do not overwrite GitLab if the ref diverged) |
| `SKIP_GITHUB_ACTORS` | no | GitHub username/`app[bot]` used by GitLab’s native push mirror; empty for GitHub→GitLab only |

Do not put the GitLab URL or token in this workflow file.

### Manual run

Actions → **Push mirror to GitLab** → **Run workflow**. Optional input `ref` (branch or tag); empty uses the default branch.

Full Action behavior, knobs, and bidirectional setup: [VWJF/mirroring](https://github.com/VWJF/mirroring).
