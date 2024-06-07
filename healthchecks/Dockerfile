FROM alpine:3.18.3

RUN apk --no-cache add postgresql14-client

COPY checks/hived.sh /checks/hived.sh
COPY checks/btracker.sh /checks/btracker.sh
COPY checks/reptracker.sh /checks/reptracker.sh
COPY checks/hivemind.sh /checks/hivemind.sh
COPY checks/hafah.sh /checks/hafah.sh
COPY checks/hafbe.sh /checks/hafbe.sh
COPY checks/format_seconds.sh /checks/format_seconds.sh
COPY checks/check_haf_lib.sh /checks/check_haf_lib.sh
COPY docker_entrypoint.sh /

ENTRYPOINT ["/docker_entrypoint.sh"]
