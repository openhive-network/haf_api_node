FROM registry.gitlab.syncad.com/hive/haf_api_node/alpine:3.22.1

RUN apk --no-cache add postgresql-client

COPY checks/hived.sh /checks/hived.sh
COPY checks/hafbe_btracker.sh /checks/hafbe_btracker.sh
COPY checks/hafbe_reptracker.sh /checks/hafbe_reptracker.sh
COPY checks/hivemind.sh /checks/hivemind.sh
COPY checks/hafah.sh /checks/hafah.sh
COPY checks/hafbe.sh /checks/hafbe.sh
COPY checks/format_seconds.sh /checks/format_seconds.sh
COPY checks/check_haf_lib.sh /checks/check_haf_lib.sh
COPY checks/hivesense.sh /checks/hivesense.sh
COPY checks/nft_tracker.sh /checks/nft_tracker.sh
COPY checks/status.sh /checks/status.sh
COPY checks/proxy_whitelist.sh /checks/proxy_whitelist.sh
COPY healthcheck_healthcheck.sh /
COPY docker_entrypoint.sh /

ENTRYPOINT ["/docker_entrypoint.sh"]
