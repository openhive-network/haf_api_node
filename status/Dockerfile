FROM node:alpine

RUN mkdir -p /home/node/app
COPY app.js package.json package-lock.json /home/node/app/
WORKDIR /home/node/app
RUN npm ci

EXPOSE 3000
CMD ["node", "app.js"]

# Labels at the end for better layer caching
ARG BUILD_TIME
ARG GIT_COMMIT_SHA
ARG GIT_CURRENT_BRANCH
ARG GIT_LAST_LOG_MESSAGE
ARG GIT_LAST_COMMITTER
ARG GIT_LAST_COMMIT_DATE
ARG CI_COMMIT_TAG
LABEL org.opencontainers.image.created="$BUILD_TIME"
LABEL org.opencontainers.image.url="https://hive.io/"
LABEL org.opencontainers.image.documentation="https://gitlab.syncad.com/hive/haf_api_node"
LABEL org.opencontainers.image.source="https://gitlab.syncad.com/hive/haf_api_node"
LABEL org.opencontainers.image.version="$CI_COMMIT_TAG"
LABEL org.opencontainers.image.revision="$GIT_COMMIT_SHA"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.ref.name="HAF API node status API"
LABEL org.opencontainers.image.title="HAF API Node Status Service"
LABEL org.opencontainers.image.description="Provides health status for all configured HAF API services"
LABEL io.hive.image.branch="$GIT_CURRENT_BRANCH"
LABEL io.hive.image.commit.log_message="$GIT_LAST_LOG_MESSAGE"
LABEL io.hive.image.commit.author="$GIT_LAST_COMMITTER"
LABEL io.hive.image.commit.date="$GIT_LAST_COMMIT_DATE"