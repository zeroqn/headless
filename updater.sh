#!/usr/bin/env bash

set -euo pipefail

manifest_path="${1:-release-assets.json}"
repo="${GITHUB_REPO:-zeroqn/headless}"
release_tag="${RELEASE_TAG:-main-build}"
api_url="${GITHUB_API_URL:-https://api.github.com}"
rio_revision="${RIO_REVISION:-d656326020ffe5959e221af7a7d1d8d82a6ab2db}"
rio_version="${RIO_VERSION:-0.4.12-${rio_revision:0:7}}"

owner="${repo%%/*}"
repo_name="${repo#*/}"
if [[ "$owner" == "$repo_name" ]]; then
  echo "GITHUB_REPO must use the owner/repository form" >&2
  exit 1
fi

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

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

collect_assets() {
  local package="$1"
  local prefix="$2"
  local output="$workdir/${package}-assets.json"
  local assets_json

  assets_json="$(
    jq --arg prefix "$prefix" '
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
    echo "No ${package} release assets were found for ${repo}@${release_tag}" >&2
    exit 1
  fi

  printf '[]\n' >"$output"
  while IFS=$'\t' read -r system name url; do
    local download_path="$workdir/$name"
    local hash

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
      "$output" >"$output.next"
    mv "$output.next" "$output"
  done < <(jq --raw-output '.[] | [.system, .name, .url] | @tsv' <<<"$assets_json")
}

collect_assets niri "niri-headless-main-"
collect_assets rio "rio-${rio_revision:0:7}-"

short_commit="$(
  jq --raw-output '(.target_commitish // .tag_name // "unknown")[:12]' <<<"$release_json"
)"

jq -n \
  --arg owner "$owner" \
  --arg repo "$repo_name" \
  --arg tag "$release_tag" \
  --arg niri_version "${release_tag}-${short_commit}" \
  --arg niri_revision "$short_commit" \
  --arg rio_version "$rio_version" \
  --arg rio_revision "$rio_revision" \
  --slurpfile niri_assets "$workdir/niri-assets.json" \
  --slurpfile rio_assets "$workdir/rio-assets.json" \
  '{
    owner: $owner,
    repo: $repo,
    release: {tag: $tag},
    packages: {
      niri: {
        version: $niri_version,
        revision: $niri_revision,
        assets: ($niri_assets[0] | from_entries)
      },
      rio: {
        version: $rio_version,
        revision: $rio_revision,
        assets: ($rio_assets[0] | from_entries)
      }
    }
  }' \
  >"$manifest_path"

echo "Updated ${manifest_path} for ${repo}@${release_tag}"
