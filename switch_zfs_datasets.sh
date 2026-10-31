#!/usr/bin/env bash
#
# Switch this node to a copy of another node's datasets received with transfer_zfs_datasets.sh,
# checking that the copy boots before the live stack is touched.
# See "Moving a node's datasets to another host" in README.md for the whole procedure.

set -e -o pipefail

print_help() {
  cat <<EOF
Usage: $0 [options] check|prepare|boot-check|swap|rollback

The new configuration is a copy of this node's live .env with TOP_LEVEL_DATASET pointing at the
received copy and the image pins of the source node (HAF and every app that installs into the
database).  Every step but rollback takes it as --new-env.

  check       print the plan without changing anything: the copy's datasets and mount state,
              directories the new configuration bind-mounts that are missing from the copy
              (target-only directories), image differences, and the settings that change
  prepare     mount the copy, then copy target-only directories from the live datadir (create
              them empty when the live datadir lacks them too)
  boot-check  start HAF alone on the copy under a separate compose project, network and p2p
              port, wait until it is healthy, then stop it cleanly.  The live stack keeps running.
  swap        stop the live stack, save the live env file as <env-file>.before-switch.<time>,
              install the new configuration and start the stack on the copy
  rollback    stop the stack, restore the newest <env-file>.before-switch.* (or --restore-from)
              and start the stack on the old datasets, which swap left untouched

Options:
  --env-file=file        the live env file (default: .env)
  --new-env=file         the new configuration (required except for rollback)
  --source-env=file      the source node's env file: HAF and installer images must match it
  --boot-timeout=SECONDS how long boot-check waits for HAF to become healthy (default 3600)
  --restore-from=file    rollback: restore this env file instead of the newest backup
  --force, -f            don't ask for confirmation; turn image mismatches into warnings
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

REPO_DIR=$(cd "$(dirname "$0")" && pwd)

if ! OPTIONS=$(getopt -o he:f --long help,env-file:,new-env:,source-env:,boot-timeout:,restore-from:,force -n "$0" -- "$@"); then
  print_help
  exit 1
fi

LIVE_ENV=.env
NEW_ENV=""
SOURCE_ENV=""
BOOT_TIMEOUT=3600
RESTORE_FROM=""
FORCE=0

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e) LIVE_ENV="$2"; shift 2 ;;
    --new-env) NEW_ENV="$2"; shift 2 ;;
    --source-env) SOURCE_ENV="$2"; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT="$2"; shift 2 ;;
    --restore-from) RESTORE_FROM="$2"; shift 2 ;;
    --force|-f) FORCE=1; shift ;;
    --help|-h) print_help; exit 0 ;;
    --) shift; break ;;
  esac
done

COMMAND="$1"
[[ "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--boot-timeout must be a number"
[ "$(id -u)" -eq 0 ] || die "this script must be run as root"

######### Configuration #########

# Value of a variable after sourcing an env file the way the other scripts here do.
env_value() {
  bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${!2-}"' _ "$1" "$2"
}

# Sets <prefix>_ZPOOL, <prefix>_TOP, <prefix>_DATASET and <prefix>_MOUNTPOINT from an env file.
read_env() {
  local prefix="$1" file="$2" zpool top mountpoint pool_mountpoint
  [ -f "$file" ] || die "$file does not exist"
  zpool=$(env_value "$file" ZPOOL)
  top=$(env_value "$file" TOP_LEVEL_DATASET)
  if [ -z "$zpool" ] || [ -z "$top" ]; then
    die "$file must define ZPOOL and TOP_LEVEL_DATASET"
  fi
  pool_mountpoint=$(env_value "$file" ZPOOL_MOUNT_POINT)
  mountpoint=$(env_value "$file" TOP_LEVEL_DATASET_MOUNTPOINT)
  [ -n "$mountpoint" ] || mountpoint="${pool_mountpoint:-/$zpool}/$top"
  printf -v "${prefix}_ZPOOL" '%s' "$zpool"
  printf -v "${prefix}_TOP" '%s' "$top"
  printf -v "${prefix}_DATASET" '%s' "$zpool/$top"
  printf -v "${prefix}_MOUNTPOINT" '%s' "${mountpoint%/}"
}

LIVE_ENV=$(realpath "$LIVE_ENV")
read_env LIVE "$LIVE_ENV"
if [ "$COMMAND" != rollback ]; then
  [ -n "$NEW_ENV" ] || die "--new-env is required for $COMMAND"
  NEW_ENV=$(realpath "$NEW_ENV")
  read_env NEW "$NEW_ENV"
fi
[ -z "$SOURCE_ENV" ] || SOURCE_ENV=$(realpath "$SOURCE_ENV")
cd "$REPO_DIR"

compose() {
  local env_file="$1"
  shift
  docker compose --project-directory "$REPO_DIR" -f "$REPO_DIR/compose.yml" --env-file "$env_file" "$@"
}

# Prints "<service> <what>" lines from the rendered compose configuration on stdin;
# <what> is binds (bind-mount sources), images or ports (host_ip:published).
compose_query() {
  python3 -c '
import json, sys
services = json.load(sys.stdin).get("services", {})
for name, svc in sorted(services.items()):
    if sys.argv[1] == "binds":
        for v in svc.get("volumes", []):
            if v.get("type") == "bind":
                print(name, v["source"])
    elif sys.argv[1] == "images":
        print(name, svc.get("image", ""))
    elif sys.argv[1] == "ports":
        for p in svc.get("ports", []):
            print(name, "%s:%s" % (p.get("host_ip", ""), p.get("published", "")))
' "$1"
}

# Services whose images write the database: HAF and the app installers.
_writes_database() {
  case $1 in
    haf|*install*) return 0 ;;
    *) return 1 ;;
  esac
}

######### check #########

FAILURES=0
fail() {
  echo "  FAIL  $*"
  FAILURES=$((FAILURES + 1))
}
warn() {
  echo "  WARN  $*"
}
ok() {
  echo "  ok    $*"
}

# Bind sources under the copy that do not exist in it, as paths relative to its mountpoint.
MISSING_BINDS=()
COPY_MOUNTED=0

# check STRICT: STRICT=1 for steps that are about to use the copy (it must be mounted and complete).
check() {
  local strict="$1" name canmount mounted property unmounted=0 latest binds source rel service image
  local live_images new_images source_images source_image var live_value new_value
  local -a changed=()
  FAILURES=0
  MISSING_BINDS=()

  echo "Live configuration: $LIVE_ENV -> $LIVE_DATASET ($LIVE_MOUNTPOINT)"
  echo "New configuration:  $NEW_ENV -> $NEW_DATASET ($NEW_MOUNTPOINT)"
  echo ""
  echo "Copy:"
  if [ "$NEW_DATASET" = "$LIVE_DATASET" ]; then
    fail "the new configuration uses the live dataset; set TOP_LEVEL_DATASET to the received copy"
    return
  fi
  if ! zfs list "$NEW_DATASET" >/dev/null 2>&1; then
    fail "$NEW_DATASET does not exist; receive it with transfer_zfs_datasets.sh first"
    return
  fi
  latest=$(zfs list -H -d 1 -t snapshot -o name -s creation "$NEW_DATASET" | tail -1)
  ok "latest received snapshot: ${latest:-none}"
  property=$(zfs get -H -o value mountpoint "$NEW_DATASET")
  if [ "$property" = "$NEW_MOUNTPOINT" ]; then
    ok "mountpoint $property"
  else
    fail "$NEW_DATASET mounts on $property but the new configuration expects $NEW_MOUNTPOINT"
  fi
  while read -r name canmount mounted; do
    if [ "$canmount" = on ] && [ "$mounted" != yes ]; then
      unmounted=$((unmounted + 1))
    fi
    printf '        %-56s canmount=%-4s mounted=%s\n' "$name" "$canmount" "$mounted"
  done < <(zfs list -r -H -o name,canmount,mounted -t filesystem "$NEW_DATASET")
  if [ "$unmounted" -eq 0 ]; then
    COPY_MOUNTED=1
    ok "all datasets of the copy are mounted"
  elif [ "$strict" -eq 1 ]; then
    fail "$unmounted dataset(s) of the copy are not mounted; run prepare"
  else
    warn "$unmounted dataset(s) of the copy are not mounted (expected until prepare)"
  fi

  echo ""
  echo "Bind mounts of the new configuration:"
  if ! binds=$(compose "$NEW_ENV" config --format json | compose_query binds); then
    fail "docker compose could not render the new configuration"
    return
  fi
  while read -r service source; do
    case $source in
      "$NEW_MOUNTPOINT"|"$NEW_MOUNTPOINT"/*) ;;
      "$LIVE_MOUNTPOINT"|"$LIVE_MOUNTPOINT"/*)
        fail "$service still mounts the live datadir: $source (check the HAF_*_DIRECTORY settings)" ;;
      *)
        [ "$service" != haf ] || fail "haf mounts $source, outside the copy: its data would not come from the copy" ;;
    esac
  done <<< "$binds"
  while read -r source; do
    rel=${source#"$NEW_MOUNTPOINT"}
    rel=${rel#/}
    [ -n "$rel" ] || continue
    if [ "$COPY_MOUNTED" -eq 0 ]; then
      continue
    elif [ -e "$source" ]; then
      ok "$rel"
    else
      MISSING_BINDS+=("$rel")
      if [ -e "$LIVE_MOUNTPOINT/$rel" ]; then
        property="target-only: prepare copies it from $LIVE_MOUNTPOINT/$rel"
      else
        property="missing here and in the live datadir: prepare creates it empty"
      fi
      if [ "$strict" -eq 1 ]; then fail "$rel ($property)"; else warn "$rel ($property)"; fi
    fi
  done < <(awk -v mp="$NEW_MOUNTPOINT" '$2 == mp || index($2, mp "/") == 1 { print $2 }' <<< "$binds" | sort -u)
  [ "$COPY_MOUNTED" -eq 1 ] || warn "bind sources not checked: the copy is not mounted"

  echo ""
  echo "Images:"
  new_images=$(compose "$NEW_ENV" config --format json | compose_query images)
  if [ -n "$SOURCE_ENV" ]; then
    source_images=$(compose "$SOURCE_ENV" config --format json | compose_query images)
    while read -r service image; do
      _writes_database "$service" || continue
      source_image=$(awk -v s="$service" '$1 == s { print $2 }' <<< "$source_images")
      if [ -z "$source_image" ]; then
        warn "$service: not enabled on the source node"
      elif [ "$source_image" = "$image" ]; then
        ok "$service: $image (same as the source)"
      elif [ "$FORCE" -eq 1 ]; then
        warn "$service: $image, but the source database was built by $source_image"
      else
        fail "$service: $image, but the source database was built by $source_image"
      fi
    done <<< "$new_images"
  else
    warn "no --source-env: cannot verify that HAF and the installers match the versions that built the copy"
  fi
  live_images=$(compose "$LIVE_ENV" config --format json | compose_query images)
  changed=()
  while read -r service image; do
    grep -qxF "$service $image" <<< "$live_images" || changed+=("$service")
  done <<< "$new_images"
  echo "        images that change on swap (${#changed[@]}): ${changed[*]:-none}"

  changed=()
  echo ""
  echo "Settings that differ between $(basename "$LIVE_ENV") and $(basename "$NEW_ENV") (values not shown):"
  while read -r var; do
    live_value=$(env_value "$LIVE_ENV" "$var")
    new_value=$(env_value "$NEW_ENV" "$var")
    [ "$live_value" = "$new_value" ] || changed+=("$var")
  done < <(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$LIVE_ENV" "$NEW_ENV" | sort -u)
  echo "        ${changed[*]:-none}"
  echo "        Only TOP_LEVEL_DATASET (and its mountpoint) and image pins should be listed; hostnames,"
  echo "        TLS/proxy settings and COMPOSE_PROFILES stay this node's own."

  echo ""
  if [ "$FAILURES" -eq 0 ]; then
    echo "Check passed."
  else
    echo "Check found $FAILURES problem(s)."
  fi
}

require_check() {
  check 1
  [ "$FAILURES" -eq 0 ] || die "fix the problems above before $COMMAND"
}

confirm() {
  local choice
  [ "$FORCE" -eq 0 ] || return 0
  read -r -p "$1 (y/n): " choice
  case "$choice" in
    y|Y) ;;
    *) die "aborted" ;;
  esac
}

######### prepare #########

prepare() {
  local name canmount mounted rel parent
  check 0
  if [ "$NEW_DATASET" = "$LIVE_DATASET" ] || ! zfs list "$NEW_DATASET" >/dev/null 2>&1; then
    die "no copy to prepare"
  fi

  echo ""
  echo "Mounting the copy:"
  while read -r name canmount mounted; do
    if [ "$canmount" = on ] && [ "$mounted" != yes ]; then
      echo "  zfs mount $name"
      zfs mount "$name"
    fi
  done < <(zfs list -r -H -o name,canmount,mounted -t filesystem "$NEW_DATASET")

  check 0 > /dev/null
  for rel in "${MISSING_BINDS[@]}"; do
    parent=$(dirname "$NEW_MOUNTPOINT/$rel")
    mkdir -p "$parent"
    if [ -e "$LIVE_MOUNTPOINT/$rel" ]; then
      echo "  copying $LIVE_MOUNTPOINT/$rel ($(du -sh "$LIVE_MOUNTPOINT/$rel" | cut -f1))"
      cp -a "$LIVE_MOUNTPOINT/$rel" "$NEW_MOUNTPOINT/$rel"
    else
      echo "  creating empty $NEW_MOUNTPOINT/$rel"
      mkdir "$NEW_MOUNTPOINT/$rel"
      chown --reference="$parent" "$NEW_MOUNTPOINT/$rel"
    fi
  done

  echo ""
  check 1
  [ "$FAILURES" -eq 0 ] || die "the copy is still not ready"
}

######### boot-check #########

BOOT_PROJECT=""
boot_compose() {
  PROJECT_NAME="$BOOT_PROJECT" NETWORK_NAME="$BOOT_PROJECT" COMPOSE_PROFILES=core \
    P2P_PORT_MAPPING="127.0.0.1::2001" compose "$NEW_ENV" -p "$BOOT_PROJECT" "$@"
}

boot_cleanup() {
  set +e
  echo "Removing the boot-check project $BOOT_PROJECT"
  boot_compose down --timeout 120
}

boot_check() {
  local container status health deadline exit_code source port
  require_check
  BOOT_PROJECT="$(env_value "$LIVE_ENV" PROJECT_NAME)-boot-check"
  BOOT_PROJECT=${BOOT_PROJECT#-}

  # The boot check must not reach the live data or the live stack's published ports.
  while read -r _ source; do
    case $source in
      "$NEW_MOUNTPOINT"/*) ;;
      *) die "boot-check would mount $source, outside the copy" ;;
    esac
  done < <(boot_compose config --format json haf | compose_query binds | awk '$1 == "haf"')
  while read -r _ port; do
    case $port in
      127.0.0.1:*) ;;
      *) die "boot-check would publish $port on a public address" ;;
    esac
  done < <(boot_compose config --format json haf | compose_query ports | awk '$1 == "haf"')

  echo ""
  echo "Starting HAF on the copy as compose project $BOOT_PROJECT (live stack untouched)"
  trap boot_cleanup EXIT
  boot_compose up -d --no-deps haf
  container=$(boot_compose ps -q haf)
  deadline=$((SECONDS + BOOT_TIMEOUT))
  while true; do
    status=$(docker inspect -f '{{.State.Status}}' "$container")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")
    if docker logs "$container" 2>&1 | grep -F "Inconsistency in last irreversible block" >/dev/null; then
      docker logs --tail 30 "$container" 2>&1
      die "hived found shared_memory.bin and RocksDB out of step: the copy came from a snapshot that was not taken with snapshot_zfs_datasets.sh, or the source was not stopped"
    fi
    [ "$health" != healthy ] || break
    if [ "$status" != running ]; then
      docker logs --tail 50 "$container" 2>&1
      die "HAF exited ($status) before becoming healthy"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      docker logs --tail 50 "$container" 2>&1
      die "HAF did not become healthy within ${BOOT_TIMEOUT}s"
    fi
    echo "$(date -u +%FT%TZ) waiting: $status${health:+, $health}"
    sleep 30
  done

  echo "$(date -u +%FT%TZ) HAF is healthy on the copy; stopping it cleanly"
  boot_compose stop haf
  exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$container")
  boot_compose down
  trap - EXIT
  [ "$exit_code" = 0 ] || die "HAF exited with code $exit_code on shutdown; check its logs before swapping"
  echo "Boot check passed.  The copy has advanced past the snapshot by whatever it synced; that is fine."
}

######### swap and rollback #########

swap() {
  local backup
  require_check
  backup="$LIVE_ENV.before-switch.$(date -u +%Y%m%dT%H%M%SZ)"
  echo ""
  echo "This stops the live stack on $LIVE_DATASET and starts it on $NEW_DATASET."
  confirm "Swap now?"
  compose "$LIVE_ENV" down
  cp -p "$LIVE_ENV" "$backup"
  cp "$NEW_ENV" "$LIVE_ENV"
  echo "Saved the previous configuration as $backup"
  if ! compose "$LIVE_ENV" up -d; then
    echo "docker compose up failed.  To go back: sudo $0 --env-file=$LIVE_ENV rollback" >&2
    exit 1
  fi
  echo ""
  echo "Stack started on $NEW_DATASET.  Watch it with: docker compose logs -f haf"
  echo "To go back to $LIVE_DATASET: sudo $0 --env-file=$LIVE_ENV rollback"
  echo "Once you are satisfied, delete the old datasets yourself: zfs destroy -r $LIVE_DATASET"
}

rollback() {
  local backup="$RESTORE_FROM" dataset
  if [ -z "$backup" ]; then
    backup=$(find "$(dirname "$LIVE_ENV")" -maxdepth 1 -name "$(basename "$LIVE_ENV").before-switch.*" | sort | tail -1)
    [ -n "$backup" ] || die "no $LIVE_ENV.before-switch.* backup found; pass --restore-from"
  fi
  dataset="$(env_value "$backup" ZPOOL)/$(env_value "$backup" TOP_LEVEL_DATASET)"
  zfs list "$dataset" >/dev/null 2>&1 || die "$backup uses $dataset, which no longer exists"
  echo "This stops the stack on $LIVE_DATASET and restarts it on $dataset using $backup."
  confirm "Roll back now?"
  compose "$LIVE_ENV" down
  cp -p "$backup" "$LIVE_ENV"
  compose "$LIVE_ENV" up -d
  echo "Rolled back to $dataset.  $LIVE_DATASET is kept; destroy it yourself when no longer needed."
}

case $COMMAND in
  check)
    check 0
    [ "$FAILURES" -eq 0 ]
    ;;
  prepare) prepare ;;
  boot-check) boot_check ;;
  swap) swap ;;
  rollback) rollback ;;
  *) print_help; exit 1 ;;
esac
