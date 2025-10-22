#!/usr/bin/env sh
set -eu

GIT_TAG="${GIT_TAG:-v4.4.0}"
REPO="https://github.com/Someguy123/hivefeed-js.git"
IMAGE_1="registry.gitlab.syncad.com/hive/haf_api_node/hivefeed-js:${GIT_TAG}"
IMAGE_2="registry.hive.blog/haf_api_node/hivefeed-js:${GIT_TAG}"

# Create a temp dir (works on GNU/BSD)
TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t hivefeed-js)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM

# Clone into temp
git clone --depth 1 --branch "$GIT_TAG" "$REPO" "$TMPDIR/repo"

# Remove the VOLUME line
sed -i '/^[[:space:]]*VOLUME[[:space:]]*\/opt\/hivefeed\/config\.json[[:space:]]*$/d' \
  "$TMPDIR/repo/Dockerfile"

# Build from the temp directory as context
(
  cd "$TMPDIR/repo"
  docker build --pull -t "$IMAGE_1" -t "$IMAGE_2" .
)

echo "Built images:"
echo "  - $IMAGE_1"
echo "  - $IMAGE_2"
