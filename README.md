# Using docker compose to run the HAF

# System Requirements

We assume the base system will be running Ubuntu 22.04 (jammy).  Everything will likely work with later versions
of Ubuntu.

For a mainnet API node, we recommend:
- 32GB of memory.  If you have 64GB, it will improve the time it takes to sync from scratch, but 
  it should make less of a difference if you're starting from a mostly-synced HAF node (i.e., 
  restoring a recent ZFS snapshot) (TODO: quantify this?)
- 4TB of NVMe storage (TODO: fact check this, add details about current actual usage)
  - Hive block log & shared memory: 500GB
  - Base HAF database: xxx
  - Hivemind database: xxx
  - base HAF + Hivemind: 2.2TB
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
sudo ./create_zfs_datasets.sh --env-file=./.env
```
to create and mount the datasets.

By default, the dataset holding most of the database storage uses zfs compression. The dataset for
the blockchain data directory (which holds the block_log for hived and the shared_memory.bin file)
is not compressed because hived directly manages compression of the block_log file. 

If you have a LOT of nvme storage (e.g. 6TB+), you can get better API performance at the cost of disk
storage by disabling ZFS compression on the database dataset, but for most nodes this isn't recommended.

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

docker compose logs -f hivemind-block-processor # tail the hivemind sync logs to the console
docker compose down hivemind-block-processor # shut down just the hivemind sync process
docker compose up -d hivemind-block-processor # bring hivemind sync process back up

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

# After startup: Monitoring services and troubleshooting failures on your API node

Haproxy can be used to monitor the state of the various services on your HAF server:
`https://your_server_name/admin/haproxy/`

If you see a service is down, you can use an appropriate `docker compose log` command to
diagnose the issue. When diagnosing issues, keep in mind that several services depend on other services
(for example, all haf apps depend on the hived service) so start by checking the health of the lowest level
services.

You can diagnose API performance problems using pgadmin and pghero. Pgadmin is best for diagnosing severe problems
(e.g. locked tables, etc) whereas pghero is typically best for profiling to determine what queries are loading
down your server and can potentially be optimized.
https://your_server_name/admin/pgadmin
https://your_server_name/admin/pghero/

# Creating a ZFS snapshot to backup your node
Creating snapshots is fast and easy:

```
docker compose down  #shut down haf
./snapshot_zfs_datasets.sh --env-file=./.env 20231023T1831Z-haf-only #where 20231023T1831Z-haf-only is an example snapshot name
docker compose up -d
```
Note: snapshot_zfs_datasets.sh unmounts the HAF datasets, takes a snapshot, and remounts them. Since it unmounts the datasets,
the script will fail if you have anything accessing the datasets. In particular, be sure you don't have any terminals open with
a current working directory set to those datasets. In theory, the script shouldn't have to unmount the datasets before taking
the snapshot, but we have occassionally encountered issues where the snapshots didn't get all needed data.

# Deleting Hivemind data from you database

You may want to remove the Hivemind app's data from your database -- either because you no longer
need it and want to free the space, or because you want want to replay your Hivemind app from 
scratch, which is required for some upgrades.

To delete the data:
- stop Hivemind, but leave the rest of the stack running: `docker compose down hivemind-setup hivemind-block-processing hivemind-server`
- run the uninstall script: `docker compose --profile=hivemind-uninstall-app up`
- you'll see the results of a few sql statements scroll by, and it should exit after a few seconds

The Hivemind data is now gone.

If you're uninstalling Hivemind permanently, then remember to remove the `hivemind` profile from your `.env` file's `COMPOSE_PROFILES` line so it doesn't start automatically next time you do a `docker compose up`.

If you're upgrading to a new version of hivemind:
- if you're upgrading to a pre-release version, you'll need to set `HIVEMIND_INSTANCE_VERSION` in your `.env` file to the correct tag for the version you want to run.  If you're just upgrading to a new release version (the ones tagged `haf_api_node`), you can leave this alone.
- run `docker compose pull` to grab the new version
- run `docker compose up -d` to bring up all services.  This should run Hivemind setup, then launch the block processor.
- you can monitor Hivemind's sync process by watching the logs from `docker compose logs -f hivemind-block-processing`.  In a few short days, your Hivemind app should be fully synced and ready to handle API requests.

