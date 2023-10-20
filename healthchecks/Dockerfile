FROM alpine:3.18.3

RUN apk --no-cache add postgresql14-client

COPY checks/hived.sh /checks/hived.sh
COPY checks/btracker.sh /checks/btracker.sh
COPY checks/hivemind.sh /checks/hivemind.sh
COPY checks/hafah.sh /checks/hafah.sh
COPY checks/hafbe.sh /checks/hafbe.sh
COPY docker_entrypoint.sh /

ENTRYPOINT ["/docker_entrypoint.sh"]
