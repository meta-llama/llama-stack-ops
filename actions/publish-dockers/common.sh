#!/bin/bash

# This file is shared between the publish-dockers and
# publish-docker-manifest-lists actions. It should only contain content
# that is common to both actions.

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

DOCKERHUB_ORGANIZATION=${DOCKERHUB_ORGANIZATION:-llamastack}
TEMPLATES=${TEMPLATES:-}

if [ -z "$TEMPLATES" ]; then
  TEMPLATES=(starter tgi meta-reference-gpu postgres-demo)
else
  TEMPLATES=(${TEMPLATES//,/ })
fi

release_exists() {
  local source=$1
  releases=$(curl -s https://${source}.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
  for release in $releases; do
    if [ x"$release" = x"$VERSION" ]; then
      return 0
    fi
  done
  return 1
}

if release_exists "test.pypi"; then
  echo "Version $VERSION found in test.pypi"
  PYPI_SOURCE="testpypi"
elif release_exists "pypi"; then
  echo "Version $VERSION found in pypi"
  PYPI_SOURCE="pypi"
else
  echo "Version $VERSION not found in either test.pypi or pypi" >&2
  exit 1
fi