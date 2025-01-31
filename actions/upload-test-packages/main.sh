#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2 
  exit 1
fi

set -uo pipefail
set -x

REPOS=(models stack-client-python stack)
for repo in "${REPOS[@]}"; do
  git clone git@github.com:meta-llama/llama-$repo.git
  cd llama-$repo

  if [ -n "$BRANCH" ]; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
  fi
  perl -pi -e "s/version=.*,/version=\"$VERSION\",/" setup.py
  perl -pi -e "s/version = .*$/version = \"$VERSION\"/" pyproject.toml
  perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py

  # Need to do this sequentially actually to capture the dependencies properly
  #
  # perl -pi -e "s/llama-models>=.*/llama-models>=$VERSION/" requirements.txt
  # perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION/" requirements.txt
  python -m build
  cd ..
done

pip install llama-models/dist/llama_models-$VERSION-py3*.whl
# check Tokenizer.get_instance() and add a simple __main__ to that file

pip install llama-stack-client-python/dist/llama_stack_client-$VERSION-py3*.whl
# add a minimal test

pip install llama-stack/dist/llama_stack-$VERSION-py3*.whl
pip list | grep llama
llama model prompt-format -m Llama3.2-11B-Vision-Instruct
llama model list
llama stack list-apis
llama stack list-providers inference
llama stack list-providers telemetry

for repo in "${REPOS[@]}"; do
  echo "Uploading llama-$repo to testpypi"
  python -m twine upload --repository testpypi llama-$repo/dist/*.whl llama-$repo/dist/*.tar.gz
done

# sad things to ensure the cache is refreshed on test.pypi
pip uninstall llama-models llama-stack-client llama-stack -y

PACKAGES="llama-models==$VERSION llama-stack-client==$VERSION llama-stack==$VERSION"
pip install -U --extra-index-url https://test.pypi.org/simple/ $PACKAGES || true
sleep 1
pip install -U --extra-index-url https://test.pypi.org/simple/ $PACKAGES || true
sleep 1
pip install -U --no-cache-dir --extra-index-url https://test.pypi.org/simple/ $PACKAGES || true

# test run docker
# podman run --network host -it -p 5000:5000 -v ~/.llama:/root/.llama --gpus=all llamastack-local-gpu
