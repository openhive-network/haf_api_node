# Using docker compose to run the HAF

---

Files used in the process:

- haf_base.yaml *(haf instance)*
- backend.yaml *(backend application: pgadmin, phgero to preview and manage the database)*
- app.yaml *(example of application: postgrest and swagger)*

and environment files:

- .env.dev *(for the developer stage)*
- .env.prod *(for the production stage)*

The environment files specify the versions of images and ports used by applications, as well as the network definition, which varies depending on the version of the environment being run.

This example deployment assumes that haf-datadir local subdirecory can be directly used as HAF instance data directory, by specifying actual path in environment file.
As usually, if you want to perform replay, you have to put a block_log file into `haf-datadir/blockchain` and specify --replay option to the Hived startup options (see ARGUMENTS variable definition in the example env files).

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
running ZFS.  Its compression and snapshots are particularly useful when running a HAF node.

We intend to publish ZFS snapshots of fully-synced HAF nodes that can downloaded to get a HAF node 
up & running quickly, avoiding the multi-day replay times.

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
sudo ./create_zfs_datasets.sh
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

## Launch example

---

1.start/stop naked HAF instance using prod environment

```SH
docker compose up -d
docker compose down
```

2.start/stop HAF instance with pgadmin and pghero in dev enviroment

```SH
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml up -d
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml down
```

3.start/stop HAF instance with pgadmin and pghero and some apps in dev enviroment

```SH
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml -f app.yaml up -d
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml -f app.yaml down
```

##



