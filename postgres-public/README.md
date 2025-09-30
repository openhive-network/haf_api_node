# PostgreSQL Public Access

This directory contains the configuration to enable secure public PostgreSQL access to your HAF database.

## Architecture

```
Internet → Caddy Layer4 → pgbouncer-public:6432 → PostgreSQL:5432
           ├─ :5432 (TLS)
           └─ :5433 (TCP)
```

- **Caddy Layer4**: Provides two connection methods:
  - Port 5432: TLS with ALPN for PostgreSQL 17+ clients
  - Port 5433: Plain TCP for all PostgreSQL clients
- **pgbouncer-public**: Separate PgBouncer instance with MD5 authentication for public users
- **PostgreSQL**: Trusts connections from pgbouncer-public (authentication happens at PgBouncer level)

## Security Features

1. **MD5 authentication**: PgBouncer authenticates clients using MD5 hashed passwords
2. **User isolation**: pgbouncer-public only allows configured public users
3. **Connection limiting**: Hard limit of 5 concurrent connections (configurable), preventing public users
                            from starving core and API functionality
4. **TLS encryption**: Available on port 5432 for PostgreSQL 17+ clients
5. **Read-only access**: The HAFSQL user (the only user currently using this feature) only has SELECT permissions

## Enabling Public Access

### 1. Add the compose file to COMPOSE_FILE

Edit your `.env` file and add the postgres-public compose file.  This is what exposes the database:

```bash
# If you don't have COMPOSE_FILE set:
COMPOSE_FILE=compose.yml:postgres-public/compose.postgres-public.yml

# If you already have COMPOSE_FILE set, append to it:
COMPOSE_FILE=compose.yml:other-files.yml:postgres-public/compose.postgres-public.yml
```

### 2. Configure credentials

Set these variables in your `.env`:

```bash
HAFSQL_PUBLIC_USERNAME=hafsql_public          # Username for public access
HAFSQL_PUBLIC_PASSWORD=your-secure-password   # CHANGE THIS!
HAFSQL_PUBLIC_CONNECTION_LIMIT=5              # Max concurrent connections
```

#### Multiple Users (Advanced)

To configure multiple users, you can add them in postgres-public/compose.postgres-public.yml.  You'll need
to add them both to haf's PG_ACCESS_PGBOUNCER_PUBLIC and to the PGBOUNCER_USERS_WITH_PASSWORDS lines in that file.

Note: When using multiple users, you'll also need to:
1. Create the users in PostgreSQL with appropriate permissions

## Connection Methods

### Port 5432: TLS Connection (PostgreSQL 17+ clients only)

For PostgreSQL 17 or newer clients with direct TLS support:

```bash
psql "postgresql://hafsql_public:your-password@your.hostname.com:5432/haf_block_log?sslmode=require&sslnegotiation=direct"
```

**Note:** Requires PostgreSQL client version 17+ with libpq 17+.

### Port 5433: Plain TCP Connection (All PostgreSQL versions)

For compatibility with all PostgreSQL client versions:

```bash
psql "postgresql://hafsql_public:your-password@your.hostname.com:5433/haf_block_log"
```

**Warning:** This connection is NOT encrypted. Use only with published passwords.

## Files in this Directory

- `compose.postgres-public.yml`: Docker Compose overrides that:
  - Expose ports 5432 (TLS) and 5433 (TCP) on Caddy
  - Mount Layer4 configuration for TCP/TLS routing
  - Add pg_hba.conf entries to trust pgbouncer-public container
  - Configure pgbouncer-public with MD5 authentication for public users
  - Pass HAFSQL credentials to generic PgBouncer configuration

## Implementation Notes

- The public user is created by the HafSQL service when it starts
- pgbouncer-public uses MD5 authentication with dynamically calculated password hashes
- passwords are independent of the postgres passwords (ALTER ROLE ... SET PASSWORD won't 
  change the passwords used to login through pgbouncer)
- Internal API services continue using the regular pgbouncer on port 6432
