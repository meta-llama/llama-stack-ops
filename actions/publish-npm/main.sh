#!/bin/bash
set -e

cd llama-stack-client-typescript
if [[ "$VERSION" == *"rc"* ]]; then
  yarn version --new-version $VERSION -m "Bump version to $VERSION" --no-git-tag-version
else
  yarn version --new-version $VERSION -m "Bump version to $VERSION"
fi
yarn install
yarn build
cd dist
if [[ "$VERSION" == *"rc"* ]]; then
  yarn publish --tag rc --non-interactive --access public
else
  yarn publish --non-interactive --access public
  git config --global user.email "github-actions@github.com"
  git config --global user.name "GitHub Actions"
  git commit -a -m "Bump version to $VERSION" --amend
  git push origin HEAD:main --force
fi
cd ..