FROM alpine:3.18.3

RUN apk --no-cache add postgresql14-client

COPY checks/hived.sh /checks/hived.sh
COPY checks/hafbe_btracker.sh /checks/hafbe_btracker.sh
COPY checks/hafbe_reptracker.sh /checks/hafbe_reptracker.sh
COPY checks/hivemind.sh /checks/hivemind.sh
COPY checks/hafah.sh /checks/hafah.sh
COPY checks/hafbe.sh /checks/hafbe.sh
COPY checks/format_seconds.sh /checks/format_seconds.sh
COPY checks/check_haf_lib.sh /checks/check_haf_lib.sh
COPY docker_entrypoint.sh /

ENTRYPOINT ["/docker_entrypoint.sh"]
