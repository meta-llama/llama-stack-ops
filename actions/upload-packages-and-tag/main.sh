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
  git clone --depth 1 --branch "rc-$VERSION" "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
  cd llama-$repo

  echo "Building package..."
  uv build -q
  uv pip install dist/*.whl

  echo "Merging rc-$VERSION into main"
  git checkout -b main origin/main
  git merge --ff-only "rc-$VERSION"
  echo "Tagging llama-$repo at version $VERSION"
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
