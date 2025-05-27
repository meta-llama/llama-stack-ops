#!/bin/bash

# Add argument checking
if [ "$#" -ne 2 ]; then
    echo "Error: Script requires exactly 2 arguments"
    echo "Usage: $0 <stainless_branch> <client_branch>"
    exit 1
fi

stainless_branch="$1"
client_branch="$2"

set -euo pipefail
set -x

# Create temporary directory
temp_dir=$(mktemp -d)
echo "Working in temporary directory: $temp_dir"

# Check if stainless branch exists in origin (without cloning)
if ! git ls-remote --heads git@github.com:stainless-sdks/llama-stack-node.git "$stainless_branch" | grep -q "$stainless_branch"; then
    echo "Error: Branch '$stainless_branch' not found in stainless repository"
    exit 1
fi

# Check if client branch exists in origin (without cloning)
if git ls-remote --heads git@github.com:meta-llama/llama-stack-client-node.git "$client_branch" | grep -q "$client_branch"; then
    echo "Warning: Branch '$client_branch' already exists in client repository"
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Now proceed with cloning
cd "$temp_dir"
git clone git@github.com:stainless-sdks/llama-stack-node.git stainless
git clone git@github.com:meta-llama/llama-stack-client-node.git client

# Checkout branches after confirming they exist/don't exist
cd "$temp_dir/stainless"
git checkout "$stainless_branch"
git pull

cd "$temp_dir/client"
git checkout -b "$client_branch"

# Export the temp directories as environment variables
export STAINLESS_NODE_SDK_REPO="$temp_dir/stainless"
export META_LLAMA_NODE_SDK_REPO="$temp_dir/client"

# Copy files using rsync
rsync -av --delete --exclude 'src/lib' $STAINLESS_NODE_SDK_REPO/src $META_LLAMA_NODE_SDK_REPO/
rsync -av --delete $STAINLESS_NODE_SDK_REPO/tests $META_LLAMA_NODE_SDK_REPO/

git checkout HEAD src/version.ts

# Check for and add untracked files
cd "$META_LLAMA_NODE_SDK_REPO"
if [ -n "$(git status --porcelain)" ]; then
    echo "Changes detected in client repository"
    git status

    git diff

    git add .
    git commit -m "Sync updates from stainless branch: $stainless_branch"

    # Ask for confirmation before pushing
    read -p "Do you want to push branch '$client_branch' to remote? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git push -f origin "$client_branch"
        echo "Successfully pushed branch '$client_branch' to remote"
    else
        echo "Changes committed locally but not pushed. You can push later with:"
        echo "cd $META_LLAMA_NODE_SDK_REPO && git push origin $client_branch"
    fi
else
    echo "No changes detected in client repository"
fi
