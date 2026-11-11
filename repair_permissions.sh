#!/bin/sh

set -e

print_help() {
  echo "Usage: $0 [--env-file=filename] [--data-dir=path] [--fix-zfs]"
  echo "  Repairs ownership and permissions for all HAF directories, then, when the data"
  echo "  directory is a ZFS dataset, reports dataset properties that differ from the layout"
  echo "  create_zfs_datasets.sh creates (zfs_dataset_layout.sh)"
  echo "  --env-file=filename  Use specified environment file instead of .env"
  echo "  --data-dir=path      Base directory for HAF data (overrides environment)"
  echo "  --fix-zfs            Also apply the property fixes that are safe on a live datadir:"
  echo "                       compression, atime, and canmount=off on a dataset that is not mounted"
}

if ! OPTIONS=$(getopt -o he:d: --long env-file:,help,data-dir:,zpool:,top-level-dataset:,fix-zfs -n "$0" -- "$@"); then
    print_help
    exit 1
fi

# Don't clear if already set in environment
[ -z "$ZPOOL" ] && ZPOOL=""
[ -z "$TOP_LEVEL_DATASET" ] && TOP_LEVEL_DATASET=""
[ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT=""
[ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT=""
FIX_ZFS=false

eval set -- "$OPTIONS"

while true; do
  case $1 in
    --env-file|-e)
      ENV_FILE="$2"
      shift 2
      ;;
    --data-dir|-d)
      TOP_LEVEL_DATASET_MOUNTPOINT="$2"
      shift 2
      ;;
    --zpool)
      ZPOOL="$2"
      shift 2
      ;;
    --top-level-dataset)
      TOP_LEVEL_DATASET="$2"
      shift 2
      ;;
    --fix-zfs)
      FIX_ZFS=true
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    --)
      shift
      break
      ;;
  esac
done

# If TOP_LEVEL_DATASET_MOUNTPOINT was provided via --data-dir, we can skip the rest
if [ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ]; then
  if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
    if [ -n "$ENV_FILE" ]; then
      echo "Reading $ENV_FILE"
      # shellcheck disable=SC1090
      . "$ENV_FILE"
    elif [ -f .env ]; then
      echo "Reading configuration from .env"
      # shellcheck disable=SC1091
      . ./.env
    else
      echo "You must either provide a --data-dir argument, an --env-file argument, or both"
      echo "a --zpool and --top-level-dataset argument to tell this script where to repair permissions."
      exit 1
    fi
  fi

  if [ -z "$ZPOOL" ] || [ -z "$TOP_LEVEL_DATASET" ]; then
    echo "Your environment file must define the ZPOOL and TOP_LEVEL_DATASET environment variables"
    exit 1
  fi

  [ -z "$ZPOOL_MOUNT_POINT" ] && ZPOOL_MOUNT_POINT="/$ZPOOL"
  [ -z "$TOP_LEVEL_DATASET_MOUNTPOINT" ] && TOP_LEVEL_DATASET_MOUNTPOINT="${ZPOOL_MOUNT_POINT}/${TOP_LEVEL_DATASET}"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

echo "Repairing permissions for HAF directories"
if [ -n "$TOP_LEVEL_DATASET" ]; then
  echo "Top-level dataset: $TOP_LEVEL_DATASET"
fi
echo "Data directory:    $TOP_LEVEL_DATASET_MOUNTPOINT"
echo ""

# Default ownership for most directories
# HIVED_UID defaults to 1000, matching hived:users inside the container
echo "Setting ownership for general HAF directories..."
mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/shared_memory/comments-rocksdb-storage"
chown -R "${HIVED_UID:-1000}:${HIVED_UID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT"

# PostgreSQL-specific ownership
# 105:109 is postgres:postgres inside the container
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store" ]; then
  echo "Setting ownership for PostgreSQL directories..."
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_db_store"
fi

# PostgreSQL configuration directory
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d" ]; then
  echo "Setting ownership for PostgreSQL configuration..."
  chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/haf_postgresql_conf.d"
fi

# Log directories with specific ownership
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs" ]; then
  echo "Setting ownership for log directories..."
  chown -R "${HIVED_UID:-1000}:${HIVED_UID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT/logs"
  
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql" ]; then
    chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/postgresql"
  fi
  
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger" ]; then
    chown -R 105:109 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/pgbadger"
  fi

  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/haproxy" ]; then
    chown -R 99:99 "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/haproxy"
  fi

  # Monitoring directories (Prometheus, Grafana, Loki)
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/monitoring" ]; then
    chown -R "${HAF_UID:-1000}:${HAF_GID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT/logs/monitoring"
  fi
fi

# Hivesense directories (if they exist)
if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense" ]; then
  echo "Setting ownership for hivesense directories..."
  
  # Ollama needs root:root as it runs as root by default
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama" ]; then
    echo "  Setting ollama directory to root:root..."
    chown -R 0:0 "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/ollama"
  fi
  
  # PCA and config directories use standard hived user
  if [ -d "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca" ]; then
    echo "  Setting pca directory to hived user..."
    chown -R "${HIVED_UID:-1000}:${HIVED_UID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/pca"
  fi
  
  # Pre-create config directory if missing (hivesense install downloads files here)
  mkdir -p "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"
  echo "  Setting config directory to hived user..."
  chown -R "${HIVED_UID:-1000}:${HIVED_UID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense/config"

  # Set the parent directory
  chown "${HIVED_UID:-1000}:${HIVED_UID:-1000}" "$TOP_LEVEL_DATASET_MOUNTPOINT/hivesense"
fi

echo "Permission repair complete!"

######### ZFS dataset properties #########

# Prints "<fstype> <source> <mountpoint>" of the mount DIR lies on, from /proc/mounts
mount_of() {
  awk -v dir="$1" '
    { mp = $2; gsub(/\\040/, " ", mp) }
    mp == dir || mp == "/" || index(dir, mp "/") == 1 {
      if (length(mp) > best) { best = length(mp); found = $3 " " $1 " " mp }
    }
    END { if (best) print found }' /proc/mounts
}

# Prints the ZFS dataset holding the data directory, or nothing when it is not on ZFS.
# No zfs command runs unless the data directory lies on a ZFS filesystem.
datadir_dataset() {
  [ -r /proc/mounts ] || return 0
  datadir=$(cd "$TOP_LEVEL_DATASET_MOUNTPOINT" && pwd -P)
  read -r fstype source mountpoint <<MOUNT
$(mount_of "$datadir")
MOUNT
  [ "$fstype" = zfs ] || return 0
  if [ "$mountpoint" = "$datadir" ]; then
    echo "$source"
  # the top-level dataset exists but is not mounted on the data directory
  elif [ -n "$ZPOOL" ] && [ -n "$TOP_LEVEL_DATASET" ] &&
       [ "$(zfs get -H -o value mountpoint "$ZPOOL/$TOP_LEVEL_DATASET" 2>/dev/null)" = "$datadir" ]; then
    echo "$ZPOOL/$TOP_LEVEL_DATASET"
  fi
}

# Prints the zfs commands that set canmount=off on a mounted DATASET: unmount its mounted
# descendants leaf-first and the dataset itself, set the property, remount the descendants parent-first
print_canmount_off_sequence() {
  dataset=$1
  descendants=$(zfs list -r -H -o name,mounted -t filesystem "$dataset" | awk -v ds="$dataset" '$1 != ds && $2 == "yes" { print $1 }')
  echo "    --fix-zfs leaves this to you, as $dataset is mounted. With the stack stopped, and after checking that $dataset"
  echo "    holds nothing but its children's mountpoints (anything else is hidden once it is unmounted), run:"
  echo "$descendants" | awk 'NF { line[n++] = $0 } END { while (n) print "      zfs unmount " line[--n] }'
  echo "      zfs unmount $dataset"
  echo "      zfs set canmount=off $dataset"
  echo "$descendants" | awk 'NF { print "      zfs mount " $0 }'
}

# Compares the datasets under TOP with zfs_dataset_layout and reports (with --fix-zfs, applies)
# the differences. Returns non-zero only when a zfs set failed.
check_zfs_layout() {
  top=$1
  deviations=0
  fixed=0
  failed=0
  compression_deviates=false
  echo ""
  echo "Checking ZFS dataset properties of $top against zfs_dataset_layout.sh..."
  layout=$(zfs_dataset_layout)
  while read -r relative_dataset presence properties <&3; do
    dataset=$top
    [ "$relative_dataset" = . ] || dataset="$top/$relative_dataset"
    if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
      if [ "$presence" = required ]; then
        deviations=$((deviations + 1))
        # shellcheck disable=SC2086 # one word per property
        echo "  $dataset: missing; create it with: zfs create$(printf ' -o %s' $properties) $dataset"
      fi
      continue
    fi
    mounted=$(zfs get -H -o value mounted "$dataset")
    canmount_deviates=false
    for property in $properties; do
      name=${property%%=*}
      expected=${property#*=}
      actual=$(zfs get -H -o value "$name" "$dataset")
      [ "$actual" = "$expected" ] && continue
      # OpenZFS maps compression=on to lz4
      [ "$name" = compression ] && [ "$expected" = lz4 ] && [ "$actual" = on ] && continue
      deviations=$((deviations + 1))
      echo "  $dataset: $name=$actual, expected $name=$expected; fix: zfs set $name=$expected $dataset"
      case "$name" in
        compression|atime)
          [ "$name" = compression ] && compression_deviates=true
          apply=$FIX_ZFS
          ;;
        canmount)
          canmount_deviates=true
          apply=false
          if [ "$expected" = off ] && [ "$mounted" = yes ]; then
            print_canmount_off_sequence "$dataset"
          elif [ "$expected" = off ]; then
            apply=$FIX_ZFS
          elif [ "$FIX_ZFS" = true ]; then
            echo "    not applied: --fix-zfs only sets canmount=off"
          fi
          ;;
        *)
          apply=false
          ;;
      esac
      if [ "$apply" = true ]; then
        if zfs set "$name=$expected" "$dataset"; then
          fixed=$((fixed + 1))
          echo "    applied"
        else
          failed=1
          echo "    FAILED: zfs set $name=$expected $dataset"
        fi
      fi
    done
    # a receive interrupted part-way leaves datasets unmounted (or parents mounted)
    if [ "$canmount_deviates" = false ]; then
      canmount=$(zfs get -H -o value canmount "$dataset")
      if [ "$canmount" = on ] && [ "$mounted" != yes ]; then
        deviations=$((deviations + 1))
        echo "  $dataset: canmount=on but not mounted; mount it with: zfs mount $dataset"
      elif [ "$canmount" = off ] && [ "$mounted" = yes ]; then
        deviations=$((deviations + 1))
        echo "  $dataset: canmount=off but mounted; unmount it (its mounted children first) with the stack stopped"
      fi
    fi
  done 3<<LAYOUT
$layout
LAYOUT

  if [ "$deviations" -eq 0 ]; then
    echo "ZFS dataset properties match the expected layout."
    return 0
  fi
  if [ "$FIX_ZFS" = true ]; then
    echo "$deviations deviation(s) from the expected layout, $fixed fixed."
  else
    echo "$deviations deviation(s) from the expected layout; nothing was changed. Rerun with --fix-zfs to apply"
    echo "the compression and atime fixes, and canmount=off on datasets that are not mounted."
  fi
  if [ "$compression_deviates" = true ]; then
    echo "Note: a compression change only affects data written afterwards; existing blocks keep their compression."
  fi
  return "$failed"
}

ZFS_DATASET=$(datadir_dataset)
if [ -n "$ZFS_DATASET" ]; then
  LAYOUT_FILE="$(dirname "$0")/zfs_dataset_layout.sh"
  if [ -f "$LAYOUT_FILE" ]; then
    # shellcheck source=zfs_dataset_layout.sh
    . "$LAYOUT_FILE"
    if ! check_zfs_layout "$ZFS_DATASET"; then
      echo "Error: some ZFS property fixes failed"
      exit 1
    fi
  else
    echo ""
    echo "Skipping the ZFS property check: $LAYOUT_FILE not found"
  fi
fi
