#!/usr/bin/env bash
# Race test for push-release-metadata.sh.
#
# Simulates build-release.yml and build-mesa.yml committing metadata to the
# shared release-assets.json on main at the same time, and verifies that the
# helper integrates the concurrent push (fetch + rebase + retry) instead of
# failing with "fetch first".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/push-release-metadata.sh"
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# Stub updater: sets one package's hash in release-assets.json, like
# updater.sh does for a single publication group. $1=path $2=package $3=hash
make_stub() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
set -euo pipefail
tmp="\$(mktemp)"; trap 'rm -f "\$tmp"' EXIT
jq --arg p "$2" --arg h "$3" \
  '.packages[\$p] = {version: "1.0", revision: "abc", assets: {x86_64_linux: {name: "p.tar.gz", url: "https://example.invalid/p.tar.gz", hash: \$h}}}' \
  release-assets.json >"\$tmp"
mv "\$tmp" release-assets.json
EOF
  chmod +x "$1"
}

# Seed origin with a release-assets.json already holding both groups, then
# clone it for the two "workflows". $1=base dir, $2=full|shallow (clone depth)
new_world() {
  local base="$1" depth="${2:-full}"
  ORIGIN="$base/origin.git"
  A="$base/repo-a"
  B="$base/repo-b"
  git init --bare -q "$ORIGIN"
  local seed="$base/seed"
  mkdir -p "$seed"
  git -C "$seed" init -q
  git -C "$seed" config user.name seed
  git -C "$seed" config user.email seed@example.com
  git -C "$seed" remote add origin "$ORIGIN"
  cat >"$seed/release-assets.json" <<'EOF'
{
  "owner": "zeroqn",
  "repo": "headless",
  "release": { "tag": "main-build" },
  "packages": {
    "sunshine": { "version": "1.0", "revision": "abc", "assets": { "x86_64_linux": { "name": "s.tar.gz", "url": "https://example.invalid/s.tar.gz", "hash": "old-b" } } },
    "mesa": { "version": "1.0", "revision": "abc", "assets": { "x86_64_linux": { "name": "m.tar.gz", "url": "https://example.invalid/m.tar.gz", "hash": "old-a" } } }
  }
}
EOF
  git -C "$seed" add release-assets.json
  git -C "$seed" commit -qm init
  git -C "$seed" push -q origin HEAD:main
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  for r in "$A" "$B"; do
    if [[ "$depth" == full ]]; then
      git clone -q "$ORIGIN" "$r"
    else
      git clone -q --depth 1 "file://$ORIGIN" "$r"
    fi
    git -C "$r" config user.name test
    git -C "$r" config user.email test@example.com
  done
}

# Simulate one workflow's metadata commit + push. $1=repo dir, $2=stub, $3=message
publish() {
  local r="$1" stub="$2" msg="$3"
  (cd "$r" && "$stub")
  git -C "$r" add release-assets.json
  git -C "$r" commit -qm "$msg"
  git -C "$r" push -q origin HEAD:main
}

# Clone origin and assert the merged manifest. $1=base dir, $2=jq expr, $3=label
check_merged() {
  local base="$1" expr="$2" label="$3"
  local check="$base/check"
  git clone -q "$ORIGIN" "$check"
  if ! jq -e "$expr" "$check/release-assets.json" >/dev/null; then
    fail "$label: expected $expr, got $(cat "$check/release-assets.json")"
  fi
  if grep -q '<<<<<<<' "$check/release-assets.json"; then
    fail "$label: conflict markers in release-assets.json"
  fi
  pass "$label"
}

echo "scenario 1: disjoint groups, concurrent push rebased and merged"
new_world "$WORK_ROOT/s1"
make_stub "$WORK_ROOT/s1/stub-b.sh" sunshine hash-b
make_stub "$WORK_ROOT/s1/stub-a.sh" mesa hash-a
publish "$B" "$WORK_ROOT/s1/stub-b.sh" "sunshine metadata"
(cd "$A" && UPDATE_RELEASE_ASSETS_CMD="$WORK_ROOT/s1/stub-a.sh" \
  bash "$HELPER" "chore: mesa metadata" release-assets.json)
check_merged "$WORK_ROOT/s1" \
  '.packages.sunshine.assets.x86_64_linux.hash == "hash-b" and .packages.mesa.assets.x86_64_linux.hash == "hash-a"' \
  "scenario 1"

echo "scenario 2: same group changed by both, regenerated on the new base"
new_world "$WORK_ROOT/s2"
make_stub "$WORK_ROOT/s2/stub-b.sh" sunshine hash-b
make_stub "$WORK_ROOT/s2/stub-a.sh" sunshine hash-a
publish "$B" "$WORK_ROOT/s2/stub-b.sh" "sunshine metadata"
(cd "$A" && UPDATE_RELEASE_ASSETS_CMD="$WORK_ROOT/s2/stub-a.sh" \
  bash "$HELPER" "chore: sunshine metadata" release-assets.json)
check_merged "$WORK_ROOT/s2" '.packages.sunshine.assets.x86_64_linux.hash == "hash-a"' "scenario 2"

echo "scenario 3: metadata unchanged, local commit still pushed"
new_world "$WORK_ROOT/s3"
make_stub "$WORK_ROOT/s3/stub-b.sh" sunshine hash-b
publish "$B" "$WORK_ROOT/s3/stub-b.sh" "sunshine metadata"
printf '%s\n' '{"lock": "bumped"}' >"$A/flake.lock"
git -C "$A" add flake.lock
git -C "$A" commit -qm "feat: bump pinned version"
(cd "$A" && UPDATE_RELEASE_ASSETS_CMD=true \
  bash "$HELPER" "chore: metadata" release-assets.json)
if ! git -C "$A" show HEAD:flake.lock | grep -q bumped; then
  fail "scenario 3: local commit was not pushed"
fi
pass "scenario 3"

echo "scenario 4: shallow checkout (actions/checkout fetch-depth 1) rebases cleanly"
new_world "$WORK_ROOT/s4" shallow
if [[ "$(git -C "$A" rev-parse --is-shallow-repository)" != true ]]; then
  fail "scenario 4: clone was not shallow; test setup broken"
fi
make_stub "$WORK_ROOT/s4/stub-b.sh" sunshine hash-b
make_stub "$WORK_ROOT/s4/stub-a.sh" mesa hash-a
publish "$B" "$WORK_ROOT/s4/stub-b.sh" "sunshine metadata"
(cd "$A" && UPDATE_RELEASE_ASSETS_CMD="$WORK_ROOT/s4/stub-a.sh" \
  bash "$HELPER" "chore: mesa metadata" release-assets.json)
check_merged "$WORK_ROOT/s4" \
  '.packages.sunshine.assets.x86_64_linux.hash == "hash-b" and .packages.mesa.assets.x86_64_linux.hash == "hash-a"' \
  "scenario 4"

echo "all scenarios passed"
