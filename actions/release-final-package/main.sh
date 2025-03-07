#!/bin/bash

if [ -z "$RELEASE_VERSION" ]; then
  echo "You must set the RELEASE_VERSION environment variable" >&2
  exit 1
fi

if [ -z "$RC_VERSION" ]; then
  echo "You must set the RC_VERSION environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}
DRY_RUN=${DRY_RUN:-false}

set -euo pipefail

is_truthy() {
  case "$1" in
    true|1) return 0 ;;
    false|0) return 1 ;;
    *) return 1 ;;
  esac
}

# Yell if RELEASE is already on pypi
version_tag=$(curl -s https://pypi.org/pypi/llama-stack/json | jq -r '.info.version')
if [ x"$version_tag" = x"$RELEASE_VERSION" ]; then
  echo "RELEASE_VERSION $RELEASE_VERSION is already on pypi" >&2
  exit 1
fi

# OTOH, if the RC is _not_ on test.pypi, we should yell
# we should look at all releases, not the latest
version_tags=$(curl -s https://test.pypi.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
found_rc=0
for version_tag in $version_tags; do
  if [ x"$version_tag" = x"$RC_VERSION" ]; then
    found_rc=1
    break
  fi
done

if [ $found_rc -eq 0 ]; then
  echo "RC_VERSION $RC_VERSION not found on test.pypi" >&2
  exit 1
fi


REPOS=(stack-client-python stack)
if is_truthy "$LLAMA_STACK_ONLY"; then
  REPOS=(stack)
fi

# check that tag v$RC_VERSION exists for all repos. each repo is remote
# github.com/meta-llama/llama-$repo.git
for repo in "${REPOS[@]}"; do
  if ! git ls-remote --tags https://github.com/meta-llama/llama-$repo.git "refs/tags/v$RC_VERSION" | grep -q .; then
    echo "Tag v$RC_VERSION does not exist for $repo" >&2
    exit 1
  fi
done

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.10
source .venv/bin/activate

uv pip install twine

add_bump_version_commit() {
  local repo=$1
  local version=$2

  # TODO: this is dangerous use uvx toml-cli toml set project.version $RELEASE_VERSION instead of this
  # cringe perl code
  perl -pi -e "s/version = .*$/version = \"$version\"/" pyproject.toml

  if ! is_truthy "$LLAMA_STACK_ONLY"; then
    perl -pi -e "s/llama-stack-client>=.*,/llama-stack-client>=$RELEASE_VERSION\",/" pyproject.toml

    if [ -f "src/llama_stack_client/_version.py" ]; then
      perl -pi -e "s/__version__ = .*$/__version__ = \"$version\"/" src/llama_stack_client/_version.py
    fi
  fi

  uv export --frozen --no-hashes --no-emit-project --output-file=requirements.txt
  git commit -a -m "Bump version to $version"
}

for repo in "${REPOS[@]}"; do
  git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
  cd llama-$repo
  git fetch origin refs/tags/v${RC_VERSION}:refs/tags/v${RC_VERSION}
  git checkout -b release-$RELEASE_VERSION refs/tags/v${RC_VERSION}

  add_bump_version_commit $repo $RELEASE_VERSION

  git tag -a "v$RELEASE_VERSION" -m "Release version $RELEASE_VERSION"

  uv build -q
  uv pip install dist/*.whl
  cd ..
done

# TODO: This is too slow right now; skipping for now
#
# git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-stack-apps.git"
# cd llama-stack-apps
# perl -pi -e "s/llama-stack>=.*/llama-stack>=$RELEASE_VERSION/" requirements.txt
# perl -pi -e "s/llama-stack-client.*/llama-stack-client>=$RELEASE_VERSION/" requirements.txt
# git commit -a -m "Bump version to $RELEASE_VERSION"
# git tag -a "v$RELEASE_VERSION" -m "Release version $RELEASE_VERSION"
# cd ..

which llama
llama model prompt-format -m Llama3.2-11B-Vision-Instruct
llama model list
llama stack list-apis
llama stack list-providers inference

llama stack build --template together --print-deps-only

if is_truthy "$DRY_RUN"; then
  echo "DRY RUN: skipping pypi upload"
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "Uploading llama-$repo to pypi"
  python -m twine upload \
    --skip-existing \
    --non-interactive \
    "llama-$repo/dist/*.whl" "llama-$repo/dist/*.tar.gz"
done

for repo in "${REPOS[@]}"; do
  cd llama-$repo

  # push the new commit to main and push the tag
  echo "Pushing branch and tag v$RELEASE_VERSION for $repo"
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "release-$RELEASE_VERSION"
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "v$RELEASE_VERSION"

  if ! is_truthy "$LLAMA_STACK_ONLY"; then
    # this is fishy because the rebase is not guaranteed to work. even the conditional above is
    # not quite correct because currently the idea is the LLAMA_STACK_ONLY=1 is set when this is a
    # bugfix release but that's not guaranteed to be true in the future.
    git checkout main
    add_bump_version_commit $repo $RELEASE_VERSION
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "main"
  fi
  cd ..
done

echo "Done"
