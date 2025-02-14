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
  git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
  cd llama-$repo

  if [ -n "$BRANCH" ]; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
  fi
  perl -pi -e "s/version = .*$/version = \"$VERSION\"/" pyproject.toml
  if [ -f "src/llama_stack_client/_version.py" ]; then
    perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
  fi

  # Need to do this sequentially actually to capture the dependencies properly
  #
  # perl -pi -e "s/llama-models>=.*/llama-models>=$VERSION/" requirements.txt
  # perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION/" requirements.txt
  uv build -q
  cd ..
done

uv pip install llama-models/dist/llama_models-$VERSION-py3*.whl
# check Tokenizer.get_instance() and add a simple __main__ to that file

uv pip install llama-stack-client-python/dist/llama_stack_client-$VERSION-py3*.whl
# add a minimal test

uv pip install llama-stack/dist/llama_stack-$VERSION-py3*.whl
uv pip list | grep llama
llama model prompt-format -m Llama3.2-11B-Vision-Instruct
llama model list
llama stack list-apis
llama stack list-providers inference
llama stack list-providers telemetry

uv pip install pytest nbval pytest-asyncio


test_library_client() {
  echo "Building template"
  SCRIPT_FILE=$(mktemp)
  echo "#!/bin/bash" >$SCRIPT_FILE
  echo "set -x" >>$SCRIPT_FILE
  echo "set -euo pipefail" >>$SCRIPT_FILE
  llama stack build --template $TEMPLATE --print-deps-only >>$SCRIPT_FILE

  echo "Running script $SCRIPT_FILE"
  bash $SCRIPT_FILE

  echo "Running client-sdk tests before uploading"
  LLAMA_STACK_CONFIG=$TEMPLATE pytest -s -v llama-stack/tests/client-sdk/ \
    -k "not(builtin_tool_code or safety_with_image or code_interpreter_for)" \
    --safety-shield meta-llama/Llama-Guard-3-8B
}

test_docker() {
  echo "Testing docker"

  USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack LLAMA_MODELS_DIR=llama-models \
    llama stack build --template $TEMPLATE --image-type container

  docker images

  # run the container in the background
  export LLAMA_STACK_PORT=8321
  docker run -d --name llama-stack-$TEMPLATE -p $LLAMA_STACK_PORT:$LLAMA_STACK_PORT \
    -e TOGETHER_API_KEY=$TOGETHER_API_KEY \
    -e FIREWORKS_API_KEY=$FIREWORKS_API_KEY \
    -e TAVILY_SEARCH_API_KEY=$TAVILY_SEARCH_API_KEY \
    -v $(pwd)/llama-stack:/app/llama-stack-source \
    -v $(pwd)/llama-models:/app/llama-models-source \
    distribution-$TEMPLATE:dev \
    --port $LLAMA_STACK_PORT

  # check localhost:$LLAMA_STACK_PORT/health repeatedly until it returns 200
  iterations=0
  max_iterations=20
  while [ $(curl -s -o /dev/null -w "%{http_code}" localhost:$LLAMA_STACK_PORT/v1/health) -ne 200 ]; do
    sleep 2
    iterations=$((iterations + 1))
    if [ $iterations -gt $max_iterations ]; then
      echo "Failed to start the container"
      docker logs llama-stack-$TEMPLATE
      exit 1
    fi
  done

  LLAMA_STACK_BASE_URL=http://localhost:$LLAMA_STACK_PORT pytest -s -v llama-stack/tests/client-sdk/ \
    -k "not(builtin_tool_code or safety_with_image or code_interpreter_for)" \
    --safety-shield meta-llama/Llama-Guard-3-8B

  # stop the container
  docker stop llama-stack-$TEMPLATE
}

test_library_client
test_docker

# TODO: we must re-build the packages now ensuring proper dependencies are captured
# otherwise one needs to install them like (P1==test-version P2==test-version P3==test-version)
for repo in "${REPOS[@]}"; do
  echo "Uploading llama-$repo to testpypi"
  # tag the repo for this version
  echo "Tagging llama-$repo at version $VERSION"
  cd llama-$repo
  git tag -a "v$VERSION" -m "Release version $VERSION"
  cd ..

  python -m twine upload \
    --repository-url https://test.pypi.org/legacy/ \
    --skip-existing \
    llama-$repo/dist/*.whl llama-$repo/dist/*.tar.gz

  # push the tag
  echo "Pushing tag for llama-$repo"
  cd llama-$repo
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "v$VERSION"
  cd ..
done

echo "Successfully uploaded packages to testpypi"

# test run docker
# podman run --network host -it -p 5000:5000 -v ~/.llama:/root/.llama --gpus=all llamastack-local-gpu
