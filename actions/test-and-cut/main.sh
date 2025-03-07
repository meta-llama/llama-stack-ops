#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
if [ -z "${COMMIT_ID+x}" ]; then
  echo "You must set the COMMIT_ID environment variable" >&2
  exit 1
fi

GITHUB_TOKEN=${GITHUB_TOKEN:-}
ONLY_TEST_DONT_CUT=${ONLY_TEST_DONT_CUT:-false}
LLAMA_STACK_ONLY=${LLAMA_STACK_ONLY:-false}

TEMPLATE=fireworks

set -euo pipefail
set -x


is_truthy() {
  case "$1" in
    true|1) return 0 ;;
    false|0) return 1 ;;
    *) return 1 ;;
  esac
}

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.10
source .venv/bin/activate

build_packages() {
  uv pip install twine

  REPOS=(stack-client-python stack)
  if is_truthy "$LLAMA_STACK_ONLY"; then
    REPOS=(stack)
  fi

  for repo in "${REPOS[@]}"; do
    git clone --depth 10 "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git"
    cd llama-$repo

    if [ "$repo" == "stack" ] && [ -n "$COMMIT_ID" ]; then
      REF="${COMMIT_ID#origin/}"
      git fetch origin "$REF"

      # Use FETCH_HEAD which is where the fetched commit is stored
      git checkout -b "rc-$VERSION" FETCH_HEAD
    else
      git checkout -b "rc-$VERSION"
    fi

    perl -pi -e "s/version = .*$/version = \"$VERSION\"/" pyproject.toml

    if ! is_truthy "$LLAMA_STACK_ONLY"; then
      # this one is only applicable for llama-stack-client-python
      if [ -f "src/llama_stack_client/_version.py" ]; then
        perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py
      fi

      # this is applicable for llama-stack repo but we should not do it when
      # LLAMA_STACK_ONLY is true
      perl -pi -e "s/llama-stack-client>=.*/llama-stack-client>=$VERSION\",/" pyproject.toml
    fi

    uv build -q
    uv pip install dist/*.whl

    git commit -am "Release candidate $VERSION"
    cd ..
  done
}

test_llama_cli() {
  uv pip list | grep llama
  llama model prompt-format -m Llama3.2-11B-Vision-Instruct
  llama model list
  llama stack list-apis
  llama stack list-providers inference
  llama stack list-providers telemetry
}

run_integration_tests() {
  stack_config=$1
  shift
  pytest -s -v llama-stack/tests/integration/ \
    --stack-config $stack_config \
    -k "not(builtin_tool_code or safety_with_image or code_interpreter_for)" \
    --text-model meta-llama/Llama-3.1-8B-Instruct \
    --vision-model meta-llama/Llama-3.2-11B-Vision-Instruct \
    --safety-shield meta-llama/Llama-Guard-3-8B \
    --embedding-model all-MiniLM-L6-v2
}

test_library_client() {
  echo "Building template"
  SCRIPT_FILE=$(mktemp)
  echo "#!/bin/bash" >$SCRIPT_FILE
  echo "set -x" >>$SCRIPT_FILE
  echo "set -euo pipefail" >>$SCRIPT_FILE
  llama stack build --template $TEMPLATE --print-deps-only >>$SCRIPT_FILE

  echo "Running script $SCRIPT_FILE"
  bash $SCRIPT_FILE

  echo "Running integration tests before uploading"
  run_integration_tests $TEMPLATE
}

test_docker() {
  echo "Testing docker"

  if is_truthy "$LLAMA_STACK_ONLY"; then
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      llama stack build --template $TEMPLATE --image-type container
  else
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=llama-stack \
      LLAMA_STACK_CLIENT_DIR=llama-stack-client-python \
      llama stack build --template $TEMPLATE --image-type container
  fi

  docker images

  # run the container in the background
  export LLAMA_STACK_PORT=8321
  docker run -d --name llama-stack-$TEMPLATE -p $LLAMA_STACK_PORT:$LLAMA_STACK_PORT \
    -e TOGETHER_API_KEY=$TOGETHER_API_KEY \
    -e FIREWORKS_API_KEY=$FIREWORKS_API_KEY \
    -e TAVILY_SEARCH_API_KEY=$TAVILY_SEARCH_API_KEY \
    -v $(pwd)/llama-stack:/app/llama-stack-source \
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

  run_integration_tests http://localhost:$LLAMA_STACK_PORT

  # stop the container
  docker stop llama-stack-$TEMPLATE
}

build_packages

uv pip install pytest nbval pytest-asyncio

test_llama_cli
test_library_client
test_docker

# if ONLY_TEST_DONT_CUT is truthy, don't cut the branch
if is_truthy "$ONLY_TEST_DONT_CUT"; then
  echo "Not cutting (i.e., pushing the branch) because ONLY_TEST_DONT_CUT is true"
  exit 0
fi

for repo in "${REPOS[@]}"; do
  echo "Pushing branch rc-$VERSION for llama-$repo"
  cd llama-$repo
  git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/meta-llama/llama-$repo.git" "rc-$VERSION"
  cd ..

done

echo "Successfully cut a release candidate branch $VERSION"
