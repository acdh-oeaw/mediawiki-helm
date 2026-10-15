#!/usr/bin/env bash
set -euo pipefail
version="$(helm show chart chart/mediawiki | awk '$1 == "version:" {print $2}')"
tag="mediawiki-${version}"
# Refuse overwriting versions. Increase Chart.yaml version for each release.
if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Release $tag already exists. Increase chart version." >&2
  exit 1
fi
mkdir -p .packages
helm package chart/mediawiki -d .packages
pages_dir="$(mktemp -d)"
trap 'git worktree remove --force "$pages_dir" 2>/dev/null || true' EXIT
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git ls-remote --exit-code --heads origin gh-pages >/dev/null; then
  git fetch origin gh-pages
  git worktree add --detach "$pages_dir" FETCH_HEAD
else
  git worktree add --detach "$pages_dir" HEAD
  (cd "$pages_dir" && git switch --orphan chart-pages && git rm -rf --ignore-unmatch .)
fi
if [[ -f "$pages_dir/index.yaml" ]] && grep -q "version: ${version}$" "$pages_dir/index.yaml"; then
  echo "Chart version already exists in index; refusing overwrite" >&2
  exit 1
fi
release_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}"
if [[ -f "$pages_dir/index.yaml" ]]; then
  helm repo index .packages --url "$release_url" --merge "$pages_dir/index.yaml"
else
  helm repo index .packages --url "$release_url"
fi
gh release create "$tag" ".packages/mediawiki-${version}.tgz"   --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA"   --title "MediaWiki chart ${version}" --notes "MediaWiki Helm chart ${version}. See repository migration instructions."
cp .packages/index.yaml "$pages_dir/index.yaml"
cp index.html "$pages_dir/index.html"
touch "$pages_dir/.nojekyll"
git -C "$pages_dir" add index.yaml index.html .nojekyll
git -C "$pages_dir" commit -m "Publish MediaWiki chart ${version}"
git -C "$pages_dir" push origin HEAD:gh-pages
