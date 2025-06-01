#!/bin/bash

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source $THIS_DIR/../publish-dockers/common.sh

set -x

push_manifest_list() {
  template=$1

  echo "Pushing multi-arch manifest list for template $template"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    manifests="$DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION}-amd64"
    has_arm64_image=$(docker buildx imagetools inspect $DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION}-arm64 > /dev/null 2>&1; echo $?)
    if [ "$has_arm64_image" -eq 0 ]; then
      manifests="$manifests $DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION}-arm64"
    fi
    docker buildx imagetools create \
      -t $DOCKERHUB_ORGANIZATION/distribution-$template:test-${VERSION} \
      $manifests
  else
    manifests="$DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION}-amd64"
    has_arm64_image=$(docker buildx imagetools inspect $DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION}-arm64 > /dev/null 2>&1; echo $?)
    if [ "$has_arm64_image" -eq 0 ]; then
      manifests="$manifests $DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION}-arm64"
    fi
    docker buildx imagetools create \
      -t $DOCKERHUB_ORGANIZATION/distribution-$template:${VERSION} \
      $manifests
    docker buildx imagetools create \
      -t $DOCKERHUB_ORGANIZATION/distribution-$template:latest \
      $manifests
  fi
}

for template in "${TEMPLATES[@]}"; do
  push_manifest_list $template
done

echo "Done"
