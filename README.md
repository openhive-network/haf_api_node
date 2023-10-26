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

We recommend running your HAF instance on a ZFS filesystem, and this documentation assumes you will be
running ZFS.  Its compression and snapshot features are particularly useful when running a HAF node.

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
ZFS options for different portions of the data.

### Initializing from scratch

If you're starting from scratch, after you've created your zpool and configured its name in the .env file
as described above, run:
```
sudo ./create_zfs_datasets.sh --env-file=./.env
```
to create and mount the datasets.

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
- `servers`: services for routing/caching API calls: jussi,varnish
