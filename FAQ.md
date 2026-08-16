# FAQ: GitHub → GitLab push-mirror Action

For operators of a GitHub↔GitLab pair. This records the design questions, the choices we made, and what to do in production.

## What this is

### Why not GitLab native bidirectional or pull mirroring?

GitLab **pull** mirroring (and therefore native bidirectional mirroring) is Premium and is not available on this GitLab instance. GitLab **push** mirroring (GitLab → GitHub) is available.

**Choice:** compose GitLab’s native push mirror (GitLab → GitHub) with this GitHub Action (GitHub → GitLab). Do not use GitLab native pull/bidirectional.

### Does the Action work without GitLab’s native mirror?

**Yes.** Used alone it is a GitHub → GitLab **push mirror** with the same deletion rules and knobs as GitLab (`only_protected_branches`, `keep_divergent_refs`, merged-branch delete, no tag prune). Bidirectional is optional: turn on GitLab’s native push mirror and `skip_github_actors` when you want the other direction.

### Must GitHub be public and GitLab private?

**No.** Visibility can change. Callers always provide credentials (`gitlab_token`, and `github_token` when the GitHub repo is private or you need the protection APIs).

## What is mirrored

### Are the git trees identical?

**Yes, that is the goal.** Commits, branches, and tags are the same on both remotes. `.github/workflows` and `.gitlab-ci.yml` both exist on both sides; each platform ignores the other’s CI files.

Not mirrored (platform metadata): issues, pull requests / merge requests, protections, secrets, webhooks, and GitHub/GitLab release objects. Git tags still sync.

### Why not a branch allowlist (regex)?

GitLab Free push-mirror’s closest control is **Only mirror protected branches**, not a regex allowlist (that is Premium).

**Choice:** treat GitHub the same. Input `only_protected_branches` defaults to `true`. The Action checks GitHub classic branch protection and, when practical, rulesets. If protection status cannot be determined, it **fails closed** (does not push everything). It never runs `git push --mirror`; it only syncs the event’s ref.

### If GitHub is public, does GitLab history become public?

If you mirror to a public GitHub repo, that **git history is public**. The Action does not filter files or commits. That is a visibility choice for the pair.

## Knobs (match GitLab)

### Is “keep divergent refs” a parameter?

**Yes.** `keep_divergent_refs`.

- GitLab’s native default is overwrite (`false`): a diverged destination ref is force-updated and dest-only refs can be removed when GitLab would delete a merged branch.
- **Choice for this Action’s default:** `true`, because bidirectional use must not clobber the other side. Set `false` if you want a one-way GitHub → GitLab mirror that overwrites like GitLab’s native default.

For bidirectional mirroring, set **true on both** this Action and GitLab’s native push mirror.

### Is “only protected branches” a parameter?

**Yes.** `only_protected_branches`, default `true` (safest). Keep GitHub and GitLab protection lists in sync. Tags are still created/updated when this is true.

### When are branches deleted on GitLab?

Like GitLab: only if the branch was **deleted on GitHub** and its tip is **merged into the default branch** (git ancestry: `merge-base --is-ancestor`). Unmerged branches are left alone.

If `keep_divergent_refs` is `true`, dest-only refs are left untouched (no delete), matching GitLab’s keep-divergent behavior.

**Squash/rebase caveat:** GitLab’s “merged” check is git ancestry, not “GitHub says the PR merged.” A squash-merged branch is often **not** an ancestor of `main`, so the Action (like GitLab) **leaves** that branch on GitLab. We do not add extra GitHub-PR heuristics.

### When are tags deleted on GitLab?

**Never automatically.** Creating and updating tags is mirrored. Deleting a tag on GitHub does **not** prune it on GitLab (GitLab push-mirror behavior). Clean up tags on GitLab by hand if needed.

## Loops and scheduling

### How do we stop an infinite mirror loop?

GitLab’s native mirror pushing to GitHub would retrigger this Action.

**Choice:** both of:

1. `skip_github_actors` — optional list. If `github.actor` matches, exit 0. For bidirectional, use a **dedicated GitHub user or GitHub App** as GitLab’s push-mirror credentials (not a human who also pushes real work). If unset, standalone mode: do not skip.
2. Idempotent SHA check — `git ls-remote` live GitLab; if the destination already has that SHA, no-op (success). This still uses Actions minutes but is the backstop when actor skip is misconfigured.

Pushes from this Action use a GitLab token, not `GITHUB_TOKEN`. GitHub’s “GITHUB_TOKEN does not retrigger workflows” does **not** stop the GitLab → GitHub → Action loop.

### Why is GitLab → GitHub slower than GitHub → GitLab?

GitLab push-mirror is **not** a git hook. It is a Sidekiq background job: the remote is updated **within about five minutes**, or **about one minute** if **Only mirror protected branches** is on. A cron considers due mirrors about once a minute, subject to capacity and retry backoff. Forced **Update now** is rate-limited.

This Action is event-driven (`on: push`) and starts in seconds.

### Should the Action also wait 1–5 minutes so the schedules match?

**No.** Delaying GitHub does not remove concurrent-write races: if both remotes already have different commits, the tips have diverged. GitLab’s delay is “within N minutes,” not an exact interval, so it cannot be matched. Sleeping in Actions also burns billed minutes.

**Choice:** the Action stays immediate and compares against **live GitLab** (`git ls-remote`), not against GitHub’s copy of GitLab (which can be 1–5 minutes stale). GitLab → GitHub lag is accepted.

Rejected for v1: debounce/sleep to mimic GitLab; GitLab-side CI/API “Update now” to speed the native mirror.

## Conflicts and merges

### What if the same branch is committed on both sides before sync?

That is a non-fast-forward.

- `keep_divergent_refs: true` — fail that ref; keep both histories; a human resolves.
- `keep_divergent_refs: false` — the source overwrites the destination (can lose commits).

No scheduler trick fixes this. Do not rewrite mirrored history. Prefer protected branches on both remotes.

### What if we merge when `main` has diverged, or merge the same PR/MR on both platforms?

A PR/MR merge is only a **push to the target**, computed against **that platform’s** target tip. It cannot be replayed onto a different `main`.

Extra failure modes even when targets started in sync:

1. GitHub squash/merge creates SHA `G`; GitLab MR merge creates SHA `L`. Neither is an ancestor of the other. PRs/MRs are not mirrored, so the other request can stay open (especially squash: GitLab does not see the original feature commits in `main`).
2. Squash/rebase then delete the feature branch: leftover destination branch + open MR invites a second merge.

**Choice:** emulate GitLab push-mirror. The Action does **not** `git merge` the two target tips, rebase the merge, or close the other side’s MR. Same fail-or-overwrite rule as any diverged ref.

**Recovery (manual):** on one machine, fetch both remotes, merge or rebase the two target tips until they share one tip, push that tip to **one** remote, let mirroring copy it, then close leftover PRs/MRs. Do not merge the same feature independently on both sides.

### Why not auto-merge diverged targets or enforce a single merge gate?

Rejected for v1. Auto-merge is not GitLab push-mirror behavior and can create unexpected commits. A one-platform merge gate (humans merge `main` only on GitHub or only on GitLab) is **operational advice**, not encoded in the Action.

## Credentials and network

### What tokens are required?

- **GitLab (`gitlab_token`):** `write_repository`. The token user must be allowed to push (and, if you delete merged branches, delete) protected branches.
- **GitHub (`github_token`):** clone if the source is private; read branches/rulesets for `only_protected_branches`. Fine-grained: Contents read; add more if the protection APIs return 403.
- **GitLab’s native mirror toward GitHub:** PAT or fine-grained token with Contents write, and Workflows write if `.github/workflows` exists.

Use **HTTPS**. GitLab cannot push LFS over SSH. Both remotes must use the same object format. GitHub’s 100 MB / LFS limits still apply when GitLab is the destination.

The Action does **not** write GitLab credentials (or a credential helper) to `~/.gitconfig` or `~/.git-credentials`. Auth is only `GIT_ASKPASS` plus per-process `git -c` flags, then those env vars are unset when the script exits. The same path is safe on GitHub-hosted and reused self-hosted runners.

### Why did the job fail with a GitLab rejection?

The Action prints GitLab’s message (with tokens redacted). Common causes: protected branch does not allow the token user; missing LFS objects; file larger than GitHub’s limit; non-fast-forward with `keep_divergent_refs: true`.

## Packaging

### Where does the Action live?

Developed in [VWJF/temp-mirror](https://github.com/VWJF/temp-mirror) (`action.yml` + `scripts/` + caller workflow). Setup and inputs are in [README_mirror.md](README_mirror.md). Extract to its own repository later. Not published to Marketplace in v1.

### What is out of scope for v1?

- Regex branch allowlists
- File-level excludes / non-identical trees
- Debounce or sleep to match GitLab’s 1–5 minute schedule
- GitLab-side “Update now” / CI trigger to speed native GitLab → GitHub mirroring
- Auto-merging diverged target branches or closing the other side’s MR
- Encoding a one-platform merge gate in the Action
- Server-side pre-receive proxy hooks (GitLab’s conflict-prevention recipe)
