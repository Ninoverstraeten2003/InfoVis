# Docker Setup (NutriVerse)

## Prerequisites

- Docker + Docker Compose
- A running Traefik instance with the `traefik_proxy` external network
- A `.env` file (copy from `.env.example` and fill in your values)

```bash
cp .env.example .env
```

## First-time setup

```bash
# 1. Start Postgres + PostgREST
docker compose up -d

# 2. Build and run the data seeder (loads all data, then exits)
docker compose --profile seed run --rm seeder
```

PostgREST will be available at `https://<SUBDOMAIN>.<DOMAIN_NAME>`.

## Normal start / restart

```bash
docker compose up -d
```

The seeder is skipped — data is persisted in the `postgres_data` named volume.

## Re-seed the database

```bash
# Wipe all data and re-run from scratch
docker compose down -v
docker compose up -d
docker compose --profile seed run --rm seeder
```

## Useful commands

```bash
# View logs
docker compose logs -f

# Stop everything (keeps data volume)
docker compose down

# Stop and wipe data volume
docker compose down -v

# Rebuild the seeder image after code changes
docker compose --profile seed build seeder
```
