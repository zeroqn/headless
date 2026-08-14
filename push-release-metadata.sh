#!/usr/bin/env bash
# Commit generated release metadata and push it to main, integrating any
# concurrent pushes (e.g. build-mesa.yml racing build-release.yml) with a
# fetch + rebase + retry loop instead of failing on "fetch first".
#
# Usage: push-release-metadata.sh <commit-message> <file>...
# Env:   UPDATE_RELEASE_ASSETS_CMD  command that (re)generates
#                                    release-assets.json from the current
#                                    release state
#                                    (default: nix run .#update-release-assets)

set -euo pipefail

commit_message="${1:?usage: push-release-metadata.sh <commit-message> [files...]}"
shift
files=("$@")

update_cmd="${UPDATE_RELEASE_ASSETS_CMD:-nix run .#update-release-assets}"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# Regenerate the manifest, then commit only if it actually changed. Local
# commits made earlier in the job (e.g. a Mesa version bump) are pushed too.
$update_cmd
git add "${files[@]}"
if ! git diff --cached --quiet; then
  git commit -m "$commit_message"
fi

for attempt in $(seq 1 5); do
  if git push origin HEAD:main; then
    exit 0
  fi
  echo "push rejected (attempt ${attempt}/5); integrating updated main" >&2
  # CI checkouts are shallow (actions/checkout fetch-depth: 1); deepen so a
  # merge base exists for the rebase.
  git fetch --unshallow origin 2>/dev/null || git fetch origin
  if ! git rebase origin/main; then
    # A concurrent metadata commit (Mesa vs the rest) rewrote the same
    # manifest; regenerate the merged file on the new base and resume.
    echo "rebase conflict; regenerating release-assets.json on the new base" >&2
    git checkout --ours release-assets.json
    $update_cmd
    git add release-assets.json
    GIT_EDITOR=true git rebase --continue
  fi
  sleep 5
done

echo "failed to push metadata after 5 attempts" >&2
exit 1
