#!/bin/bash

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source $THIS_DIR/common.sh

CONTINUE_ON_ERROR=${CONTINUE_ON_ERROR:-}
ARCH=${ARCH:-amd64}

# `llama stack build` uses the `BUILD_PLATFORM` as the architecture to build
export BUILD_PLATFORM="linux/$ARCH"

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.12
source .venv/bin/activate

uv pip install --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  llama-stack==${VERSION}

which llama
llama stack list-apis

last_build_error="false"
handle_build_error() {
  template=$1
  last_build_error="true"

  echo "Error building template $template" >&2
  if [ "$CONTINUE_ON_ERROR" = "true" ]; then
    echo "Continuing on error" >&2
  else
    echo "Stopping on error" >&2
    exit 1
  fi
}

build_and_push_docker() {
  template=$1
  last_build_error="false"

  echo "Building docker image for template $template and platform $BUILD_PLATFORM"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    TEST_PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container || handle_build_error $template
  else
    PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container || handle_build_error $template
  fi
  docker images

  if [ "$last_build_error" = "true" ]; then
    echo "Skipping push for template $template because of build error"
    return
  fi

  echo "Pushing docker image for template $template and platform $BUILD_PLATFORM"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    docker tag distribution-$template:test-${VERSION} $DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION}-${ARCH}
    docker push $DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION}-${ARCH}
  else
    docker tag distribution-$template:${VERSION} $DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION}-${ARCH}
    docker tag distribution-$template:${VERSION} $DOCKERHUB_ORGANIZATION/distribution-$template:latest-${ARCH}
    docker push $DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION}-${ARCH}
    docker push $DOCKERHUB_ORGANIZATION/distribution-$template:latest-${ARCH}
  fi
}

for template in "${TEMPLATES[@]}"; do
  build_and_push_docker $template
done

echo "Done"
