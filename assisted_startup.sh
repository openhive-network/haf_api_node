#!/bin/bash

# Startup with a snapshot
# After installing zfs and docker prequisites, run this script to configure the rest of the system
# This script will aid in the .env setup, and will automatically create a zpool and zfs datasets if needed


for arg in "$@"; do
    case $arg in
        --no-ramdisk)
            NO_RAMDISK=1
            ;;
        --no-autoswap)
            NO_AUTOSWAP=1
            ;;
        --help)
            echo "Usage: startup_with_snapshot.sh [--no-ramdisk] [--no-autoswap]"
            echo "  --no-ramdisk: Do not use a RAM Disk for shared memory"
            echo "  --no-autoswap: Do not automatically grow swap"
            exit 0
            ;;
        *)
            # Handle other arguments as needed
            ;;
    esac
done

touch startup.temp
## source will load the variable written later in the script if it exists
source startup.temp
source .env

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

if [ ! -f .env ]; then
    echo ".env not found. Performing first time setup..."
    cp .env.example .env
    source .env
    echo "PROFILES are the list of HAF services you want to run. The default is core,admin,apps,servers."
    echo "core: the minimal HAF system of a database and hived"
    echo "admin: useful tools for administrating HAF: pgadmin, pghero"
    echo "apps: core HAF apps: hivemind, hafah, hafbe (balance-tracker is a subapp)"
    echo "servers: services for routing/caching API calls: haproxy, jussi (JSON caching), varnish (REST caching)"
    read -p "Run admin? (Y or N): " choice
    if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
        echo "Adding admin to profiles..."
        echo "$COMPOSE_PROFILES"
        sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES="core,admin"/g" .env
        source .env
    else
        sed -i "s/COMPOSE_PROFILES=\"$COMPOSE_PROFILES\"/COMPOSE_PROFILES="core"/g" .env
        source .env
    fi
    echo "$COMPOSE_PROFILES"
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
    read -p "What is your public hostname? (api.hive.blog) Leave blank if none: " choice
    if [[ "$choice" != "" ]]; then
        echo "Configuring $choice..."
        sed -i "s/PUBLIC_HOSTNAME="$PUBLIC_HOSTNAME"/PUBLIC_HOSTNAME="$choice"/g" .env
        source .env
        echo "Caddy may attempt to get a real SSL certificate for $PUBLIC_HOSTNAME from LetsEncrypt."
        echo "If this server is behind a firewall or NAT, or $PUBLIC_HOSTNAME is misconfigured," 
        echo "it will fail to get a certificate, and that will count against LetsEncrypt's rate limits."
        read -p "Automate SSL for $PUBLIC_HOSTNAME? (Y or N)" choice
        if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
            echo "Automating SSL with Caddy..."
            sed -i "s:TLS_SELF_SIGNED_SNIPPET=caddy/self-signed.snippet:#TLS_SELF_SIGNED_SNIPPET=caddy/self-signed.snippet:g" .env
            sed -i "s:#TLS_SELF_SIGNED_SNIPPET=/dev/null:TLS_SELF_SIGNED_SNIPPET=/dev/null:g" .env
            source .env
        fi
    fi
    echo "If you want to change more options, edit .env manually now and rerun this script."
fi

source .env

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
    echo "Availible NVME drives: $NVME_DRIVES"
    echo "Availible NVME partitions: $NVME_PARTITIONS"
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
    if [[ $TOTAL_SPACE -lt 4000000000000 ]]; then
        echo "Less than 4T of free space found. Please manually create a zpool."
        exit 1
    fi
    echo "Total free space on NVMEs: $(( $TOTAL_SPACE / 1000000000 )) G"
    echo "Found NVME devices: $NVMES"
    echo "sudo $CALLSTRING"
    read -p "Create a zpool with these drives? (Y or N): " choice
    if [[ "$choice" == "Y" || "$choice" == "y" ]]; then
        echo "Creating zpool..."
        sudo $CALLSTRING
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

zfs list -t snapshot | grep first_sync &> /dev/null
if [[ $? == 0 ]]; then
    echo "Snapshot found. Nothing to do"
    rm startup.temp
    exit 0
fi

if [[ $docker_up != 1 ]]; then
    echo "Setting Up Startup..."

    # Optimize the system for replaying the blockchain

    physical_memory=$(free -g | awk '/^Mem:/{print $2}')
    free_memory=$(free -g | awk '/^Mem:/{print $4}')
    swap_memory=$(free -g | awk '/^Swap:/{print $2}')
    free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed "s/G//g")
    swap_type=$(swapon --show=TYPE --noheadings)
    swap_location=$(swapon --show=NAME --noheadings)


    if [[ $physical_memory -gt 60 && $free_memory -gt 30 && $NO_RAMDISK != 1 ]]; then
        echo "There is more than 64 gigabytes of RAM. Mounting shared_mem..."
        if [ ! -d "/mnt/haf_shared_mem" ]; then
            sudo mkdir /mnt/haf_shared_mem
        fi
        sudo mount -t tmpfs -o size=25g tmpfs /mnt/haf_shared_mem
        sudo chown 1000:100 /mnt/haf_shared_mem
        remove_shared_mem=25
    else
        remove_shared_mem=0
    fi
    echo "Available Memory: $(( physical_memory - remove_shared_mem + swap_memory ))G"
    echo "Current swapsize: $swap_memory"
    echo "64G of memory is recommended, with at least 8G of swap"
    echo "This script will attempt to allocate aditional swap if needed"

    # write variable to a temp file
    echo "remove_shared_mem=$remove_shared_mem" > startup.temp

    # Modify the .env file to use only the core and admin profile and the shared_mem directory

    while IFS= read -r line; do
        if [[ $line == COMPOSE_PROFILES=* ]]; then
            original_line="$line"
            modified_line="COMPOSE_PROFILES=\"core,admin\""
            # Print the original and modified lines
            echo "Intended Profiles: $original_line"
            echo "Startup Profiles: $modified_line"
        fi
        if [[ $line == HAF_SHM_DIRECTORY=* ]]; then
            original_HAF_SHM="$line"
            modified_HAF_SHM="HAF_SHM_DIRECTORY=\"/mnt/haf_shared_mem\""

        fi
        if [[ $line == ARGUMENTS=* && ($line == *--replay-blockchain* || $line == *--force-replay*) ]]; then
            original_arguments="$line"
            modified_arguments=$(echo "$line" | sed -E "s/(--replay-blockchain|--force-replay)//g")
            echo "Using: $original_arguments"
            echo "After Sync will use: $modified_arguments"
            echo "If this isn't desired, manually change the arguments in .env before the sync is finished"
        fi
    done < .env

    sed -i "s/$original_line/$modified_line/g" .env

    if [[ $remove_shared_mem == 1 ]]; then
        sed -i "s#$original_HAF_SHM#$modified_HAF_SHM#g" .env
        echo "original_HAF_SHM=$original_HAF_SHM" >> startup.temp
        echo "modified_HAF_SHM=$modified_HAF_SHM" >> startup.temp
    fi

    echo "original_line=$original_line" >> startup.temp
    echo "modified_line=$modified_line" >> startup.temp

    if [[ $original_arguments != "" ]]; then
        echo "original_arguments=$original_arguments" >> startup.temp
        echo "modified_arguments=$modified_arguments" >> startup.temp
    fi

    docker compose up -d

    echo "docker_up=1" >> startup.temp

fi

source .env

max_mem=$(free -g | awk '/^Mem:/{print $3}')
max_swap=$(free -g | awk '/^Swap:/{print $3}')
echo "max_mem=$max_mem" >> startup.temp
echo "max_swap=$max_swap" >> startup.temp
sync_done=0
# Monitor the output for the desired phrase
docker compose logs -f | while read -r line; do
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
                sudo dd if=/dev/zero of=$lowest_priority_file+ count=32K  bs=1M
                sudo chmod 600 $lowest_priority_file+
                sudo mkswap $lowest_priority_file+
                sudo swapon $lowest_priority_file+
                making_swap=0
                made_swap=1
            else
                echo "Swap is nearly full."
            fi

        fi
    fi
    if [[ $line == *"PROFILE: Entered LIVE sync"* ]]; then
        sync_done=1
        echo "Detected *PROFILE: Entered LIVE sync* in the output. Bringing down Docker Compose..."

        # Write Sync time to "haf.log" for tracking, as this log will get wiped on restart
        docker logs haf-world-haf-1 | grep PRO > haf.log
        # Write max memory and swap usage to "haf.log" for tracking
        grep "max_mem=" startup.temp >> haf.log
        grep "max_swap=" startup.temp >> haf.log
        docker compose down
        break
    fi
done


# prevent script completion if interupt sent to above loop

if [[ $sync_done == 1 ]]; then
    # Restore the original line
    sed -i "s/$modified_line/$original_line/g" .env

    # Move the shared_mem file to the blockchain directory
    if [[ $remove_shared_mem != 0 ]]; then
        sed -i "s#$modified_HAF_SHM#$original_HAF_SHM#g" .env
        sudo cp /mnt/haf_shared_mem/shared_memory.bin /$ZPOOL/$TOP_LEVEL_DATASET/blockchain
        sudo chown 1000:100 /$ZPOOL/$TOP_LEVEL_DATASET/blockchain/shared_memory.bin
        sudo umount /mnt/haf_shared_mem
    fi


    # Remove replay arguments
    if [[ $original_arguments != "" ]]; then
        sed -i "s#$original_arguments#$modified_arguments#g" .env
    fi

    # Create a snapshot of the ZFS pool
    ./snapshot_zfs_datasets.sh first_sync

    # Restart Docker Compose
    docker compose up -d
    rm startup.temp
    echo "Startup Complete"
    echo "Sync Complete"
    echo "Forward haf.log to the HAF team for performance tracking."
    if [[ $made_swap == 1 ]]; then
        echo "Swap file(s) created to prevent OOM crash. Please manually remove them if desired. (swapon --help)"
    fi
    exit 0
fi

exit 1
