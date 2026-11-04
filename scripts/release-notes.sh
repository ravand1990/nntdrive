#!/usr/bin/env bash
# Print the CHANGELOG section for a release tag, e.g. v0.1.0.
#
# Fails (exit 1) when there is no section or no Features/Bug fixes bullets, so
# the release workflow cannot publish an undocumented release.
set -euo pipefail

tag="${1:-}"
if [[ -z "$tag" ]]; then
  echo "usage: $0 <tag> (e.g. v0.1.1)" >&2
  exit 2
fi
version="${tag#v}"
file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CHANGELOG.md"

if [[ ! -f "$file" ]]; then
  echo "CHANGELOG.md not found" >&2
  exit 1
fi

body="$(awk -v version="$version" '
  $0 ~ "^## \\[" version "\\]" { found=1; next }
  found && /^## \[/ { exit }
  found { print }
' "$file")"

if [[ -z "${body//[[:space:]]/}" ]]; then
  echo "No CHANGELOG.md section for version $version." >&2
  echo "Add a '## [$version] - YYYY-MM-DD' section with '### Features' and/or '### Bug fixes'." >&2
  exit 1
fi

if ! grep -qE '^### (Features|Bug fixes)' <<<"$body"; then
  echo "CHANGELOG section $version has no '### Features' or '### Bug fixes' heading." >&2
  exit 1
fi

if ! grep -qE '^- ' <<<"$body"; then
  echo "CHANGELOG section $version has no bullet points." >&2
  exit 1
fi

printf '%s\n' "$body"
