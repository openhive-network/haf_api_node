# Using docker compose to install and maintain a HAF server and HAF apps

# System Requirements

We assume the base system will be running at least Ubuntu 22.04 (jammy).  Everything will likely work with later versions of Ubuntu. IMPORTANT UPDATE: experiments have shown 20% better API performance when running U23.10, so this latter version is recommended over Ubuntu 22 as a hosting OS.

For a mainnet API node, we recommend:
- at least 32GB of memory.  If you have 64GB, it will improve the time it takes to sync from scratch, but 
  it should make less of a difference if you're starting from a mostly-synced HAF node (i.e., 
  restoring a recent ZFS snapshot) (TODO: quantify this?)
- 4TB of NVMe storage 
  - Hive block log & shared memory: 500GB
  - Base HAF database: 3.5T (before 2x lz4 compression)
  - Hivemind database: 0.65T (before 2x lz4 compression)
  - base HAF + Hivemind:  2.14T (compressed)
  - HAF Block Explorer: xxx

# Install prerequisites

## Install ZFS support

We strongly recommend running your HAF instance on a ZFS filesystem, and this documentation assumes 
you will be running ZFS.  Its compression and snapshot features are particularly useful when running a HAF node.

We intend to publish ZFS snapshots of fully-synced HAF nodes that can downloaded to get a HAF node 
up & running quickly, avoiding multi-day replay times.

```
sudo apt install zfsutils-linux
```

## Install Docker
Install the latest docker.  If you're running Ubuntu 22.04, the version provided by the
native docker.io package is too old to work with the compose scripts.  Install the latest
version from docker.com, following the instructions here:

  https://docs.docker.com/engine/install/ubuntu/

Which are:
```
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## Create a ZFS pool

Create your ZFS pool if necessary.  HAF requires at least 4TB of space, and 2TB NVMe drives are
readily available, so we typically construct a pool striping data across several 2TB drives.
If you have three or four drives, you will get somewhat better read/write performance, and 
the extra space can come in handy.

To create a pool named "haf-pool" using the first two NVMe drives in your system,
use a command like:
```
sudo zpool create haf-pool /dev/nvme0n1 /dev/nvme1n1
```
If you name your ZFS pool something else, configure the name in the environment file, 
as described in the next section.

Note: By default, ZFS tries to detect your disk's actual sector size, but it often gets it wrong 
for modern NVMe drives, which will degrade performance due to having to write the same sector multiple
times.  If you don't know the actual sector size, we recommend forcing the sector size to 8k by 
specifying setting ashift=13 (e.g., `zfs create -o ashift=13 haf-pool /dev....`)

## Configure your environment

Make a copy of the file `.env.example` and customize it for your system.  This file contains
configurable paramters for things like
- directories
- versions of hived, HAF, and associated tools

The `docker compose` command will automatically read the file named `.env`.  If you want to
keep multiple configurations, you can give your environment files different names like
`.env.dev` and `.env.prod`, then explicitly specify the filename when running `docker compose`:
`docker compose --env-file=.env.dev ...`

## Set up ZFS filesystems

The HAF installation is spread across multiple ZFS datasets, which allows us to set different
ZFS options for different portions of the data. We recommend that most nodes keep the default
datasets in order to enable easy sharing of snapshots.

### Initializing from scratch

If you're starting from scratch, after you've created your zpool and configured its name in the .env file
as described above, run:
```
sudo ./create_zfs_datasets.sh
```
to create and mount the datasets.

By default, the dataset holding most of the database storage uses zfs compression. The dataset for
the blockchain data directory (which holds the block_log for hived and the shared_memory.bin file)
is not compressed because hived directly manages compression of the block_log file. 

If you have a LOT of nvme storage (e.g. 6TB+), you can get better API performance at the cost of disk
storage by disabling ZFS compression on the database dataset, but for most nodes this isn't recommended.

#### Speeding up the initial sync

Following the instructions above will get you a working HAF node, but there are some things you can
do to speed up the initial sync.

##### Replaying
If you already have a recent block_log file (e.g., you're already running another instance of hived
somewhere else on your local network), you can copy the block_log and block_log.artifacts files
from that node into your /haf-pool/haf-datadir/blockchain directory.  After copying the files,
make sure the ownership is set to the same owner as the /haf-pool/haf-datadir/blockchain directory
so hived can read/write them: `chown 1000:100 block_log block_log.artifacts`

Before brining up the haf service, you will also need to add the `--replay-blockchain` argument to
hived to tell it you want to replay.  Edit the `.env` file's `ARGUMENTS` line like so:
```
ARGUMENTS="--replay-blockchain"
```
Once the replay has finished, you can revert the `ARGUMENTS` line to the empty string

##### Shared Memory on Ramdisk
If you have enough spare memory on your system, you can speed up the initial replay by placing the
`shared_memory.bin` file on a ramdisk.

The current default shared memory filesize is 24G, so this will only work if you have 24G free 
(that's in addition to the memory you expect to be used by hived and HAF's integrated PostgreSQL 
instance). 

If you have a 64GB system, ensure you have a big enough swapfile (32GB is recommended
and 8GB is known to not be sufficient) to handle peak memory usage needs during the replay.
Peak memory usage currently occurs when haf table indexes are being built during the final 
stage of replay.

To do this, first create a ramdisk:
```
sudo mkdir /mnt/haf_shared_mem

# then
sudo mount -t tmpfs -o size=25g tmpfs /mnt/haf_shared_mem
# - or -
sudo mount -t ramfs ramfs /mnt/haf_shared_mem

# then
sudo chown 1000:100 /mnt/haf_shared_mem
```

Then, edit your `.env` file to tell it where to put the shared memory file:
```
HAF_SHM_DIRECTORY="/mnt/haf_shared_mem"
```

Now, when you resync / replay, your shared memory file will actually be in memory.  

###### Moving Shared Memory back to disk
Once your replay is finished, we suggest moving the shared_memory.bin file back to NVMe storage, 
because:
- it doesn't make much performance difference once hived is in sync
- you'll be able to have your zfs snapshots include your shared memory file
- you won't be forced to replay if the power goes out

To do this:

- take down the stack (`docker compose down`).
- copy the shared memory: `sudo cp /mnt/haf_shared_mem/shared_memory.bin /haf-pool/haf-datadir/blockchain`
- destroy the ramdisk: `sudo umount /mnt/haf_shared_mem`
- update the `.env` file's location: `HAF_SHM_DIRECTORY="${TOP_LEVEL_DATASET_MOUNTPOINT}/blockchain"`
- bring the stack back up (`docker compose up -d`)

### Initializing from a snapshot

If you're starting with one of our snapshots, the process of restoring the snapshots will create the correct
datasets with the correct options set.

First, download the snapshot file from: TODO: http://xxxxxx

Since these snapshots are huge, it's best to download the snapshot file to a different disk (a magnetic
HDD will be fine for this) that has enough free space for the snapshot first, then restore it to the ZFS pool.
This lets you easily resume the download if your transfer is interrupted.  If you download directly to
the ZFS pool, any interruption would require you to start the download from the beginning.

```
wget -c https://whatever.net/snapshot_filename
```
If the transfer gets interrupted, run the same command again to resume.

Then, to restore the snapshot, run:
```
sudo zfs recv -d -v haf-pool < snapshot_filename
```

## Launch procedure

---

start/stop HAF instance based on profiles enabled in your `.env` file

```SH
docker compose up -d

docker compose logs -f hivemind-block-processing # tail the hivemind sync logs to the console
docker compose down hivemind-block-processing # shut down just the hivemind sync process
docker compose up -d hivemind-block-processing # bring hivemind sync process back up

docker compose down # shut down all containers
```

This will start or stop all services selected by the profiles you have
enabled in the `.env` file's `COMPOSE_PROFILES` variable.

Currently available profiles are:
- `core`: the minimal HAF system of a database and hived
- `admin`: useful tools for administrating HAF: pgadmin, pghero
- `apps`: core HAF apps: hivemind, HAfAH, haf-block-explorer
- `servers`: services for routing/caching API calls: haproxy, jussi,varnish

# Observing node startup

After you start your HAF instance, hived will need some time to catch up to the head block
of the Hive blockchain (typically a few minutes or less if you started from a snapshot,
otherwise it will take many hours or even days depending on your hardware). You can monitor
this process using: `docker compose logs -f haf`

If syncing or replaying for the first time, HAF will delay creating indexes on its tables until the blockchain data has mostly been added to the database. This means there will be a noticeable delay near the end of the catchup period while these indexes get created. Even on a fast machine this post-sync/replay process currently takes over 2 hours to create the indexes, and another two hours to cluster the account_operations table, so be patient. Do not interrupt the process or your database will be left in an invalid state and might require another full replay.

If you enabled the "admin" profile, you can use pghero's "Live Queries" view to monitor this process (e.g https://your_server/admin/pghero/live_queries). If not, you can still observe the cpu and disk io usage by postgresql during this process if you run a tool like htop.

# After startup: Monitoring services and troubleshooting failures on your API node

Haproxy can be used to monitor the state of the various services on your HAF server:
`https://your_server_name/admin/haproxy/`

If you see a service is down, you can use an appropriate `docker compose log` command to
diagnose the issue. When diagnosing issues, keep in mind that several services depend on other services
(for example, all haf apps depend on the hived service) so start by checking the health of the lowest level
services.

You can diagnose API performance problems using pgAdmin and PgHero. pgAdmin is best for diagnosing severe problems (e.g. locked tables, etc) whereas PgHero is typically best for profiling to determine what queries are loading down your server and can potentially be optimized.

https://your_server_name/admin/

# Creating a ZFS snapshot to backup your node
Creating snapshots is fast and easy:

```
docker compose down  #shut down haf
./snapshot_zfs_datasets.sh 20231023T1831Z-haf-only # where 20231023T1831Z-haf-only is an example snapshot name
docker compose up -d
```
Note: snapshot_zfs_datasets.sh unmounts the HAF datasets, takes a snapshot, and remounts them. Since it unmounts the datasets, the script will fail if you have anything accessing the datasets. In particular, be sure you don't have any terminals open with a current working directory set to those datasets. In theory, the script shouldn't have to unmount the datasets before taking the snapshot, but we have occassionally encountered issues where the snapshots didn't get all needed data.

# Deleting Hivemind data from your database (or a similar app's data)

You may want to remove the Hivemind app's data from your database -- either because you no longer
need it and want to free the space, or because you want want to replay your Hivemind app from 
scratch, which is required for some upgrades.

To delete the data:
- stop Hivemind, but leave the rest of the stack running: `docker compose down hivemind-install hivemind-block-processing hivemind-server`
- run the uninstall script: `docker compose --profile=hivemind-uninstall up`
- you'll see the results of a few sql statements scroll by, and it should exit after a few seconds

The Hivemind data is now gone.

If you're uninstalling Hivemind permanently, then remember to remove the `hivemind` profile from your `.env` file's `COMPOSE_PROFILES` line so it doesn't start automatically next time you do a `docker compose up -d`.

If you're upgrading to a new version of hivemind:
- if you're upgrading to a pre-release version, you'll need to set `HIVEMIND_VERSION` in your `.env` file to the correct tag for the version you want to run.  If you're just upgrading to a new release version (the ones tagged `haf_api_node`), you can leave this alone.
- run `docker compose pull` to grab the new version
- run `docker compose up -d` to bring up all services.  This should run hivemind's install, then launch the block processing container.
- you can monitor Hivemind's sync process by watching the logs from `docker compose logs -f hivemind-block-processing`.  In a few short days, your Hivemind app should be fully synced and ready to handle API requests.

# Scripts in the haf_api_node Directory

## use_develop_env.py
This script updates the `.env` file in the `haf_api_node` repository with the short git hashes of other repositories in the specified directory. It scans the given directory for git repositories, retrieves their remote URLs and short git hashes, and updates the `.env` file accordingly.

Usage:
```
python3 use_develop_env.py <path_to_directory>
```

## make_ramdisk.sh
This script creates a ramdisk and mounts it to the `/mnt/haf_shared_mem` directory. It sets the size of the ramdisk to 26GB and changes the permissions to allow read/write access for all users.

Usage:
```
sudo ./make_ramdisk.sh
```

## clone_zfs_datasets.sh
This script clones an existing ZFS dataset to create a new dataset. It is useful for creating backups or duplicating datasets for testing purposes. The script takes the source dataset and the target dataset as arguments and performs the cloning operation.

Usage:
```
sudo ./clone_zfs_datasets.sh <source_dataset> <target_dataset>
```
Example:
```markdown
sudo ./clone_zfs_datasets.sh haf-pool/haf-datadir haf-pool/haf-datadir-test-upgrade
```

## snapshot_zfs_datasets.sh
This script creates a ZFS snapshot of the HAF datasets. It unmounts the datasets, takes a snapshot, and then remounts them. It also provides options for handling log files during the snapshot process.

Usage:
```
sudo ./snapshot_zfs_datasets.sh [--env-file=filename] [--public-snapshot] [--temp-dir=dir] [--swap-logs-with-dataset=dataset] snapshot-name
```
Options:
- `--env-file=filename`: Specify the environment file to use.
- `--public-snapshot`: Move log files to /tmp before taking the snapshot, then restore them afterwards.
- `--temp-dir=dir`: Use a different temp directory (use if /tmp isn't big enough).
- `--swap-logs-with-dataset=dataset`: Swap the logs dataset with an empty dataset before taking the snapshot, then swap back afterwards.

Example:
```
sudo ./snapshot_zfs_datasets.sh 20231023T1831Z-haf-only
```

## rollback_zfs_datasets.sh
This script rolls back ZFS datasets to a specified snapshot. It unmounts the datasets, rolls them back to the named snapshot, and then remounts them. This process will result in the loss of all data on those datasets since the snapshot.

Usage:
```
sudo ./rollback_zfs_datasets.sh [--env-file=filename] [--zpool=zpool_name] [--top-level-dataset=dataset_name] snapshot-name
```
Options:
- `--env-file=filename`: Specify the environment file to use.
- `--zpool=zpool_name`: Specify the ZFS pool name.
- `--top-level-dataset=dataset_name`: Specify the top-level dataset name.

Example:
```
sudo ./rollback_zfs_datasets.sh --env-file=.env --zpool=haf-pool --top-level-dataset=haf-datadir snapshot_name
```