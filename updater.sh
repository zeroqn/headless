#!/usr/bin/env bash

set -euo pipefail

manifest_path="${1:-release-assets.json}"
repo="${GITHUB_REPO:-zeroqn/headless}"
release_tag="${RELEASE_TAG:-main-build}"
api_url="${GITHUB_API_URL:-https://api.github.com}"
publish_groups="${PUBLISH_GROUPS:-niri-rio,sunshine,moonlight,waypipe,mesa}"
rio_revision="${RIO_REVISION:-d656326020ffe5959e221af7a7d1d8d82a6ab2db}"
rio_version="${RIO_VERSION:-0.4.12-${rio_revision:0:7}}"
sunshine_revision="${SUNSHINE_REVISION:-9d2409f71b60f1812f482e6dd807dc52e2f72fe7}"
sunshine_version="${SUNSHINE_VERSION:-2026.07.15.vulkan}"
moonlight_revision="${MOONLIGHT_REVISION:-2e13ed9977bc31c73caf8428f08f58d793313ece}"
waypipe_revision="${WAYPIPE_REVISION:-1ac039b4d50e2658d284e750c182266cc00efe74}"
waypipe_version="${WAYPIPE_VERSION:-0.11.0-unstable-2026-06-17}"
mesa_revision="${MESA_REVISION:-mesa-26.1.5}"
mesa_version="${MESA_VERSION:-26.1.5}"

owner="${repo%%/*}"
repo_name="${repo#*/}"
if [[ "$owner" == "$repo_name" ]]; then
  echo "GITHUB_REPO must use the owner/repository form" >&2
  exit 1
fi

has_group() {
  [[ ",${publish_groups}," == *",$1,"* ]]
}

if ! has_group niri-rio && ! has_group sunshine && ! has_group moonlight && ! has_group waypipe && ! has_group mesa; then
  echo "PUBLISH_GROUPS must include niri-rio, sunshine, moonlight, waypipe, mesa, or a comma-separated combination" >&2
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

if [[ -f "$manifest_path" ]]; then
  cp "$manifest_path" "$workdir/manifest.json"
else
  jq -n \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    '{owner: $owner, repo: $repo, release: {tag: $tag}, packages: {}}' \
    >"$workdir/manifest.json"
fi

collect_assets() {
  local package="$1"
  local prefix="$2"
  local exclude_prefix="${3:-}"
  local output="$workdir/${package}-assets.json"
  local assets_json

  assets_json="$(
    jq \
      --arg prefix "$prefix" \
      --arg exclude_prefix "$exclude_prefix" '
        [.assets[]
         | select(.name | startswith($prefix))
         | select($exclude_prefix == "" or (.name | startswith($exclude_prefix) | not))
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

short_commit="$(
  jq --raw-output '(.target_commitish // .tag_name // "unknown")[:12]' <<<"$release_json"
)"

if has_group niri-rio; then
  collect_assets niri "niri-headless-main-"
  collect_assets rio "rio-${rio_revision:0:7}-"

  jq \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    --arg niri_version "${release_tag}-${short_commit}" \
    --arg niri_revision "$short_commit" \
    --arg rio_version "$rio_version" \
    --arg rio_revision "$rio_revision" \
    --slurpfile niri_assets "$workdir/niri-assets.json" \
    --slurpfile rio_assets "$workdir/rio-assets.json" '
      .owner = $owner
      | .repo = $repo
      | .release.tag = $tag
      | .packages.niri = {
          version: $niri_version,
          revision: $niri_revision,
          assets: ($niri_assets[0] | from_entries)
        }
      | .packages.rio = {
          version: $rio_version,
          revision: $rio_revision,
          assets: ($rio_assets[0] | from_entries)
        }
    ' "$workdir/manifest.json" >"$workdir/manifest.next.json"
  mv "$workdir/manifest.next.json" "$workdir/manifest.json"
fi

if has_group sunshine; then
  collect_assets sunshine "sunshine-main-" "sunshine-main-cuda-"
  collect_assets sunshine-cuda "sunshine-main-cuda-"

  jq \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    --arg version "$sunshine_version" \
    --arg revision "$sunshine_revision" \
    --slurpfile sunshine_assets "$workdir/sunshine-assets.json" \
    --slurpfile sunshine_cuda_assets "$workdir/sunshine-cuda-assets.json" '
      .owner = $owner
      | .repo = $repo
      | .release.tag = $tag
      | .packages.sunshine = {
          version: $version,
          revision: $revision,
          assets: ($sunshine_assets[0] | from_entries)
        }
      | .packages["sunshine-cuda"] = {
          version: $version,
          revision: $revision,
          assets: ($sunshine_cuda_assets[0] | from_entries)
        }
    ' "$workdir/manifest.json" >"$workdir/manifest.next.json"
  mv "$workdir/manifest.next.json" "$workdir/manifest.json"
fi

if has_group moonlight; then
  collect_assets moonlight "moonlight-qt-main-"

  jq \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    --arg version "${release_tag}-${short_commit}" \
    --arg revision "$moonlight_revision" \
    --slurpfile moonlight_assets "$workdir/moonlight-assets.json" '
      .owner = $owner
      | .repo = $repo
      | .release.tag = $tag
      | .packages.moonlight = {
          version: $version,
          revision: $revision,
          assets: ($moonlight_assets[0] | from_entries)
        }
    ' "$workdir/manifest.json" >"$workdir/manifest.next.json"
  mv "$workdir/manifest.next.json" "$workdir/manifest.json"
fi

if has_group waypipe; then
  collect_assets waypipe "waypipe-${waypipe_revision:0:8}-"

  jq \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    --arg version "$waypipe_version" \
    --arg revision "$waypipe_revision" \
    --slurpfile waypipe_assets "$workdir/waypipe-assets.json" '
      .owner = $owner
      | .repo = $repo
      | .release.tag = $tag
      | .packages.waypipe = {
          version: $version,
          revision: $revision,
          assets: ($waypipe_assets[0] | from_entries)
        }
    ' "$workdir/manifest.json" >"$workdir/manifest.next.json"
  mv "$workdir/manifest.next.json" "$workdir/manifest.json"
fi

if has_group mesa; then
  collect_assets mesa "mesa-${mesa_version}-"

  jq \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg tag "$release_tag" \
    --arg version "$mesa_version" \
    --arg revision "$mesa_revision" \
    --slurpfile mesa_assets "$workdir/mesa-assets.json" '
      .owner = $owner
      | .repo = $repo
      | .release.tag = $tag
      | .packages.mesa = {
          version: $version,
          revision: $revision,
          assets: ($mesa_assets[0] | from_entries)
        }
    ' "$workdir/manifest.json" >"$workdir/manifest.next.json"
  mv "$workdir/manifest.next.json" "$workdir/manifest.json"
fi

mv "$workdir/manifest.json" "$manifest_path"
echo "Updated ${manifest_path} for ${repo}@${release_tag}: ${publish_groups}"
