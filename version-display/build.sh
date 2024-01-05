#! /bin/sh

export DOCKER_BUILDKIT=1
BUILD_TIME="$(date -uIseconds)"
GIT_COMMIT_SHA="$CI_COMMIT_SHA"
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="$(git rev-parse HEAD || true)"
  if [ -z "$GIT_COMMIT_SHA" ]; then
    GIT_COMMIT_SHA="[unknown]"
  fi
fi
GIT_CURRENT_BRANCH="$CI_COMMIT_BRANCH"
if [ -z "$GIT_CURRENT_BRANCH" ]; then
  GIT_CURRENT_BRANCH="$(git branch --show-current || true)"
  if [ -z "$GIT_CURRENT_BRANCH" ]; then
    GIT_CURRENT_BRANCH="$(git describe --abbrev=0 --all | sed 's/^.*\///' || true)"
    if [ -z "$GIT_CURRENT_BRANCH" ]; then
      GIT_CURRENT_BRANCH="[unknown]"
    fi
  fi
fi

GIT_LAST_LOG_MESSAGE="$CI_COMMIT_MESSAGE"
if [ -z "$GIT_LAST_LOG_MESSAGE" ]; then
  GIT_LAST_LOG_MESSAGE="$(git log -1 --pretty=%B || true)"
  if [ -z "$GIT_LAST_LOG_MESSAGE" ]; then
    GIT_LAST_LOG_MESSAGE="[unknown]"
  fi
fi


GIT_LAST_COMMITTER="$CI_COMMIT_AUTHOR"
if [ -z "$GIT_LAST_COMMITTER" ]; then
  GIT_LAST_COMMITTER="$(git log -1 --pretty="%an <%ae>" || true)"
  if [ -z "$GIT_LAST_COMMITTER" ]; then
    GIT_LAST_COMMITTER="[unknown]"
  fi
fi

GIT_LAST_COMMIT_DATE="$CI_COMMIT_TIMESTAMP"
if [ -z "$GIT_LAST_COMMIT_DATE" ]; then
  GIT_LAST_COMMIT_DATE="$(git log -1 --pretty="%aI" || true)"
  if [ -z "$GIT_LAST_COMMIT_DATE" ]; then
    GIT_LAST_COMMIT_DATE="[unknown]"
  fi
fi

exec docker build \
  --tag=registry.gitlab.syncad.com/hive/haf_api_node/version-display:latest \
  --build-arg BUILD_TIME="$BUILD_TIME" \
  --build-arg GIT_COMMIT_SHA="$GIT_COMMIT_SHA" \
  --build-arg GIT_CURRENT_BRANCH="$GIT_CURRENT_BRANCH" \
  --build-arg GIT_LAST_LOG_MESSAGE="$GIT_LAST_LOG_MESSAGE" \
  --build-arg GIT_LAST_COMMITTER="$GIT_LAST_COMMITTER" \
  --build-arg GIT_LAST_COMMIT_DATE="$GIT_LAST_COMMIT_DATE" \
  .
