#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}

TEMPLATE=fireworks

set -euo pipefail
set -x

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.10
source .venv/bin/activate

uv pip install twine

REPOS=(models stack-client-python stack)
for repo in "${REPOS[@]}"; do
  git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
  cd llama-$repo

  echo "Building package..."
  git fetch origin "rc-$VERSION":"rc-$VERSION"
  git checkout "rc-$VERSION"

  PYPROJECT_VERSION=$(cat pyproject.toml | grep version)
  echo "version to build: $PYPROJECT_VERSION"

  uv build -q
  uv pip install dist/*.whl

  # tag the commit on the branch because merging it back to main could move things
  # beyond the cut-point (main could have been updated since the cut)
  echo "Tagging llama-$repo at version $VERSION (not pushing yet)"
  git tag -a "v$VERSION" -m "Release version $VERSION"

  echo "Uploading llama-$repo to testpypi"
  python -m twine upload \
    --repository-url https://test.pypi.org/legacy/ \
    --skip-existing \
    dist/*.whl dist/*.tar.gz

  echo "Pushing tag for llama-$repo"
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "v$VERSION"

  cd ..
done
