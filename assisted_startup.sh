#!/bin/bash
# Startup with a snapshot
# After installing zfs and docker prequisites, run this script to configure the rest of the system
# This script will aid in the .env setup, and will automatically create a zpool and zfs datasets if needed

# Container UID/GID for hived process (2001 on modern builds, was 1000 on older)
HIVED_UID=2001
HIVED_GID=2001

# Ramdisk size configuration
RAMDISK_SIZE_GB=7  # Default ramdisk size in GB (for shared_memory.bin only)

# Mode detection variables
HIVE_MODE=0  # Flag to track if we're using hive profile (0=HAF mode, 1=Hive mode)
SERVICE_NAME=""  # Will be set to either "haf" or "hive"
SYNC_MESSAGE=""  # Will be set to appropriate sync detection string

# Memory thresholds for optimization selection
RAMDISK_MIN_MEMORY_GB=$((RAMDISK_SIZE_GB + 33))  # Minimum RAM for ramdisk approach
REDUCE_WRITEBACKS_MIN_MEMORY_GB=35                # Minimum RAM for reduce_writebacks approach

for arg in "$@"; do
    case $arg in
        --no-ramdisk)
            NO_RAMDISK=1
            ;;
        --force-reduce-writebacks)
            FORCE_REDUCE_WRITEBACKS=1
            ;;
        --no-optimizations)
            NO_OPTIMIZATIONS=1
            ;;
        --no-autoswap)
            NO_AUTOSWAP=1
            ;;
        --replay)
            REPLAY=1
            ;;
        --snapshot-name)
            SNAPSHOT_NAME=$2
            shift
            ;;
        --skip-disk-size-reqt)
            SKIP_DISK_SIZE_REQT=1
            ;;
        --help)
            echo "Usage: assisted_startup.sh [OPTIONS]"
            echo ""
            echo "Performance optimization options:"
            echo "  --no-ramdisk: Do not use a RAM disk (will use reduce_writebacks if available)"
            echo "  --force-reduce-writebacks: Force use reduce_writebacks optimization"
            echo "  --no-optimizations: Disable all performance optimizations"
            echo ""
            echo "Other options:"
            echo "  --no-autoswap: Do not automatically grow swap"
            echo "  --replay: Replay the blockchain, use only on first run, and not rerun if this script exits before snapshot"
            echo "  --skip-disk-size-reqt: Do not stop the script if less than 4T disk partitions found"
            echo "  --snapshot-name NAME: Name of the snapshot to use. default first_sync"
            echo ""
            echo "Memory requirements:"
            echo "  - Ramdisk optimization: ${RAMDISK_MIN_MEMORY_GB}GB+ RAM"
            echo "  - reduce_writebacks optimization: ${REDUCE_WRITEBACKS_MIN_MEMORY_GB}GB+ RAM"
            echo "  - No optimization: Any amount (but slower sync)"
            exit 0
            ;;
        *)
            # Handle other arguments as needed
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

touch startup.temp

# Get or remove data if rerunning the script after a premature exit

if [[ $REPLAY == 1 ]]; then
    rm -f startup.temp
else
    # Source startup.temp if it exists, this will restore mode variables
    if [[ -f startup.temp ]]; then
        source startup.temp
    fi
fi

if command -v zfs >/dev/null 2>&1; then
    echo "Verifying Prerequisites..."
else
    echo "ZFS is not installed on your system."
    exit 1
fi

if command -v docker >/dev/null 2>&1; then
    echo "Prerequisites verified."
else
    echo "Docker is not installed on your system."
    exit 1
fi

# if no snapshot name is provided, use the default
if [[ $SNAPSHOT_NAME == "" ]]; then
    SNAPSHOT_NAME="first_sync"
fi

echo "SNAPSHOT_NAME=$SNAPSHOT_NAME" >> startup.temp

if [[ $REPLAY == 1 && $SNAPSHOT_NAME == "first_sync" ]]; then
    zfs list -H -o name -t snapshot | xargs -n1 zfs destroy -r first_sync
fi

if [ ! -f .env ]; then
    echo ".env not found. Performing first time setup..."
    cp .env.example .env
    source .env

    # Ask about mode first
    echo "Choose your deployment mode:"
    echo "1. Traditional HAF mode - Full HAF stack with database and applications"
    echo "2. Hive mode - Lightweight hived-only deployment without database"
    read -p "Select mode (1 for HAF, 2 for Hive): " mode_choice

    if [[ "$mode_choice" == "2" ]]; then
        # Hive mode setup
        echo "Setting up Hive mode..."
        HIVE_MODE=1
        NEW_PROFILES="hive"
        sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
        source .env

        # Optional: ask about price_feed profile
        read -p "Add price_feed profile? (Y or N): " choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Adding price_feed to profiles..."
            NEW_PROFILES="${COMPOSE_PROFILES},price_feed"
            sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
            source .env
        fi
    else
        # Traditional HAF mode setup
        echo "Setting up traditional HAF mode..."
        echo "PROFILES are the list of HAF services you want to run. The default is $COMPOSE_PROFILES."
        echo "core: the minimal HAF system of a database and hived"
        echo "admin: useful tools for administrating HAF: pgadmin, pghero"
        echo "apps: core HAF apps: hivemind, hafah, hafbe (balance-tracker is a subapp)"
        echo "servers: services for routing/caching API calls: haproxy, jussi/drone (JSON caching), varnish (REST caching)"
        read -p "Run admin? (Y or N): " choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Adding admin to profiles..."
            NEW_PROFILES="core,admin"
            sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
            source .env
        else
            NEW_PROFILES="core"
            sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
            source .env
        fi
        echo $COMPOSE_PROFILES
        read -p "Run all apps? (Y or N): " choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Adding apps to profiles..."
            NEW_PROFILES="${COMPOSE_PROFILES},apps"
            echo $NEW_PROFILES
            sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
            source .env
        else
            read -p "Run hivemind? (Y or N): " choice
            if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                echo "Adding hivemind to profiles..."
                NEW_PROFILES="${COMPOSE_PROFILES},hivemind"
                echo $NEW_PROFILES
                sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
                source .env
            fi
            read -p "Run hafah? (Y or N): " choice
            if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                echo "Adding hafah to profiles..."
                NEW_PROFILES="${COMPOSE_PROFILES},hafah"
                echo $NEW_PROFILES
                sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
                source .env
            fi
            read -p "Run hafbe? (Y or N): " choice
            if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                echo "Adding hafbe to profiles..."
                NEW_PROFILES="${COMPOSE_PROFILES},hafbe"
                echo $NEW_PROFILES
                sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
                source .env
            fi
            read -p "Run balance-tracker? (Y or N): " choice
            if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                echo "Adding balance-tracker to profiles..."
                NEW_PROFILES="${COMPOSE_PROFILES},balance-tracker"
                echo $NEW_PROFILES
                sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
                source .env
            fi
        fi
        read -p "Run servers? (Y or N): " choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Adding servers to profiles..."
            NEW_PROFILES="${COMPOSE_PROFILES},servers"
            echo $NEW_PROFILES
            sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES=\"$NEW_PROFILES\"/g" .env
            source .env
        fi
    fi  # End of mode choice (HAF vs Hive)
    read -p "What is your public hostname? (api.hive.blog) Leave blank if none: " choice
    if [[ "$choice" != "" ]]; then
        echo "Configuring $choice..."
        sed -i "s/PUBLIC_HOSTNAME=\"$PUBLIC_HOSTNAME\"/PUBLIC_HOSTNAME=\"$choice\"/g" .env
        source .env
        echo "Caddy may attempt to get a real SSL certificate for $PUBLIC_HOSTNAME from LetsEncrypt."
        echo "If this server is behind a firewall or NAT, or $PUBLIC_HOSTNAME is misconfigured,"
        echo "it will fail to get a certificate, and that will count against LetsEncrypt's rate limits."
        read -p "Automate SSL for $PUBLIC_HOSTNAME? (Y or N)" choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Automating SSL with Caddy..."
            # Add CADDY_TLS_SELF_SIGNED=false to enable LetsEncrypt
            if grep -q "^CADDY_TLS_SELF_SIGNED=" .env; then
                sed -i "s:^CADDY_TLS_SELF_SIGNED=.*:CADDY_TLS_SELF_SIGNED=false:g" .env
            elif grep -q "^# CADDY_TLS_SELF_SIGNED=" .env; then
                sed -i "s:^# CADDY_TLS_SELF_SIGNED=.*:CADDY_TLS_SELF_SIGNED=false:g" .env
            else
                echo "CADDY_TLS_SELF_SIGNED=false" >> .env
            fi
            source .env
        fi
    fi
    echo "If you want to change more options, edit .env manually now and rerun this script."
fi

source .env

# Detect which mode we're in based on COMPOSE_PROFILES
if [[ "$COMPOSE_PROFILES" == *"hive"* ]]; then
    HIVE_MODE=1
    SERVICE_NAME="hive"
    SYNC_MESSAGE="entering live mode"
    echo "Detected Hive mode from profiles: $COMPOSE_PROFILES"
else
    HIVE_MODE=0
    SERVICE_NAME="haf"
    SYNC_MESSAGE="PROFILE: Entered LIVE sync"
    echo "Detected HAF mode from profiles: $COMPOSE_PROFILES"
fi

# Save mode to temp file for reruns
echo "HIVE_MODE=$HIVE_MODE" >> startup.temp
echo "SERVICE_NAME=$SERVICE_NAME" >> startup.temp
echo "SYNC_MESSAGE=\"$SYNC_MESSAGE\"" >> startup.temp

zfs list | grep $ZPOOL &> /dev/null
if [[ $? == 1 ]]; then
    echo "zpool hasn't been created."
    # Find NVME drives without file systems
    NVME_DRIVES=$(lsblk  --noheadings --fs | awk '$1~/nvme.*[[:digit:]]/ && $2==""' | sed 's/└─\|├─//g' | awk '{print $1}' | grep -v "p")
    # Find NVME partitions
    NVME_PARTITIONS=$(lsblk  --noheadings --fs | awk '$1~/nvme.*[[:digit:]]/' | sed 's/└─\|├─//g' | awk '{print $1}' | grep "p")
    # Remove NVME drives with partitions
    for drive in $NVME_DRIVES; do
        FOUND=$(echo $NVME_PARTITIONS | grep "$drive")
        if [[ $FOUND != "" ]]; then
            NVME_DRIVES=$(echo $NVME_DRIVES | sed "s/$drive//g")
        fi
    done
    NVME_PARTITIONS=$(lsblk  --noheadings --fs | awk '$1~/nvme.*[[:digit:]]/ && $2==""' | sed 's/└─\|├─//g' | awk '{print $1}' | grep "p")
    echo "Available NVME drives: $NVME_DRIVES"
    echo "Available NVME partitions: $NVME_PARTITIONS"
    TOTAL_SPACE=0
    # count free space on NVME drives
    echo $NVME_DRIVES
    MSG=""
    NVMES=""
    CALLSTRING="zpool create $ZPOOL "
    for drive in $NVME_DRIVES; do
        echo "Checking $drive..."
        free_space=$(lsblk /dev/$drive -b | awk 'NR==2 {print $4}' )
        if [[ $free_space -gt 1000000000 ]]; then
            NVMES+="$drive "
            TOTAL_SPACE=$(( $TOTAL_SPACE + $free_space ))
            MSG+="Found: $drive with $free_space bytes of free space.\n"
            CALLSTRING+="/dev/$drive "
        else
            echo "Drive $drive has less than 1G of free space. Skipping..."
        fi
    done
    # count free space on NVME partitions
    for partition in $NVME_PARTITIONS; do
        echo "Checking $partition..."
        free_space=$(lsblk /dev/$partition -b | awk 'NR==2 {print $4}' )
        if [[ $free_space -gt 1000000000 ]]; then
            NVMES+="$partition "
            TOTAL_SPACE=$(( $TOTAL_SPACE + $free_space ))
            MSG+="Found: $partition with $free_space Bytes of free space.\n"
            CALLSTRING+="/dev/$partition "
        else
            echo "Partition $partition has less than 1G of free space. Skipping..."
        fi
    done
    if [[ $NVMES == "" ]]; then
        echo "No NVME drives found. Please manually create a zpool."
        exit 1
    fi
    #only bail out if user did not choose to skip min disk size reqt
    if [[ $SKIP_DISK_SIZE_REQT != 1 && $TOTAL_SPACE -lt 4000000000000 ]]; then
        echo "Less than 4T of free space found. Please manually create a zpool."
        exit 1
    fi
    echo "Total free space on NVMEs: $(( $TOTAL_SPACE / 1000000000 )) G"
    echo "Found NVME devices: $NVMES"
    echo "$CALLSTRING"
    read -p "Create a zpool with these drives? (Y or N): " choice
    if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
        echo "Creating zpool..."
        $CALLSTRING
        if [[ $? == 0 ]]; then
            echo "zpool created successfully."
        else
            echo "zpool creation failed."
            exit 1
        fi
    else
        echo "Please manually create a zpool."
        exit 1
    fi
fi

zfs list | grep $ZPOOL/$TOP_LEVEL_DATASET &> /dev/null
if [[ $? == 1 ]]; then
    echo "Creating zfs datasets"
    ./create_zfs_datasets.sh
fi

zfs list -t snapshot "${ZPOOL}/${TOP_LEVEL_DATASET}@${SNAPSHOT_NAME}" &> /dev/null
if [[ $? == 0 ]]; then
    echo "Snapshot found. Nothing to do. Use --snapshot-name to specify a different snapshot."
    exit 0
fi

if [[ $REPLAY == 1 ]]; then
    sed -i 's/^ARGUMENTS=""/ARGUMENTS="--replay-blockchain"/g' .env
fi

if docker compose ps | grep $SERVICE_NAME | grep Up > /dev/null 2>&1; then
    echo "Docker Compose is up and running."
else
    echo "Setting Up Startup..."
    if [[ $original_line == "" ]]; then
        # Optimize the system for replaying the blockchain

        physical_memory=$(free -g | awk '/^Mem:/{print $2}')
        free_memory=$(free -g | awk '/^Mem:/{print $4}')
        swap_memory=$(free -g | awk '/^Swap:/{print $2}')
        free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed "s/G//g")
        swap_type=$(swapon --show=TYPE --noheadings)
        swap_location=$(swapon --show=NAME --noheadings)


        # Determine optimization method
        OPTIMIZATION_METHOD=""

        if [[ $NO_OPTIMIZATIONS == 1 ]]; then
            OPTIMIZATION_METHOD="none"
            echo "Performance optimizations disabled by user (--no-optimizations)"
        elif [[ $FORCE_REDUCE_WRITEBACKS == 1 ]]; then
            OPTIMIZATION_METHOD="reduce_writebacks"
            echo "Using reduce_writebacks optimization (--force-reduce-writebacks)"
        elif [[ $physical_memory -ge $RAMDISK_MIN_MEMORY_GB && $free_memory -gt $((RAMDISK_SIZE_GB + 5)) && $NO_RAMDISK != 1 ]]; then
            OPTIMIZATION_METHOD="ramdisk"
            echo "Sufficient memory detected (${physical_memory}GB). Using ramdisk optimization..."
        elif [[ $physical_memory -ge $REDUCE_WRITEBACKS_MIN_MEMORY_GB ]]; then
            OPTIMIZATION_METHOD="reduce_writebacks"
            if [[ $NO_RAMDISK == 1 ]]; then
                echo "Using reduce_writebacks optimization (--no-ramdisk specified)..."
            else
                echo "Using reduce_writebacks optimization (insufficient memory for ramdisk)..."
            fi
        elif [[ $physical_memory -lt $REDUCE_WRITEBACKS_MIN_MEMORY_GB ]]; then
            echo "WARNING: Only ${physical_memory}GB RAM detected. Recommended minimum:"
            echo "  - ${RAMDISK_MIN_MEMORY_GB}GB for ramdisk optimization"
            echo "  - ${REDUCE_WRITEBACKS_MIN_MEMORY_GB}GB for reduce_writebacks optimization"
            read -p "Try reduce_writebacks anyway? (y/N): " choice
            if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                OPTIMIZATION_METHOD="reduce_writebacks"
            else
                OPTIMIZATION_METHOD="none"
            fi
        else
            OPTIMIZATION_METHOD="none"
            echo "No performance optimizations will be applied"
        fi

        # Apply chosen optimization
        if [[ $OPTIMIZATION_METHOD == "ramdisk" ]]; then
            echo "Mounting ${RAMDISK_SIZE_GB}GB ramdisk for shared_memory.bin only..."
            if [ ! -d "/mnt/haf_shared_mem" ]; then
                mkdir /mnt/haf_shared_mem
            fi
            # Unmount any leftover ramdisk from a previous interrupted run
            if mountpoint -q /mnt/haf_shared_mem; then
                echo "WARNING: /mnt/haf_shared_mem is already mounted (leftover from previous run), unmounting..."
                umount /mnt/haf_shared_mem
            fi
            mount -t tmpfs -o size=${RAMDISK_SIZE_GB}g tmpfs /mnt/haf_shared_mem
            chown $HIVED_UID:$HIVED_GID /mnt/haf_shared_mem

            # Ensure RocksDB directories exist on disk
            mkdir -p /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/comments-rocksdb-storage
            chown $HIVED_UID:$HIVED_GID /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/comments-rocksdb-storage

            remove_shared_mem=$RAMDISK_SIZE_GB
        elif [[ $OPTIMIZATION_METHOD == "reduce_writebacks" ]]; then
            echo "Applying reduce_writebacks optimization..."
            if ./reduce_writebacks.sh; then
                echo "reduce_writebacks optimization applied successfully"
            else
                echo "WARNING: Failed to apply reduce_writebacks optimization"
                OPTIMIZATION_METHOD="none"
            fi
            remove_shared_mem=0
        else
            remove_shared_mem=0
        fi

        echo "Available Memory: $(( physical_memory - remove_shared_mem + swap_memory ))G"
        echo "Current swapsize: $swap_memory"
        echo "64G of memory is recommended, with at least 8G of swap"
        echo "This script will attempt to allocate aditional swap if needed"

        # write variables to a temp file
        echo "remove_shared_mem=$remove_shared_mem" > startup.temp
        echo "OPTIMIZATION_METHOD=$OPTIMIZATION_METHOD" >> startup.temp

        # Track what lines we added (vs modified) so we can remove them later
        added_lines=""
        modified_lines=""
        added_rocksdb_arg=""

        # Modify the .env file to use only the appropriate startup profile based on mode
        while IFS= read -r line; do
            if [[ $line == COMPOSE_PROFILES=* ]]; then
                original_line="$line"
                if [[ $HIVE_MODE == 1 ]]; then
                    modified_line="COMPOSE_PROFILES=\"hive\""
                else
                    modified_line="COMPOSE_PROFILES=\"core,admin\""
                fi
                # Print the original and modified lines
                echo "Intended Profiles: $original_line"
                echo "Startup Profiles: $modified_line"
            fi
            # We'll handle HAF_SHM_DIRECTORY outside the loop
            # since it might not exist in the file

            if [[ $line == ARGUMENTS=* && ($line == *--replay-blockchain* || $line == *--force-replay*) ]]; then
                original_arguments="$line"
                modified_arguments=$(echo "$line" | sed -E "s/(--replay-blockchain|--force-replay)//g" | sed -E 's/="[[:space:]]+/="/g' | sed -E 's/[[:space:]]+"/"/g' | sed -E 's/([[:space:]])[[:space:]]+/\1/g')
                echo "Using: $original_arguments"
                echo "After Sync will use: $modified_arguments"
                echo "If this isn't desired, manually change the arguments in .env before the sync is finished"
            fi
        done < .env

        # Use grep -v and echo to avoid sed quoting issues
        grep -v "^COMPOSE_PROFILES=" .env > .env.tmp
        echo "${modified_line}" >> .env.tmp
        mv .env.tmp .env

        # Handle optional HAF_SHM_DIRECTORY and HAF_ROCKSDB_DIRECTORY
        if [[ $OPTIMIZATION_METHOD == "ramdisk" ]]; then
            # Check if HAF_SHM_DIRECTORY exists
            if grep -q "^HAF_SHM_DIRECTORY=" .env; then
                # Variable exists, modify it
                original_HAF_SHM=$(grep "^HAF_SHM_DIRECTORY=" .env)
                modified_HAF_SHM="HAF_SHM_DIRECTORY=\"/mnt/haf_shared_mem\""
                sed -i "s#^$original_HAF_SHM#$modified_HAF_SHM#g" .env
                echo "original_HAF_SHM=$original_HAF_SHM" >> startup.temp
                echo "modified_HAF_SHM=$modified_HAF_SHM" >> startup.temp
                echo "modified_HAF_SHM_EXISTS=1" >> startup.temp
            else
                # Variable doesn't exist, add it
                echo "HAF_SHM_DIRECTORY=\"/mnt/haf_shared_mem\"" >> .env
                echo "added_HAF_SHM=1" >> startup.temp
                added_lines="${added_lines}HAF_SHM_DIRECTORY\n"
            fi

            # Check if HAF_ROCKSDB_DIRECTORY exists
            if grep -q "^HAF_ROCKSDB_DIRECTORY=" .env; then
                # Variable exists, save original
                original_HAF_ROCKSDB=$(grep "^HAF_ROCKSDB_DIRECTORY=" .env)
                echo "original_HAF_ROCKSDB=$original_HAF_ROCKSDB" >> startup.temp
                echo "HAF_ROCKSDB_EXISTS=1" >> startup.temp
            else
                # Variable doesn't exist, add it
                echo "HAF_ROCKSDB_DIRECTORY=\"/$ZPOOL/$TOP_LEVEL_DATASET/shared_memory\"" >> .env
                echo "added_HAF_ROCKSDB=1" >> startup.temp
                added_lines="${added_lines}HAF_ROCKSDB_DIRECTORY\n"
            fi

            # Add rocksdb path to ARGUMENTS
            current_args=$(grep "^ARGUMENTS=" .env | sed 's/ARGUMENTS=//' | sed 's/^"//' | sed 's/"$//')
            rocksdb_arg="--comments-rocksdb-path=/home/hived/rocksdb_dir/comments-rocksdb-storage"

            if [[ -z "$current_args" || "$current_args" == '""' || "$current_args" == "" ]]; then
                new_args="\"$rocksdb_arg\""
            else
                new_args="\"${current_args} ${rocksdb_arg}\""
            fi

            original_rocksdb_arguments=$(grep "^ARGUMENTS=" .env)
            # Use grep -v and echo to avoid sed quoting issues
            grep -v "^ARGUMENTS=" .env > .env.tmp
            echo "ARGUMENTS=${new_args}" >> .env.tmp
            mv .env.tmp .env

            echo "original_rocksdb_arguments=$original_rocksdb_arguments" >> startup.temp
            echo "added_rocksdb_arg=1" >> startup.temp
            added_rocksdb_arg="1"
        fi

        echo "original_line=$original_line" >> startup.temp
        echo "modified_line=$modified_line" >> startup.temp

        # Save what lines we added vs modified
        echo "added_lines=$added_lines" >> startup.temp

        if [[ $original_arguments != "" ]]; then
            echo "original_arguments=$original_arguments" >> startup.temp
            echo "modified_arguments=$modified_arguments" >> startup.temp
        fi

    fi

    if ! docker compose up -d; then
      echo "Docker containers did not start successfully, aborting..."
      exit 1
    fi

fi

source .env

max_mem=$(free -g | awk '/^Mem:/{print $3}')
max_swap=$(free -g | awk '/^Swap:/{print $3}')
echo "max_mem=$max_mem" >> startup.temp
echo "max_swap=$max_swap" >> startup.temp
# Monitor the output for the desired phrase


entered_livesync=0
while read -r line; do
    if [[ $line == *"Block"* ]]; then
        echo "$line"
        mem_state=$(free -g | awk '/^Mem:/{print $3}')
        swap_state=$(free -g | awk '/^Swap:/{print $3}')
        free_swap=$(free -g | awk '/^Swap:/{print $4}')
	previous_max_mem=$(grep "max_mem=" startup.temp | sed "s/max_mem=//g")
	previous_max_swap=$(grep "max_swap=" startup.temp | sed "s/max_swap=//g")
        if [[ $mem_state -gt $max_mem ]]; then
            # Track the max memory usage in startup.temp
            sed -i "s/max_mem=$max_mem/max_mem=$mem_state/g" startup.temp
            max_mem=$mem_state
        fi
        if [[ $swap_state -gt $max_swap ]]; then
            max_swap=$swap_state
            sed -i "s/max_swap=$max_swap/max_swap=$swap_state/g" startup.temp
        fi
        if [[ $free_swap -lt 2 && $NO_AUTOSWAP != 1 && $making_swap != 1 ]]; then
            free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed "s/G//g")
            if [[ $free_space -gt 40 ]]; then
                making_swap=1

                echo "Swap is almost  full. Adding a swapfile..."
                echo "Making swap file..."
                if [[ $swap_type == "file" ]]; then
                    swap_files=$(grep -E '^/[^ ]+' /proc/swaps | awk '{print $1}')
                    for file in $swap_files; do
                        lowest_priority_file=$file
                    done
                else
                    lowest_priority_file="/swapfile"
                    swap_type="file"
                fi
                dd if=/dev/zero of=$lowest_priority_file+ count=32K  bs=1M
                chmod 600 $lowest_priority_file+
                mkswap $lowest_priority_file+
                swapon $lowest_priority_file+
                making_swap=0
                made_swap=1
            else
                echo "Swap is nearly full."
            fi

        fi
    fi
    if [[ $line == *"$SYNC_MESSAGE"* ]]; then
        echo "Detected *$SYNC_MESSAGE* in the output. Bringing down Docker Compose..."
        entered_livesync=1
        # Write Sync time to "haf.log" for tracking, as this log will get wiped on restart
        # Only generate haf.log for HAF mode (PROFILE statements are HAF-specific)
        if [[ $HIVE_MODE == 0 ]]; then
            docker compose logs $SERVICE_NAME | grep PROFILE > haf.log
            # Write max memory and swap usage to "haf.log" for tracking
            grep "max_mem=" startup.temp >> haf.log
            grep "max_swap=" startup.temp >> haf.log
        fi
        echo "Checkpointing the database before shutdown..."
        docker compose exec haf psql -U haf_admin -d haf_block_log -c "CHECKPOINT;"
        docker compose down
        break
    fi
done < <(docker compose logs -f)

if [ $entered_livesync -eq 0 ]; then
  echo "Failed to enter livesync, aborting..."
  exit 1
fi

# prevent script completion if interupt sent to above loop

if docker compose ps | grep $SERVICE_NAME | grep Up >/dev/null 2>&1; then
    echo "Docker Compose is still running."
else
    # Load optimization method from startup.temp
    source startup.temp

    # Restore the original COMPOSE_PROFILES line
    # Use grep -v and echo to avoid sed quoting issues
    grep -v "^COMPOSE_PROFILES=" .env > .env.tmp
    echo "${original_line}" >> .env.tmp
    mv .env.tmp .env

    # Restore optimization settings based on method used
    if [[ $OPTIMIZATION_METHOD == "ramdisk" && $remove_shared_mem != 0 ]]; then
        # Restore HAF_SHM_DIRECTORY
        if [[ "$added_HAF_SHM" == "1" ]]; then
            # We added this line, remove it
            sed -i "/^HAF_SHM_DIRECTORY=/d" .env
            echo "Removed added HAF_SHM_DIRECTORY"
        elif [[ "$modified_HAF_SHM_EXISTS" == "1" ]]; then
            # We modified this line, restore it
            sed -i "s#^$modified_HAF_SHM#$original_HAF_SHM#g" .env
            echo "Restored original HAF_SHM_DIRECTORY"
        fi

        # Restore HAF_ROCKSDB_DIRECTORY
        if [[ "$added_HAF_ROCKSDB" == "1" ]]; then
            # We added this line, remove it
            sed -i "/^HAF_ROCKSDB_DIRECTORY=/d" .env
            echo "Removed added HAF_ROCKSDB_DIRECTORY"
        elif [[ "$HAF_ROCKSDB_EXISTS" == "1" ]]; then
            # Variable existed but we didn't modify it, nothing to do
            echo "HAF_ROCKSDB_DIRECTORY was not modified"
        fi

        # Remove rocksdb argument from ARGUMENTS
        if [[ "$added_rocksdb_arg" == "1" ]]; then
            # Use grep -v and echo to avoid sed quoting issues
            grep -v "^ARGUMENTS=" .env > .env.tmp
            echo "${original_rocksdb_arguments}" >> .env.tmp
            mv .env.tmp .env
            echo "Restored original ARGUMENTS (removed rocksdb path)"
        fi

        # Copy shared_memory data back to disk before unmounting ramdisk.
        # RocksDB (comments-rocksdb-storage) may end up on the ramdisk alongside
        # shared_memory.bin. Both must be copied back so the ZFS snapshot is
        # internally consistent (shared_memory.bin and RocksDB must agree on LIB).
        echo "Copying shared_memory.bin from ramdisk to ZFS..."
        cp --sparse=always /mnt/haf_shared_mem/shared_memory.bin /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/
        chown $HIVED_UID:$HIVED_GID /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/shared_memory.bin
        # Copy RocksDB if it has actual data (SST files) on the ramdisk.
        # Replace the ZFS copy entirely to ensure it matches the shared_memory.bin
        # we just copied (both must be from the same replay run).
        if ls /mnt/haf_shared_mem/comments-rocksdb-storage/*.sst >/dev/null 2>&1; then
            echo "Copying comments-rocksdb-storage from ramdisk to ZFS..."
            rm -rf /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/comments-rocksdb-storage
            cp -a /mnt/haf_shared_mem/comments-rocksdb-storage /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/
            chown -R $HIVED_UID:$HIVED_GID /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/comments-rocksdb-storage
        fi
        umount /mnt/haf_shared_mem

        # Safety: if HAF_SHM_DIRECTORY still points to the ramdisk after restore,
        # comment it out since the ramdisk has been unmounted
        if grep -q '^HAF_SHM_DIRECTORY=.*/mnt/haf_shared_mem' .env; then
            sed -i 's/^HAF_SHM_DIRECTORY=/#HAF_SHM_DIRECTORY=/' .env
            echo "Commented out HAF_SHM_DIRECTORY (ramdisk no longer available)"
        fi

        echo "Ramdisk optimization cleanup completed"
    elif [[ $OPTIMIZATION_METHOD == "reduce_writebacks" ]]; then
        echo "Restoring original kernel parameters..."
        if ./reduce_writebacks.sh --restore; then
            echo "Kernel parameters restored successfully"
        else
            echo "WARNING: Failed to restore kernel parameters. They will reset on next reboot."
        fi
    fi


    # Remove replay arguments
    if [[ $original_arguments != "" ]]; then
        # Use grep -v and echo to avoid sed quoting issues
        grep -v "^ARGUMENTS=" .env > .env.tmp
        echo "${modified_arguments}" >> .env.tmp
        mv .env.tmp .env
    fi

    # Create a snapshot of the ZFS pool
    # (specify --force to prevent snapshot_zfs_datasets from erroring out
    # if the blockchain and shared_memory write times are too far apart,
    # something that can easily happen when copying the shared memory file)
    ./snapshot_zfs_datasets.sh --force $SNAPSHOT_NAME

    # Fix data directory ownership and permissions for hived (block_log may have been copied in as root)
    chown -R $HIVED_UID:$HIVED_GID /$ZPOOL/$TOP_LEVEL_DATASET/blockchain/ 2>/dev/null
    chmod -R u+rw /$ZPOOL/$TOP_LEVEL_DATASET/blockchain/ 2>/dev/null
    chown -R $HIVED_UID:$HIVED_GID /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/ 2>/dev/null
    chmod -R u+rw /$ZPOOL/$TOP_LEVEL_DATASET/shared_memory/ 2>/dev/null

    # Stage 1: Start just HAF and wait for it to enter LIVE sync.
    # By starting HAF before apps, no app indexes get registered, so HAF
    # skips the REINDEX phase and enters LIVE quickly.
    echo "Starting HAF and waiting for it to enter live sync..."
    docker compose up -d haf

    echo "Waiting for HAF to become healthy..."
    while ! docker compose ps haf --format '{{.Health}}' 2>/dev/null | grep -q "healthy"; do
        sleep 5
    done

    echo "HAF is healthy. Waiting for LIVE sync state..."
    while true; do
        sync_state=$(docker compose exec -T haf psql -U haf_admin -d haf_block_log -t -A -c "SELECT hive.get_sync_state();" 2>/dev/null)
        if [ "$sync_state" = "LIVE" ]; then
            break
        fi
        echo "  HAF sync state: $sync_state"
        sleep 10
    done
    echo "HAF has entered LIVE sync."

    # Repair ownership/permissions for all app data directories (hivesense config,
    # ollama, pgdata, etc.) which may be root-owned after ZFS rollback or snapshot restore
    echo "Repairing data directory permissions..."
    ./repair_permissions.sh

    # Stage 2: Bring up the rest of the stack
    docker compose up -d
    rm startup.temp
    echo "Startup Complete"
    echo "Sync Complete"

    # Only mention haf.log for HAF mode
    if [[ $HIVE_MODE == 0 ]]; then
        echo "Forward haf.log to the HAF team for performance tracking."
    fi

    # Report which optimization was used
    if [[ $OPTIMIZATION_METHOD == "ramdisk" ]]; then
        echo "Ramdisk optimization was used for this sync"
    elif [[ $OPTIMIZATION_METHOD == "reduce_writebacks" ]]; then
        echo "reduce_writebacks optimization was used for this sync"
        echo "Kernel parameters have been restored to original values"
    else
        echo "No performance optimizations were used for this sync"
    fi

    if [[ $made_swap == 1 ]]; then
        echo "Swap file(s) created to prevent OOM crash. Please manually remove them if desired. (swapon --help)"
    fi
    exit 0
fi

exit 1
