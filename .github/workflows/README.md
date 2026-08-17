# Workflows

This repository is a **caller** of the reusable Action in [VWJF/mirroring](https://github.com/VWJF/mirroring). The Action definition does not live here.

## `push-mirror.yml`

Push-mirrors the triggering GitHub ref to GitLab (`GITLAB_URL`).

- Triggers: `push` (branches and tags), `workflow_dispatch`
- Action: `VWJF/mirroring@0.0.2-alpha`
- Concurrency is per ref; in-progress runs are **not** cancelled
- Tag `create` is not a separate trigger: a tag push already fires `push`, so `on: create` caused two runs for one tag

### Required GitHub configuration

**Secret** (Settings → Secrets and variables → Actions → Secrets):

- `GITLAB_TOKEN` — GitLab project or personal access token with `write_repository`. For protected `main`, the token **role** must be **Maintainer** (Developer cannot push protected branches). You do not need to unprotect `main`.

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

GitHub only shows **Run workflow** for `workflow_dispatch` if this file exists on the **default branch** (`main`).

Actions → **Push mirror to GitLab** → **Run workflow**. Optional input `ref` (branch or tag); empty uses the default branch.

Full Action behavior, knobs, and bidirectional setup: [VWJF/mirroring](https://github.com/VWJF/mirroring).

### Alerts

- **GitLab → GitHub** (native push mirror): GitLab emails **project Maintainers/Owners** on the first failed remote-mirror update (including a keep-divergent skip). The project page also shows a warning and an Error badge. Later retries in the same failure streak do not send another mail.
- **GitHub → GitLab** (this workflow): GitHub does **not** email all maintainers. The **user who pushed** may get an Actions failure mail if they have Actions notifications on. Other maintainers must **watch** this repo and enable **Actions / failed workflow** notifications, or they will miss a red run (including an intentional fail-closed divergence).

Details: [VWJF/mirroring README — Alerts](https://github.com/VWJF/mirroring#alerts).
