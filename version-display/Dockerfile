FROM node:alpine

RUN mkdir -p /home/node/app
COPY api.js index.js package.json package-lock.json /home/node/app
WORKDIR /home/node/app
RUN npm ci

ARG BUILD_TIME
ARG GIT_COMMIT_SHA
ARG GIT_CURRENT_BRANCH
ARG GIT_LAST_LOG_MESSAGE
ARG GIT_LAST_COMMITTER
ARG GIT_LAST_COMMIT_DATE
LABEL org.opencontainers.image.created="$BUILD_TIME"
LABEL org.opencontainers.image.url="https://hive.io/"
LABEL org.opencontainers.image.documentation="https://gitlab.syncad.com/hive/haf_api_node"
LABEL org.opencontainers.image.source="https://gitlab.syncad.com/hive/haf_api_node"
#LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="$GIT_COMMIT_SHA"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.ref.name="HAF API node version display app"
LABEL org.opencontainers.image.title="Hive Application Framework (HAF) version display app"
LABEL org.opencontainers.image.description="Shows the currently-running versions of each of the docker container to the admin"
LABEL io.hive.image.branch="$GIT_CURRENT_BRANCH"
LABEL io.hive.image.commit.log_message="$GIT_LAST_LOG_MESSAGE"
LABEL io.hive.image.commit.author="$GIT_LAST_COMMITTER"
LABEL io.hive.image.commit.date="$GIT_LAST_COMMIT_DATE"

CMD ["node", "api.js"]
