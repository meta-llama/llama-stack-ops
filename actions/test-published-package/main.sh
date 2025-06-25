#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

TEMPLATE=${TEMPLATE:-fireworks}

set -euo pipefail
set -x

if ! git ls-remote --tags https://github.com/meta-llama/llama-stack.git "refs/tags/v$VERSION" | grep -q .; then
  echo "Tag v$VERSION does not exist for llama-stack" >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
cd $TMPDIR

uv venv -p python3.12
source .venv/bin/activate

max_attempts=6
attempt=1
while [ $attempt -le $max_attempts ]; do
  echo "Attempt $attempt of $max_attempts to install package..."
  if uv pip install --no-cache \
    --index-strategy unsafe-best-match \
    --prerelease=allow \
    --index-url https://pypi.org/simple/ \
    --extra-index-url https://test.pypi.org/simple/ \
    llama-stack==${VERSION}; then
    echo "Package installed successfully"
    break
  fi
  if [ $attempt -ge $max_attempts ]; then
    echo "Failed to install package after $max_attempts attempts"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 5
done

uv pip list | grep llama
llama model prompt-format -m Llama3.2-90B-Vision-Instruct
llama model list
llama stack list-apis
llama stack list-providers inference
llama stack list-providers telemetry

templates_to_build=("fireworks" "together")
for build_template in "${templates_to_build[@]}"; do
  echo "Building $build_template template"
  SCRIPT_FILE=$(mktemp)
  echo "#!/bin/bash" >$SCRIPT_FILE
  echo "set -euo pipefail" >>$SCRIPT_FILE
  echo "set -x" >>$SCRIPT_FILE
  llama stack build --template $build_template --print-deps-only --image-type venv >>$SCRIPT_FILE

  echo "Running script $SCRIPT_FILE"
  bash $SCRIPT_FILE
done

uv pip install pytest nbval pytest-asyncio

git clone --depth 1 https://github.com/meta-llama/llama-stack.git
cd llama-stack

git fetch origin refs/tags/v${VERSION}:refs/tags/v${VERSION}
git checkout -b cut-${VERSION} refs/tags/v${VERSION}

# Client-SDK uses Fireworks
echo "Running integration tests"
LLAMA_STACK_TEST_INTERVAL_SECONDS=3 pytest -s -v tests/integration/ \
  --stack-config $TEMPLATE \
  -k "not(supervised_fine_tune or builtin_tool_code or safety_with_image or code_interpreter_for or rag_and_code or truncation or register_and_unregister)" \
  --text-model meta-llama/Llama-3.3-70B-Instruct \
  --vision-model meta-llama/Llama-4-Scout-17B-16E-Instruct \
  --safety-shield meta-llama/Llama-Guard-3-8B \
  --embedding-model all-MiniLM-L6-v2

# Notebook tests use Together
echo "Running notebook tests"

# very important to _not_ run from the llama-stack repo otherwise you
# won't pick up the installed version of the package
# cd $TMPDIR
# LLAMA_STACK_TEST_INTERVAL_SECONDS=3 pytest -v -s --nbval-lax ./llama-stack/docs/getting_started.ipynb
# LLAMA_STACK_TEST_INTERVAL_SECONDS=3 pytest -v -s --nbval-lax ./llama-stack/docs/notebooks/Llama_Stack_Benchmark_Evals.ipynb
