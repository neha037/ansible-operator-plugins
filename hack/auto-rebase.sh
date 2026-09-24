#!/usr/bin/env bash
#
# Periodic / CI entrypoint for rebasing openshift/ansible-operator-plugins onto
# a newer upstream ansible-operator-plugins release tag.
#
# Uses ./openshift/hack/rebase_upstream.sh for the merge. Opens a PR; does not
# auto-merge.
#
# Environment:
#   OVERRIDE_TAG           Optional. Override tag discovery; rebase this specific tag.
#   REBASE_BRANCH          Downstream branch to rebase onto (default: main).
#   UPSTREAM_REMOTE        Remote name for upstream repo (default: upstream).
#   UPSTREAM_URL           URL for the upstream remote (default: https://github.com/operator-framework/ansible-operator-plugins.git).
#   ORIGIN_REMOTE          Remote name to push PR branch (default: origin).
#   ORIGIN_URL             URL for the origin remote (default: https://github.com/${DEST_ORG_REPO}.git).
#   DEST_ORG_REPO          GitHub org/repo for PRs (default: openshift/ansible-operator-plugins).
#   GITHUB_TOKEN           Token for push + gh pr create (minted by the periodic job).
#   DRY_RUN                If set to 1, only report what would happen (no merge/push/PR).
#   FORCE_REMOTE_URLS      If set to 1, allow rewriting an existing remote whose
#                          org/repo differs from the expected value (e.g. a developer fork).
#                          Default 0 — the script aborts instead to protect local config.
#   ALLOW_BRANCH_DELETE    If set to 1, allow deleting stale local rebase branches.
#                          Automatically enabled in CI (OPENSHIFT_CI / CI / JOB_NAME).
#   GIT_AUTHOR_NAME        Git identity for commits (default: openshift-app-platform-shift-bot).
#   GIT_AUTHOR_EMAIL       Git identity email (default: 267347085+openshift-app-platform-shift-bot@users.noreply.github.com).
#
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

REBASE_BRANCH=${REBASE_BRANCH:-main}
UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-upstream}
ORIGIN_REMOTE=${ORIGIN_REMOTE:-origin}
DEST_ORG_REPO=${DEST_ORG_REPO:-openshift/ansible-operator-plugins}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/operator-framework/ansible-operator-plugins.git}
ORIGIN_URL=${ORIGIN_URL:-https://github.com/${DEST_ORG_REPO}.git}
DRY_RUN=${DRY_RUN:-0}
FORCE_REMOTE_URLS=${FORCE_REMOTE_URLS:-0}
GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-openshift-app-platform-shift-bot}
GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-267347085+openshift-app-platform-shift-bot@users.noreply.github.com}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Cleanup (credential file only) ---
_cred_file=""
_cleanup() {
  [[ -n "$_cred_file" ]] && rm -f "$_cred_file"
  git config --unset credential.helper 2>/dev/null || true
}
trap _cleanup EXIT

# True when running inside Prow / CI (checked env vars).
is_ci_context() {
  [[ -n "${OPENSHIFT_CI:-}" || -n "${CI:-}" || -n "${JOB_NAME:-}" ]]
}

# Delete a leftover local rebase branch, but only in CI or with opt-in.
cleanup_stale_branch() {
  local branch=$1
  git show-ref --verify --quiet "refs/heads/${branch}" || return 0
  if is_ci_context || [[ "${ALLOW_BRANCH_DELETE:-0}" == "1" ]]; then
    log "Deleting stale local branch ${branch}"
    git branch -D "$branch"
    return 0
  fi
  die "Local branch ${branch} already exists. Delete it manually or set ALLOW_BRANCH_DELETE=1."
}

# Return 0 if $1 is a strictly newer semver than $2 (release tags only).
version_gt() {
  local a=${1#v} b=${2#v}
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

# Extract a safe "org/repo" identifier from supported GitHub URL forms.
# Never emit the original URL: it may contain credentials or point at an
# internal host.
_github_org_repo() {
  local url=$1
  local repo
  case "$url" in
    https://github.com/*)
      repo=${url#https://github.com/}
      ;;
    https://*@github.com/*)
      local userinfo=${url#https://}
      userinfo=${userinfo%%@github.com/*}
      [[ "$userinfo" != */* && "$userinfo" != *\?* && "$userinfo" != *#* && "$userinfo" != *@* ]] || return 1
      repo=${url#https://*@github.com/}
      ;;
    ssh://git@github.com/*)
      repo=${url#ssh://git@github.com/}
      ;;
    git@github.com:*)
      repo=${url#git@github.com:}
      ;;
    *)
      return 1
      ;;
  esac

  repo=${repo%.git}
  repo=${repo%/}
  [[ "$repo" =~ ^[[:alnum:]._-]+/[[:alnum:]._-]+$ ]] || return 1
  printf '%s\n' "$repo"
}

# Add or update a git remote; protects all remotes from silent org/repo overwrites.
ensure_remote() {
  local name=$1 url=$2
  if git remote get-url "$name" >/dev/null 2>&1; then
    local current
    current=$(git remote get-url "$name")
    if [[ "$current" != "$url" ]]; then
      local cur_repo exp_repo
      cur_repo=$(_github_org_repo "$current") \
        || die "Remote ${name} must use a supported github.com URL"
      exp_repo=$(_github_org_repo "$url") \
        || die "Configured URL for remote ${name} must use a supported github.com URL"
      if [[ "$cur_repo" == "$exp_repo" ]]; then
        log "Remote ${name} org/repo matches (${cur_repo}); keeping existing URL"
        return 0
      fi
      if [[ "$FORCE_REMOTE_URLS" != "1" ]]; then
        die "Remote ${name} points at ${cur_repo} but expected ${exp_repo}. Set FORCE_REMOTE_URLS=1 to overwrite, or set the matching URL env var to match your config."
      fi
      log "Rewriting remote ${name} to ${exp_repo}"
      git remote set-url "$name" "$url"
    fi
  else
    git remote add "$name" "$url"
  fi
}

# Die if gh CLI is not on PATH (CI image must provide it).
ensure_gh() {
  command -v gh >/dev/null 2>&1 || die "gh CLI is required but not found in PATH"
}

# Set git user.name and user.email for the bot's commits.
configure_git_identity() {
  git config user.name "$GIT_AUTHOR_NAME"
  git config user.email "$GIT_AUTHOR_EMAIL"
}

# Write GITHUB_TOKEN to a temp file and configure git credential.helper.
setup_credential_helper() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || return 0
  _cred_file=$(mktemp)
  chmod 600 "$_cred_file"
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" >"$_cred_file"
  git config credential.helper "store --file=${_cred_file}"
}

# Read the current upstream version pin from UPSTREAM-VERSION.
current_pin() {
  local pin
  pin=$(tr -d '[:space:]' <UPSTREAM-VERSION)
  [[ -n "$pin" ]] || die "UPSTREAM-VERSION is empty"
  printf '%s\n' "$pin"
}

# Query upstream for the newest vMAJOR.MINOR.PATCH tag beyond the pin.
newest_upstream_tag() {
  local pin=$1 tag newest=""
  while IFS=$'\t' read -r _ ref; do
    tag=${ref#refs/tags/}
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if version_gt "$tag" "$pin"; then
      if [[ -z "$newest" ]] || version_gt "$tag" "$newest"; then
        newest=$tag
      fi
    fi
  done < <(git ls-remote --tags "$UPSTREAM_URL" 'v*' 2>/dev/null)
  printf '%s\n' "$newest"
}

# Return 0 if an open PR already targets the rebase branch for this tag.
open_pr_exists() {
  local tag=$1
  command -v gh >/dev/null 2>&1 || return 1
  [[ -n "${GITHUB_TOKEN:-}" ]] || return 1
  local branch="${tag}-rebase-${REBASE_BRANCH}"
  local count
  count=$(gh pr list --repo "$DEST_ORG_REPO" --state open --head "$branch" \
    --json headRefName --jq 'length') || die "gh pr list failed for branch ${branch}"
  [[ "$count" -gt 0 ]]
}

# Resolve the correct OCP version for a given Go builder image.
_resolve_builder_ocp() {
  local new_go=$1 current_ocp=$2

  command -v oc >/dev/null 2>&1 || return 1

  local all_tags
  all_tags=$(oc get is builder -n ocp \
    -o jsonpath='{.status.tags[*].tag}' 2>/dev/null) || return 1
  [[ -n "$all_tags" ]] || return 1

  # Fast path: same OCP version already has the builder
  # shellcheck disable=SC2086
  if printf '%s\n' $all_tags | grep -qF "rhel-9-golang-${new_go}-openshift-${current_ocp}"; then
    printf '%s\n' "$current_ocp"
    return 0
  fi

  # Fallback: find the highest OCP version that has this Go builder
  local best_ocp
  # shellcheck disable=SC2086
  best_ocp=$(printf '%s\n' $all_tags \
    | sed -n "s/^rhel-9-golang-${new_go}-openshift-\([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p" \
    | sort -V | tail -1)
  if [[ -n "$best_ocp" ]]; then
    printf '%s\n' "$best_ocp"
    return 0
  fi

  return 1
}

_builder_todo=""

# Bump golang builder pins in .ci-operator.yaml and openshift/Dockerfile if needed.
update_golang_builder() {
  local new_go current_go current_ocp
  new_go=$(awk '/^go /{split($2, a, "."); print a[1]"."a[2]}' go.mod)
  [[ -n "$new_go" ]] || { log "WARNING: could not parse go version from go.mod"; return 0; }

  current_go=$(sed -n 's/.*golang-\([0-9]*\.[0-9]*\).*/\1/p' .ci-operator.yaml | head -1)
  current_ocp=$(sed -n 's/.*openshift-\([0-9]*\.[0-9]*\).*/\1/p' .ci-operator.yaml | head -1)
  [[ -n "$current_go" && -n "$current_ocp" ]] \
    || { log "WARNING: could not parse builder tag from .ci-operator.yaml"; return 0; }

  if [[ "$new_go" == "$current_go" ]]; then
    log "Golang version unchanged (${current_go}); no builder update needed"
    return 0
  fi

  local target_ocp
  if target_ocp=$(_resolve_builder_ocp "$new_go" "$current_ocp"); then
    log "Verified builder image: golang-${new_go}-openshift-${target_ocp}"
  else
    log "WARNING: no builder image found for golang-${new_go}; skipping builder bump"
    _builder_todo="Go ${current_go} -> ${new_go} (builder image not found; update \`.ci-operator.yaml\` and \`openshift/Dockerfile\` manually)"
    return 0
  fi

  local old_ci_suffix="release-golang-${current_go}-openshift-${current_ocp}"
  local new_ci_suffix="release-golang-${new_go}-openshift-${target_ocp}"
  local old_builder_suffix="golang-${current_go}-openshift-${current_ocp}"
  local new_builder_suffix="golang-${new_go}-openshift-${target_ocp}"
  log "Updating golang builder: ${old_builder_suffix} -> ${new_builder_suffix}"

  sed -i "s/${old_ci_suffix}/${new_ci_suffix}/" .ci-operator.yaml
  if [[ -f openshift/Dockerfile ]]; then
    sed -i "s/${old_builder_suffix}/${new_builder_suffix}/" openshift/Dockerfile
  fi

  git add .ci-operator.yaml
  git add openshift/Dockerfile 2>/dev/null || true
  if ! git diff --staged --quiet; then
    git commit -m "UPSTREAM: <carry>: updates golang builder from ${old_builder_suffix} to ${new_builder_suffix}"
  fi
}

_collections_ok=1
_requirements_ok=1

# Attempt to update ansible_collections; record pass/fail for PR body.
run_collections_gate() {
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    log "WARNING: no container engine (docker/podman) found; skipping collections update"
    _collections_ok=0
    return 0
  fi
  log "Running make update-collections"
  if ! make -f openshift/Makefile update-collections; then
    log "WARNING: make update-collections failed"
    _collections_ok=0
    return 0
  fi
  if [[ -n "$(git status --porcelain -- openshift/release/ansible/ansible_collections/)" ]]; then
    git add openshift/release/ansible/ansible_collections
    git commit -m "UPSTREAM: <carry>: Update ansible_collections directory"
  else
    log "No changed files in ansible_collections directory"
  fi
}

# Attempt to generate downstream requirements files; record pass/fail for PR body.
run_requirements_gate() {
  if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then
    log "WARNING: no container engine (docker/podman) found; skipping requirements generation"
    _requirements_ok=0
    return 0
  fi
  log "Running make generate-requirements"
  if ! make -f openshift/Makefile generate-requirements; then
    log "WARNING: make generate-requirements failed"
    _requirements_ok=0
    return 0
  fi
  if ! git diff --quiet openshift/; then
    git add openshift/
    git commit -m "UPSTREAM: <carry>: Update downstream requirements"
  else
    log "No changed files in openshift directory"
  fi
}

# Open a PR (or draft if any gate failed) for the rebase branch.
create_pr() {
  local tag=$1 branch=$2 old_pin=$3
  local title body draft_flag=""
  local any_failure=0

  [[ "$_collections_ok" == "1" && "$_requirements_ok" == "1" ]] || any_failure=1

  title="Rebase to ${tag}"
  body=$(cat <<EOF
## Summary
Automated rebase of downstream Ansible Operator Plugins onto upstream \`${tag}\` via \`./openshift/hack/rebase_upstream.sh\`.

- Previous upstream pin: \`${old_pin}\`
- Collections update: $([[ "$_collections_ok" == "1" ]] && echo "passed" || echo "**failed or skipped** — manual follow-up needed")
- Requirements generation: $([[ "$_requirements_ok" == "1" ]] && echo "passed" || echo "**failed or skipped** — manual follow-up needed")

## Manual follow-up
- Review conflict fallout (script prefers upstream on conflicts).
- Add any needed \`UPSTREAM: <carry>:\` commits.
$([[ "$_collections_ok" != "1" ]] && printf '%s\n' "- [ ] **Collections update needed**: Run \`make -f openshift/Makefile update-collections\` and commit the result.")
$([[ "$_requirements_ok" != "1" ]] && printf '%s\n' "- [ ] **Requirements generation needed**: Run \`make -f openshift/Makefile generate-requirements\` and commit the result. See \`openshift/README.md\` for troubleshooting build dependency conflicts.")
$([[ -n "$_builder_todo" ]] && printf '%s\n' "- [ ] **Builder image update needed**: ${_builder_todo}")
- Verify \`openshift/release/ansible/ansible_collections\` is in sync with \`testdata/memcached-molecule-operator/requirements.yml\`.
- Verify requirements files are referenced in the image build config at \`openshift-eng/ocp-build-data\`.
- Do **not** auto-merge until CI is green.

## Test plan
- [ ] CI presubmits pass
- [ ] \`make -f openshift/Makefile check-collections\`
- [ ] \`make -f openshift/Makefile check-requirements\`
- [ ] Request ART test build to verify python build dependencies
EOF
)
  if [[ "$any_failure" == "1" ]]; then
    gh pr create --repo "$DEST_ORG_REPO" --base "$REBASE_BRANCH" --head "$branch" \
      --title "WIP: ${title}" --body "$body" --draft \
      || die "Failed to create draft PR for ${branch}"
  else
    gh pr create --repo "$DEST_ORG_REPO" --base "$REBASE_BRANCH" --head "$branch" \
      --title "$title" --body "$body" \
      || die "Failed to create PR for ${branch}"
  fi
}

# Orchestrate: discover tag, merge, gate, push, PR.
main() {
  local pin tag branch

  _github_org_repo "$UPSTREAM_URL" >/dev/null \
    || die "UPSTREAM_URL must use a supported github.com URL"
  _github_org_repo "$ORIGIN_URL" >/dev/null \
    || die "ORIGIN_URL must use a supported github.com URL"

  log "Fetching upstream tags"
  git fetch -t "$UPSTREAM_URL" 2>/dev/null || die "Failed to fetch upstream tags"

  pin=$(current_pin)
  if [[ -n "${OVERRIDE_TAG:-}" ]]; then
    tag=$OVERRIDE_TAG
    log "OVERRIDE_TAG set: ${tag}"
  else
    tag=$(newest_upstream_tag "$pin")
  fi

  if [[ -z "$tag" ]]; then
    log "No newer upstream release tag than ${pin}; nothing to do"
    exit 0
  fi

  if ! version_gt "$tag" "$pin" && [[ -z "${OVERRIDE_TAG:-}" ]]; then
    log "Selected tag ${tag} is not newer than pin ${pin}; nothing to do"
    exit 0
  fi

  branch="${tag}-rebase-${REBASE_BRANCH}"
  log "Candidate rebase: ${pin} -> ${tag} (branch ${branch})"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1: would run ./openshift/hack/rebase_upstream.sh ${tag} ${REBASE_BRANCH} ${UPSTREAM_REMOTE}"
    exit 0
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    die "Working tree must be clean (including untracked files) before mutating"
  fi

  ensure_remote "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  ensure_remote "$ORIGIN_REMOTE" "$ORIGIN_URL"

  if ! git fetch "$ORIGIN_REMOTE" "$REBASE_BRANCH" 2>/dev/null \
    && ! git fetch "$ORIGIN_REMOTE" 2>/dev/null; then
    die "Failed to fetch ${ORIGIN_REMOTE}/${REBASE_BRANCH}"
  fi

  [[ -n "${GITHUB_TOKEN:-}" ]] || log "WARNING: no GITHUB_TOKEN; push/PR may fail"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    ensure_gh
    export GH_TOKEN="$GITHUB_TOKEN"
    if open_pr_exists "$tag"; then
      log "Open PR for ${tag} already exists; skipping"
      exit 0
    fi
  fi

  configure_git_identity
  setup_credential_helper

  if ! is_ci_context && git show-ref --verify --quiet "refs/heads/${REBASE_BRANCH}"; then
    if ! git merge-base --is-ancestor "$REBASE_BRANCH" "$ORIGIN_REMOTE/$REBASE_BRANCH"; then
      die "Local branch ${REBASE_BRANCH} contains commits not in ${ORIGIN_REMOTE}/${REBASE_BRANCH}; refusing to discard them outside CI"
    fi
  fi

  git checkout -B "$REBASE_BRANCH" "$ORIGIN_REMOTE/$REBASE_BRANCH"
  git branch --set-upstream-to="$ORIGIN_REMOTE/$REBASE_BRANCH" "$REBASE_BRANCH"

  if is_ci_context; then
    export ALLOW_BRANCH_DELETE=1
  fi

  cleanup_stale_branch "$branch"

  trap 'log "FAILED (rc=$?) on branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"' ERR

  log "Running rebase_upstream.sh ${tag} ${REBASE_BRANCH} ${UPSTREAM_REMOTE}"
  SKIP_GENERATION=1 ./openshift/hack/rebase_upstream.sh "$tag" "$REBASE_BRANCH" "$UPSTREAM_REMOTE"

  update_golang_builder

  run_collections_gate
  run_requirements_gate

  [[ -n "${GITHUB_TOKEN:-}" ]] || die "GITHUB_TOKEN required to push and open PR"

  log "Pushing ${branch}"
  git push --force -u "$ORIGIN_REMOTE" "$branch" 2>/dev/null \
    || die "Failed to push ${branch}"

  log "Opening pull request"
  create_pr "$tag" "$branch" "$pin"

  if [[ "$_collections_ok" != "1" || "$_requirements_ok" != "1" ]]; then
    die "One or more gates failed; draft PR opened for manual fixes"
  fi
  log "Auto-rebase complete for ${tag}"
}

main "$@"
