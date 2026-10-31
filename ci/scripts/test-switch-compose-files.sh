#!/usr/bin/env bash
#
# Test that switch_zfs_datasets.sh renders the stack each env file's COMPOSE_FILE selects, in check,
# prepare, boot-check, swap and rollback.  The new configuration and the source layer an override
# pinning haf to a tag of its own, plus exposed/ (which publishes haf ports the boot check must drop).
# No ZFS or docker daemon needed: zfs and id are stubbed, and a docker wrapper logs every compose
# command, passes "config" to the real docker compose and renders the stack in place of "up".
# Skips (exit 0) with the reason when docker compose is missing.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/../.." && pwd)
PIN=example.test/hive/haf:switch-test

skip() {
  echo "SKIP switch-compose-files: $*"
  exit 0
}

fail() {
  echo "FAIL: $*"
  exit 1
}

REAL_DOCKER=$(command -v docker) || skip "docker is not installed"
"$REAL_DOCKER" compose version >/dev/null 2>&1 || skip "docker compose is not installed"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/mnt/live" "$WORK/mnt/copy"

cat > "$WORK/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$WORK/bin/zfs" <<EOF
#!/usr/bin/env bash
dataset=\${!#}
case "\$*" in
  "get -H -o value mountpoint "*) echo "$WORK/mnt/\${dataset#pool/}" ;;
  *"-t snapshot"*) echo "\$dataset@move" ;;
  *"-t filesystem"*) printf '%s\ton\tyes\n' "\$dataset" ;;
esac
EOF
cat > "$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/docker.log"
args=("\$@")
for i in "\${!args[@]}"; do
  case \${args[i]} in
    config) exec "$REAL_DOCKER" "\$@" ;;
    up)
      "$REAL_DOCKER" "\${args[@]:0:i}" config --format json > "$WORK/up.\$(wc -l < "$WORK/docker.log").json"
      [[ "\$*" != *-boot-check* ]]
      exit ;;
  esac
done
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
unset COMPOSE_FILE

cat > "$WORK/pins.yml" <<EOF
services:
  haf:
    image: $PIN
EOF
write_env() {
  sed -e "s|^ZPOOL_MOUNT_POINT=.*|ZPOOL_MOUNT_POINT=$WORK/mnt|" -e "s|^ZPOOL=.*|ZPOOL=pool|" \
    -e "s|^TOP_LEVEL_DATASET=.*|TOP_LEVEL_DATASET=$2|" "$REPO_DIR/.env.example" > "$WORK/$1"
  [ -z "${3:-}" ] || echo "COMPOSE_FILE=$3" >> "$WORK/$1"
}
write_env live.env live
write_env new.env copy "compose.yml:exposed/compose.exposed.yml:$WORK/pins.yml"
write_env source.env live "compose.yml:$WORK/pins.yml:compose.not-on-this-host.yml"
write_env unpinned-source.env live
switch() {
  "$REPO_DIR/switch_zfs_datasets.sh" --env-file="$WORK/live.env" "$@"
}

# haf's image and published ports in a rendered stack.
haf_of() {
  python3 -c '
import json, sys
haf = json.load(open(sys.argv[1]))["services"]["haf"]
print(haf["image"], " ".join("%s:%s" % (p.get("host_ip", ""), p.get("published", "")) for p in haf.get("ports", [])))
' "$1"
}

docker compose --project-directory "$REPO_DIR" --env-file "$WORK/live.env" config --format json > "$WORK/default.json"
DEFAULT_HAF=$(haf_of "$WORK/default.json" | cut -d' ' -f1)
[ "$DEFAULT_HAF" != "$PIN" ] || fail "compose.yml already uses $PIN"

######### check #########

switch --new-env="$WORK/new.env" --source-env="$WORK/source.env" check > "$WORK/check.log" || fail "check failed: $(cat "$WORK/check.log")"
grep -qF "ok    haf: $PIN (same as the source)" "$WORK/check.log" || fail "check did not resolve the pinned haf: $(cat "$WORK/check.log")"
grep -qF "compose.not-on-this-host.yml, which is not here" "$WORK/check.log" || fail "check did not list the source's missing file"
grep -qF "New compose files:  compose.yml exposed/compose.exposed.yml $WORK/pins.yml" "$WORK/check.log" || fail "check did not list the new compose files"
grep -q "images that change on swap.*\bhaf\b" "$WORK/check.log" || fail "check did not see haf change against the live stack"

switch --new-env="$WORK/new.env" --source-env="$WORK/unpinned-source.env" check > "$WORK/unpinned.log" && fail "check accepted a source built by $DEFAULT_HAF"
grep -qF "FAIL  haf: $PIN, but the source database was built by $DEFAULT_HAF" "$WORK/unpinned.log" || fail "no haf mismatch: $(cat "$WORK/unpinned.log")"

echo "$PIN" > "$WORK/source.images"
switch --new-env="$WORK/new.env" --source-images="$WORK/source.images" check > "$WORK/images.log" || fail "check failed with --source-images: $(cat "$WORK/images.log")"
grep -qF "ok    haf: $PIN (the source runs it)" "$WORK/images.log" || fail "--source-images did not match: $(cat "$WORK/images.log")"
echo "${PIN%:*}:other-tag" > "$WORK/source.images"
switch --new-env="$WORK/new.env" --source-images="$WORK/source.images" check > "$WORK/images.log" && fail "check accepted a different source haf tag"
grep -qF "FAIL  haf: $PIN, but the source database was built by ${PIN%:*}:other-tag" "$WORK/images.log" || fail "no --source-images mismatch: $(cat "$WORK/images.log")"

echo "COMPOSE_FILE=compose.yml:compose.not-on-this-host.yml" >> "$WORK/broken.env"
cat "$WORK/new.env" "$WORK/broken.env" > "$WORK/broken-new.env"
switch --new-env="$WORK/broken-new.env" check > "$WORK/broken.log" 2>&1 && fail "check accepted a new configuration naming a missing compose file"
grep -qF "names missing file(s): $REPO_DIR/compose.not-on-this-host.yml" "$WORK/broken.log" || fail "missing file not reported: $(cat "$WORK/broken.log")"

######### prepare and boot-check #########

switch --new-env="$WORK/new.env" --source-env="$WORK/source.env" prepare > "$WORK/prepare.log" || fail "prepare failed: $(cat "$WORK/prepare.log")"
: > "$WORK/docker.log"
switch --new-env="$WORK/new.env" --source-env="$WORK/source.env" boot-check > "$WORK/boot.log" 2>&1 && fail "boot-check went on after a failed up"
up=$(grep -n -- ' up ' "$WORK/docker.log" | cut -d: -f1 || true)
[ -n "$up" ] || fail "boot-check ran no up: $(cat "$WORK/boot.log")"
grep -E -- "-f $REPO_DIR/exposed/compose.exposed.yml -f $WORK/pins.yml --env-file $WORK/new.env -f [^ ]+\.boot-check\.yml -p haf-boot-check up" "$WORK/docker.log" >/dev/null \
  || fail "boot-check did not layer its override after the new configuration's files: $(cat "$WORK/docker.log")"
[ "$(haf_of "$WORK/up.$up.json")" = "$PIN 127.0.0.1:" ] || fail "boot-check haf: $(haf_of "$WORK/up.$up.json")"
grep -q -- '-p haf-boot-check down' "$WORK/docker.log" || fail "boot-check did not remove its project"

######### swap and rollback #########

cp "$WORK/live.env" "$WORK/live.env.orig"
: > "$WORK/docker.log"
switch --new-env="$WORK/new.env" --source-env="$WORK/source.env" --force swap > "$WORK/swap.log" || fail "swap failed: $(cat "$WORK/swap.log")"
up=$(grep -n -- ' up ' "$WORK/docker.log" | cut -d: -f1 || true)
grep -qF -- "-f $REPO_DIR/compose.yml --env-file $WORK/live.env down" "$WORK/docker.log" || fail "swap did not stop the live stack with its own files: $(cat "$WORK/docker.log")"
[ -n "$up" ] || fail "swap ran no up: $(cat "$WORK/swap.log")"
[ "$(haf_of "$WORK/up.$up.json")" = "$PIN :2001 0.0.0.0:17001 0.0.0.0:17008" ] || fail "swap started haf as $(haf_of "$WORK/up.$up.json")"

: > "$WORK/docker.log"
switch --force rollback > "$WORK/rollback.log" || fail "rollback failed: $(cat "$WORK/rollback.log")"
grep -qF -- "-f $WORK/pins.yml --env-file $WORK/live.env down" "$WORK/docker.log" || fail "rollback did not stop the stack with the new files: $(cat "$WORK/docker.log")"
up=$(grep -n -- ' up ' "$WORK/docker.log" | cut -d: -f1 || true)
[ "$(haf_of "$WORK/up.$up.json")" = "$DEFAULT_HAF :2001" ] || fail "rollback started haf as $(haf_of "$WORK/up.$up.json")"
cmp -s "$WORK/live.env" "$WORK/live.env.orig" || fail "rollback did not restore the live env file"

echo "PASS switch-compose-files"
