#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

if [ -z "$NPM_TOKEN" ]; then
  echo "You must set the NPM_TOKEN environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}

TEMPLATE=fireworks

set -euo pipefail
set -x

npm config set '//registry.npmjs.org/:_authToken' "$NPM_TOKEN"

is_truthy() {
  case "$1" in
    true|1) return 0 ;;
    false|0) return 1 ;;
    *) return 1 ;;
  esac
}

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.12
source .venv/bin/activate

uv pip install twine

npm install -g yarn

REPOS=(stack-client-python stack-client-typescript stack)
if is_truthy "$LLAMA_STACK_ONLY"; then
  REPOS=(stack)
fi

for repo in "${REPOS[@]}"; do
  git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
  cd llama-$repo

  echo "Building package..."
  git fetch origin "rc-$VERSION":"rc-$VERSION"
  git checkout "rc-$VERSION"

  if [ "$repo" == "stack-client-typescript" ]; then
    NPM_VERSION=$(cat package.json | jq -r '.version')
    echo "version to build: $NPM_VERSION"

    npx yarn install
    npx yarn build
  else
    PYPROJECT_VERSION=$(cat pyproject.toml | grep version)
    echo "version to build: $PYPROJECT_VERSION"

    uv build -q
    uv pip install dist/*.whl
  fi

  # tag the commit on the branch because merging it back to main could move things
  # beyond the cut-point (main could have been updated since the cut)
  echo "Tagging llama-$repo at version $VERSION (not pushing yet)"
  git tag -a "v$VERSION" -m "Release version $VERSION"

  if [ "$repo" == "stack-client-typescript" ]; then
    echo "Uploading llama-$repo to npm"
    cd dist
    npx yarn publish --access public --tag rc-$VERSION --registry https://registry.npmjs.org/
    cd ..
  else
    echo "Uploading llama-$repo to testpypi"
    python -m twine upload \
      --repository-url https://test.pypi.org/legacy/ \
      --skip-existing \
      dist/*.whl dist/*.tar.gz
  fi

  echo "Pushing tag for llama-$repo"
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "v$VERSION"

  cd ..
done
