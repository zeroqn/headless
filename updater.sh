#!/usr/bin/env bash

set -euo pipefail

manifest_path="${1:-release-assets.json}"
repo="${GITHUB_REPO:-zeroqn/headless}"
release_tag="${RELEASE_TAG:-main-build}"
api_url="${GITHUB_API_URL:-https://api.github.com}"
asset_prefix="${ASSET_PREFIX:-niri-headless-main-}"
owner="${repo%%/*}"
repo_name="${repo#*/}"
headers=(
  --header "Accept: application/vnd.github+json"
  --header "X-GitHub-Api-Version: 2022-11-28"
)

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  headers+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

release_json="$(
  curl \
    --silent \
    --show-error \
    --fail \
    --location \
    "${headers[@]}" \
    "${api_url%/}/repos/${repo}/releases/tags/${release_tag}"
)"

assets_json="$(
  jq --arg prefix "$asset_prefix" '
    [.assets[]
     | select(.name | startswith($prefix))
     | select(.name | endswith(".tar.gz"))
     | {
         name,
         url: .browser_download_url,
         system: (.name | sub("^" + $prefix; "") | sub("\\.tar\\.gz$"; ""))
       }]
  ' <<<"$release_json"
)"

if [[ "$(jq 'length' <<<"$assets_json")" -eq 0 ]]; then
  echo "No release assets matching ${asset_prefix}*.tar.gz were found for ${repo}@${release_tag}" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
printf '[]\n' >"$workdir/assets.json"

while IFS=$'\t' read -r system name url; do
  download_path="$workdir/$name"
  curl \
    --silent \
    --show-error \
    --fail \
    --location \
    "${headers[@]}" \
    --output "$download_path" \
    "$url"
  hash="$(nix hash file --type sha256 --sri "$download_path")"
  jq \
    --arg system "$system" \
    --arg name "$name" \
    --arg url "$url" \
    --arg hash "$hash" \
    '. + [{key: $system, value: {name: $name, url: $url, hash: $hash}}]' \
    "$workdir/assets.json" >"$workdir/assets.next.json"
  mv "$workdir/assets.next.json" "$workdir/assets.json"
done < <(jq --raw-output '.[] | [.system, .name, .url] | @tsv' <<<"$assets_json")

short_commit="$(
  jq --raw-output '(.target_commitish // .tag_name // "unknown")[:12]' <<<"$release_json"
)"

jq -n \
  --arg owner "$owner" \
  --arg repo "$repo_name" \
  --arg tag "$release_tag" \
  --arg version "${release_tag}-${short_commit}" \
  --slurpfile assets "$workdir/assets.json" \
  '{owner: $owner, repo: $repo, release: {tag: $tag, version: $version}, assets: ($assets[0] | from_entries)}' \
  >"$manifest_path"

echo "Updated ${manifest_path} for ${repo}@${release_tag}"
