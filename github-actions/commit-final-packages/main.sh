#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

set -uo pipefail
set -x

for repo in models stack-client-python stack; do
  with-proxy git clone git@github.com:meta-llama/llama-$repo.git
  cd llama-$repo
  if [ -n "$BRANCH" ]; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
  fi
  perl -pi -e "s/version=.*,/version=\"$VERSION\",/" setup.py
  perl -pi -e "s/llama-models.*/llama-models>=$VERSION/" requirements.txt
  perl -pi -e "s/llama-stack-client.*/llama-stack-client>=$VERSION/" requirements.txt

  # stack-client uses pyproject.toml
  perl -pi -e "s/version = .*$/version = \"$VERSION\"/" pyproject.toml
  perl -pi -e "s/__version__ = .*$/__version__ = \"$VERSION\"/" src/llama_stack_client/_version.py

  git tag -a "v$VERSION" -m "Release version $VERSION"
  git commit -a -m "Bump version to $VERSION"

  with-proxy python -m build
  cd ..
done

with-proxy git clone git@github.com:meta-llama/llama-stack-apps.git
cd llama-stack-apps
if [ -n "$BRANCH" ]; then
  git checkout -b "$BRANCH" "origin/$BRANCH"
fi
perl -pi -e "s/llama-stack>=.*/llama-stack>=$VERSION/" requirements.txt
perl -pi -e "s/llama-stack-client.*/llama-stack-client>=$VERSION/" requirements.txt
git commit -a -m "Bump version to $VERSION"
git tag -a "v$VERSION" -m "Release version $VERSION"
cd ..

echo "Installing llama models"
pip install llama-models/dist/llama_models-$VERSION-py3*.whl

echo "Installing llama stack client"
pip install llama-stack-client-python/dist/llama_stack_client-$VERSION-py3*.whl

echo "Installing llama stack"
pip install llama-stack/dist/llama_stack-$VERSION-py3*.whl
which llama
llama model prompt-format -m Llama3.2-11B-Vision-Instruct
llama model list
llama stack list-apis
llama stack list-providers inference

for repo in models stack-client-python stack; do
  echo ""
  python -m twine upload --repository pypi "llama-$repo/dist/*.whl" "llama-$repo/dist/*.tar.gz"
done

for repo in models stack-client-python stack stack-apps; do
  cd llama-$repo
  git pull
  echo ""
  git push origin "v$VERSION"
  git push origin main:main
  cd ..
done

echo "Done"