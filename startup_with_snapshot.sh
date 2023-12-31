#!/bin/bash

zfs list -t snapshot | grep first_sync &> /dev/null
if [[ $? == 0 ]]; then
    echo "Snapshot found. Nothing to do"
    exit 0
fi

source startup.temp

if [[ $docker_up != 1 ]]; then
    echo "Setting Up Startup..."

    # Determine if there is enough RAM to mount shared_mem

    total_memory=$(free -g | awk '/^Mem:/{print $2}')

    if [[ $total_memory -gt 60 ]]; then
        echo "There is more than 64 gigabytes of RAM. Mounting shared_mem..."
        if [ ! -d "/mnt/haf_shared_mem" ]; then
            sudo mkdir /mnt/haf_shared_mem
        fi
        sudo mount -t tmpfs -o size=25g tmpfs /mnt/haf_shared_mem
        sudo chown 1000:100 /mnt/haf_shared_mem
        remove_shared_mem=1
    else
        echo "There is not more than 64 gigabytes of RAM."
        remove_shared_mem=0
    fi

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
    done < .env

    sed -i "s/$original_line/$modified_line/g" .env

    if [[ $remove_shared_mem == 1 ]]; then
        sed -i "s#$original_HAF_SHM#$modified_HAF_SHM#g" .env
        echo "original_HAF_SHM=$original_HAF_SHM" >> startup.temp
        echo "modified_HAF_SHM=$modified_HAF_SHM" >> startup.temp
    fi

    echo "original_line=$original_line" >> startup.temp
    echo "modified_line=$modified_line" >> startup.temp

    docker compose up -d

    echo "docker_up=1" >> startup.temp

fi

source .env

# Monitor the output for the desired phrase
docker compose logs -f | while read -r line; do
    if [[ $line == *"Block"* ]]; then
        echo "$line"
    fi
    if [[ $line == *"PROFILE: Entered LIVE sync"* ]]; then
        echo "Detected *PROFILE: Entered LIVE sync* in the output. Bringing down Docker Compose..."
        docker logs haf-world-haf-1 | grep PRO > haf.log
        docker compose down
        break
    fi
done

# Restore the original line
sed -i "s/$modified_line/$original_line/g" .env

# Move the shared_mem file to the blockchain directory
if [[ $remove_shared_mem == 1 ]]; then
    sed -i "s#$modified_HAF_SHM#$original_HAF_SHM#g" .env
    sudo cp /mnt/haf_shared_mem/shared_memory.bin /haf-pool/haf-datadir/blockchain
    sudo chown 1000:100 /haf-pool/haf-datadir/blockchain/shared_memory.bin
    sudo umount /mnt/haf_shared_mem
fi

# Create a snapshot of the ZFS pool
./snapshot_zfs_datasets.sh first_sync

# Restart Docker Compose
docker compose up -d
rm startup.temp

exit 0
