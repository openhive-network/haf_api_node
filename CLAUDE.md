# CLAUDE.md - haf_api_node

## Project Overview

**haf_api_node** is a docker-compose based deployment stack for running a complete HAF (Hive Application Framework) API node. It orchestrates:
- HAF PostgreSQL database with hived consensus node
- Multiple HAF applications (Hivemind, HAfAH, Balance/Reputation/NFT Trackers, Block Explorer)
- API routing, caching, and load balancing (HAProxy, Caddy, Varnish, Jussi)
- Connection pooling (PgBouncer) and monitoring (Prometheus/Grafana/Loki)

## Tech Stack

- **Containers:** Docker, Docker Compose 2.24.7+
- **Database:** PostgreSQL (HAF), PgBouncer (pooling)
- **Blockchain:** hived consensus node
- **Scripting:** Bash
- **OS:** Ubuntu 22.04+ (23.10 recommended)
- **Storage:** ZFS filesystem (strongly recommended)

**Docker Registries:**
- `registry.hive.blog` - stable releases
- `registry.gitlab.syncad.com/hive` - CI builds

## Directory Structure

```
haf_api_node/
├── compose.yml              # Main orchestrator (includes 23+ YAML files)
├── .env.example             # Environment template (copy to .env)
├── docker-bake.hcl          # Docker Buildx configuration
├── .gitlab-ci.yml           # GitLab CI pipeline
│
├── *.yaml                   # Service definitions:
│   ├── haf_base.yaml        #   HAF core + hived
│   ├── hivemind.yaml        #   Hivemind app
│   ├── hafah.yaml           #   HAfAH app
│   ├── *_tracker.yaml       #   Balance/Reputation/NFT trackers
│   ├── haproxy.yaml         #   Load balancer
│   ├── caddy.yaml           #   Web server
│   ├── pgbouncer.yaml       #   Connection pooler
│   ├── monitoring.yaml      #   Prometheus/Grafana stack
│   └── ...
│
├── caddy/                   # Web server config
├── haproxy/                 # Load balancer config (*.cfg files)
├── pgbouncer/               # Connection pooler config
├── varnish/                 # HTTP cache config
├── jussi/                   # JSON-RPC cache config
├── monitoring/              # Prometheus/Grafana/Loki configs
├── healthchecks/            # HAProxy health check scripts
├── ci/                      # CI scripts and configs
│   ├── scripts/             #   replay-api-node.sh, test-api-node.sh
│   └── node-replay.gitlab-ci.yml
└── scripts/                 # Utility scripts
```

## Development Commands

### Environment Setup
```bash
cp .env.example .env         # Configure environment variables
sudo ./create_zfs_datasets.sh    # ZFS setup (recommended)
sudo ./create_directories.sh     # OR regular filesystem setup
sudo ./repair_permissions.sh     # Fix permissions if needed
```

### Running the Stack
```bash
docker compose up -d             # Start all services in COMPOSE_PROFILES
docker compose logs -f <service> # Tail logs
docker compose down              # Stop all services
```

### Building Images
```bash
docker buildx bake --file=docker-bake.hcl --progress="plain" "pipeline-images"
```

### Linting Docker Compose Files
```bash
# Validate all compose files with dclint
docker run -t --rm -v ${PWD}:/app zavoloklom/dclint *.yaml

# Quick validation (requires Docker daemon)
docker compose config --quiet
```

### ZFS Management
```bash
sudo ./snapshot_zfs_datasets.sh <name>   # Create snapshot
sudo ./rollback_zfs_datasets.sh <name>   # Rollback
sudo ./clone_zfs_datasets.sh <src> <dst> # Clone datasets
```

### Performance Optimization
```bash
sudo ./assisted_startup.sh       # Guided startup with optimizations
sudo ./make_ramdisk.sh           # Create ramdisk for faster sync
sudo ./reduce_writebacks.sh      # Reduce disk writebacks
```

## Key Files

- **`.env.example`** - Master configuration (100+ parameters): ZFS pools, image versions, compose profiles, database credentials, HAF arguments
- **`compose.yml`** - Main compose file with include mechanism
- **`docker-bake.hcl`** - Multi-image build configuration
- **`haproxy/*.cfg`** - Load balancer rules (00-global, 10-defaults, 30-proxies)
- **`caddy/Caddyfile`** - Web server routing with `/admin/*` paths
- **`varnish/default.vcl`** - HTTP cache rules
- **`jussi/config.json`** - JSON-RPC cache configuration

## Coding Conventions

**Bash Scripts:**
- Use `set -e` for error handling
- Variables in `ALL_CAPS` for configuration
- Proper quoting: `"${VAR}"`
- Comment sections: `######### Section Name #########`

**Docker/Compose:**
- Multi-stage builds via docker-bake.hcl
- Health checks on all services
- Dependencies with `depends_on` + condition checks
- Environment substitution: `${VAR:-default}`

**Service Patterns:**
- Install (one-shot) → Block processing → Server/API
- Connection pooling through PgBouncer for all DB access
- Profile-based service grouping: `core`, `admin`, `apps`, `servers`, `monitoring`

## CI/CD Notes

**GitLab CI Pipeline** (`.gitlab-ci.yml`):
- **Build:** Docker images via docker-bake.hcl
- **Replay:** Blockchain replay to block 10000 (manual trigger)
- **Test:** API endpoint validation
- **Publish:** Image tagging for releases/develop
- **Cleanup:** Cache management

**Runner Tags:**
- `public-runner-docker` - Image building
- `data-cache-storage` + `fast` - Replay/testing

**Key CI Variables:**
- `REPLAY_DIRECTORY_PREFIX` - Test data cache location
- `BLOCK_LOG_SOURCE_DIR` - `/blockchain/block_log_5m` (static block_log)

**CI Scripts:**
- `ci/scripts/replay-api-node.sh` - Blockchain replay
- `ci/scripts/test-api-node.sh` - API testing
- `ci/scripts/set-up-stack.sh` - Stack initialization

## System Requirements

- **RAM:** 32GB minimum, 64GB recommended
- **Storage:** 4TB NVMe (500GB blockchain + 3.5TB HAF + 0.65TB Hivemind)
- **Docker Compose:** 2.24.7+
- **ZFS:** Recommended for compression and snapshots

## Admin URLs

```
/admin/haproxy/   # HAProxy stats
/admin/pghero/    # PostgreSQL monitoring
/admin/           # PgAdmin
/version/         # Container version info
```
