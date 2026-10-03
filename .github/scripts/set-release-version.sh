#!/usr/bin/env bash
# Set the package version from a release tag (v1.2.3 or 1.2.3) in mix.exs and
# verify that Mix reads it back. The manifest in git is not bumped by hand: the
# git tag is the source of truth for the published version.
set -euo pipefail

tag="${1:-${RELEASE_TAG:-}}"
if [[ -z "$tag" ]]; then
  echo "Usage: set-release-version.sh <tag> (or set RELEASE_TAG)" >&2
  exit 1
fi

version="${tag#v}"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'
if ! [[ "$version" =~ $semver ]]; then
  echo "Release tag must use 1.2.3 or v1.2.3, with an optional prerelease suffix." >&2
  exit 1
fi

# mix.exs: replace the single `@version "..."` module attribute.
awk -v version="$version" '
  !done && /^  @version "[^"]*"[[:space:]]*$/ {
    print "  @version \"" version "\""
    done = 1
    next
  }
  { print }
  END { if (!done) exit 1 }
' mix.exs > mix.exs.new || { echo "No @version attribute found in mix.exs." >&2; rm -f mix.exs.new; exit 1; }
mv mix.exs.new mix.exs

# Verify that Mix reads the requested version.
mix_version="$(mix run --no-compile --no-start --no-deps-check -e 'IO.puts(Mix.Project.config()[:version])' | tail -n 1)"
if [[ "$mix_version" != "$version" ]]; then
  echo "Mix reports version ${mix_version}, expected ${version}." >&2
  exit 1
fi

echo "Package version set to ${version}."
