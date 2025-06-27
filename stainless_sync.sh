#!/bin/bash

# Add argument checking
if [ "$#" -ne 1 ]; then
    echo "Error: Script requires exactly 1 argument"
    echo "Usage: $0 <client_branch>"
    exit 1
fi

client_branch="$1"

set -euo pipefail
set -x

# Create temporary directory
temp_dir=$(mktemp -d)
echo "Working in temporary directory: $temp_dir"

# Check if client branch exists in origin (without cloning)
if git ls-remote --heads git@github.com:meta-llama/llama-stack-client-python.git "$client_branch" | grep -q "$client_branch"; then
    echo "Warning: Branch '$client_branch' already exists in client repository"
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Now proceed with cloning
cd "$temp_dir"
git clone git@github.com:llamastack/llama-stack-client-python.git stainless
git clone git@github.com:meta-llama/llama-stack-client-python.git client

# Checkout branches after confirming they exist/don't exist
cd "$temp_dir/stainless"
stainless_commit_hash=$(git rev-parse HEAD)

cd "$temp_dir/client"
git checkout -b "$client_branch"

# Export the temp directories as environment variables
export STAINLESS_PYTHON_SDK_REPO="$temp_dir/stainless"
export META_LLAMA_PYTHON_SDK_REPO="$temp_dir/client"

# Copy files using rsync
rsync -av --delete --exclude 'llama_stack_client/lib' $STAINLESS_PYTHON_SDK_REPO/src $META_LLAMA_PYTHON_SDK_REPO/
rsync -av --delete $STAINLESS_PYTHON_SDK_REPO/tests $META_LLAMA_PYTHON_SDK_REPO/

# Remove src/llama_stack directory if it exists
rm -rf $META_LLAMA_PYTHON_SDK_REPO/src/llama_stack

CLIENT_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/_client.py

# Add json import after future imports
perl -pi -e 's/(from __future__ import.*\n)/$1import json\n/' "$CLIENT_PY"

# Add provider_data parameter
perl -pi -e 's/(_strict_response_validation: bool = False,)/$1\n        provider_data: Mapping[str, Any] | None = None,/' "$CLIENT_PY"

# Add provider_data handling logic
perl -pi -e '
  s|(base_url = f"http:\/\/any-hosted-llama-stack\.com")|$1\n\n        custom_headers = default_headers or {}\n        custom_headers["X-LlamaStack-Client-Version"] = __version__\n        if provider_data is not None:\n            custom_headers["X-LlamaStack-Provider-Data"] = json.dumps(provider_data)|
' "$CLIENT_PY"

# Add streaming header when stream=True for /inference/completion and /inference/chat-completion
INFERENCE_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/resources/inference.py
perl -i -0777 -pe '
  s|(return (?:await\b\s+)?self._post\(\n            "/v\d+/inference/completion",)|if stream:\n            extra_headers = {"Accept": "text\/event-stream", \*\*\(extra_headers or {}\)}\n        $1|gs
' "$INFERENCE_PY"
INFERENCE_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/resources/inference.py
perl -i -0777 -pe '
  s|(return (?:await\b\s+)?self._post\(\n            "/v\d+/inference/chat-completion",)|if stream:\n            extra_headers = {"Accept": "text\/event-stream", \*\*\(extra_headers or {}\)}\n        $1|gs
' "$INFERENCE_PY"

perl -pi -e 's|custom_headers=default_headers|custom_headers=custom_headers|' "$CLIENT_PY"

# Update logging configuration to add RichHandler
LOGS_CONFIG_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/_utils/_logs.py
perl -i -0777 -pe '
  # Add rich.logging import
  s|(import os\nimport logging\n)|$1from rich.logging import RichHandler\n|gs;

  # Update the _basic_config function to add handlers parameter with RichHandler
  s|(logging\.basicConfig\(\n\s+format="[^"]+",\n\s+datefmt="[^"]+")(\s*,?\n\s*\))|$1,\n        handlers=[RichHandler(rich_tracebacks=True)]$2|gs;
' "$LOGS_CONFIG_PY"


RESPONSE_OBJECT_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/types/response_object.py
# look for class ResponseObject, and in the next line add the following:
# @property
# def output_text(self) -> str:
#     texts: List[str] = []
#     for output in self.output:
#         if output.type == "message":
#             for content in output.content:
#                 if content.type == "output_text":
#                     texts.append(content.text)
#     return "".join(texts)

perl -i -0777 -pe '
  s|(class ResponseObject.BaseModel.:)|$1\n    \@property\n    def output_text(self) -> str:\n        texts: List[str] = []\n        for output in self.output:\n            if output.type == "message":\n                for content in output.content:\n                    if content.type == "output_text":\n                        texts.append(content.text)\n        return "".join(texts)\n|gs;
' "$RESPONSE_OBJECT_PY"

git checkout HEAD src/llama_stack_client/_version.py

# Modify __init__.py to add the imports
INIT_PY=$META_LLAMA_PYTHON_SDK_REPO/src/llama_stack_client/__init__.py
perl -i -0777 -pe '
  s|(from \._utils\._logs import setup_logging as _setup_logging\n)|$1\nfrom .lib.agents.agent import Agent\nfrom .lib.agents.event_logger import EventLogger as AgentEventLogger\nfrom .lib.inference.event_logger import EventLogger as InferenceEventLogger\nfrom .types.agents.turn_create_params import Document\nfrom .types.shared_params.document import Document as RAGDocument\n|gs;
' "$INIT_PY"

# Check for and add untracked files
cd "$META_LLAMA_PYTHON_SDK_REPO"
if [ -n "$(git status --porcelain)" ]; then
    echo "Changes detected in client repository"
    git status

    git add .
    git commit -m "Sync updates from stainless: $stainless_commit_hash"

    # Ask for confirmation before pushing
    read -p "Do you want to push branch '$client_branch' to remote? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git push -f origin "$client_branch"
        echo "Successfully pushed branch '$client_branch' to remote"
    else
        echo "Changes committed locally but not pushed. You can push later with:"
        echo "cd $META_LLAMA_PYTHON_SDK_REPO && git push origin $client_branch"
    fi
else
    echo "No changes detected in client repository"
fi
