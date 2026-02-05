# Database Setup and Management Guide

Complete guide for PostgreSQL and Redis database management in the Mosuon cluster.

## Table of Contents

1. [PostgreSQL Setup](#postgresql-setup)
2. [Redis Setup](#redis-setup)
3. [Database Operations](#database-operations)
4. [Backup and Restore](#backup-and-restore)
5. [Performance Tuning](#performance-tuning)
6. [Monitoring](#monitoring)
7. [Troubleshooting](#troubleshooting)

## PostgreSQL Setup

### Installation

PostgreSQL is installed via Bitnami Helm chart during provisioning:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install postgresql bitnami/postgresql \
  --namespace infra \
  --set auth.postgresPassword=$POSTGRES_PASSWORD \
  --set primary.persistence.size=20Gi \
  --set primary.resources.requests.memory=512Mi \
  --set primary.resources.requests.cpu=250m \
  --set primary.resources.limits.memory=1Gi \
  --set primary.resources.limits.cpu=1000m
```

### Configuration

**Version**: PostgreSQL 15
**Storage**: 20Gi persistent volume
**Namespace**: `infra`
**Service**: `postgresql.infra.svc.cluster.local:5432`

**Resource Limits**:
```yaml
resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 1000m
```

### Access PostgreSQL

#### From Within Cluster

```bash
# Get PostgreSQL pod
kubectl get pods -n infra -l app=postgresql

# Execute psql in pod
kubectl exec -it -n infra postgresql-0 -- psql -U postgres

# Connect to specific database
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats
```

#### From Local Machine (Port Forward)

```bash
# Forward port
kubectl port-forward -n infra svc/postgresql 5432:5432

# In another terminal
psql "postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres"

# Or use connection string
export DATABASE_URL="postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/game_stats"
psql $DATABASE_URL
```

#### Using GUI Tools

Configure connection in pgAdmin, DBeaver, or TablePlus:

```
Host: localhost (after port-forward)
Port: 5432
User: postgres
Password: [your POSTGRES_PASSWORD]
Database: game_stats
SSL Mode: prefer
```

### Database Creation

#### Application Database

Created automatically during provisioning:

```sql
-- Create database
CREATE DATABASE game_stats;

-- Create user
CREATE USER game_stats_user WITH PASSWORD 'secure-password';

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE game_stats TO game_stats_user;

-- Connect to database
\c game_stats

-- Grant schema privileges
GRANT ALL ON SCHEMA public TO game_stats_user;

-- Grant default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
  GRANT ALL ON TABLES TO game_stats_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public 
  GRANT ALL ON SEQUENCES TO game_stats_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public 
  GRANT ALL ON FUNCTIONS TO game_stats_user;
```

#### Manual Database Creation

```bash
kubectl exec -n infra postgresql-0 -- psql -U postgres <<'EOF'
CREATE DATABASE new_service_db;
CREATE USER new_service_user WITH PASSWORD 'secure-password';
GRANT ALL PRIVILEGES ON DATABASE new_service_db TO new_service_user;
\c new_service_db
GRANT ALL ON SCHEMA public TO new_service_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO new_service_user;
EOF
```

### Database Migrations

#### Using Go Migrate

```bash
# Install migrate CLI
go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

# Run migrations
migrate -path ./migrations \
  -database "$DATABASE_URL" \
  up

# Rollback migration
migrate -path ./migrations \
  -database "$DATABASE_URL" \
  down 1

# Check version
migrate -path ./migrations \
  -database "$DATABASE_URL" \
  version
```

#### Using Kubernetes Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  namespace: mosuon
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: migrate/migrate:v4.16.0
        args:
          - "-path=/migrations"
          - "-database=$(DATABASE_URL)"
          - "up"
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: game-stats-api-secrets
              key: DATABASE_URL
        volumeMounts:
        - name: migrations
          mountPath: /migrations
      volumes:
      - name: migrations
        configMap:
          name: db-migrations
      restartPolicy: OnFailure
```

### User Management

#### Create Read-Only User

```sql
-- Create user
CREATE ROLE readonly_user WITH LOGIN PASSWORD 'readonly_password';

-- Grant connect
GRANT CONNECT ON DATABASE game_stats TO readonly_user;

-- Grant usage on schema
\c game_stats
GRANT USAGE ON SCHEMA public TO readonly_user;

-- Grant SELECT on all existing tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;

-- Grant SELECT on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
  GRANT SELECT ON TABLES TO readonly_user;
```

#### Create Application User

```sql
-- Create user with limited privileges
CREATE ROLE app_user WITH LOGIN PASSWORD 'app_password';
GRANT CONNECT ON DATABASE game_stats TO app_user;

\c game_stats
GRANT USAGE ON SCHEMA public TO app_user;

-- Grant specific table permissions
GRANT SELECT, INSERT, UPDATE ON games TO app_user;
GRANT SELECT, INSERT ON game_stats TO app_user;

-- Grant sequence usage
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user;
```

## Redis Setup

### Installation

Redis is installed via Bitnami Helm chart:

```bash
helm install redis bitnami/redis \
  --namespace infra \
  --set auth.password=$POSTGRES_PASSWORD \
  --set master.persistence.size=8Gi \
  --set master.resources.requests.memory=256Mi \
  --set master.resources.requests.cpu=100m \
  --set replica.replicaCount=0
```

### Configuration

**Version**: Redis 7
**Storage**: 8Gi persistent volume
**Namespace**: `infra`
**Service**: `redis-master.infra.svc.cluster.local:6379`

**Resource Limits**:
```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Access Redis

#### From Within Cluster

```bash
# Connect to Redis pod
kubectl exec -it -n infra redis-master-0 -- redis-cli

# Authenticate
AUTH your-redis-password

# Test
PING
# PONG

# Get info
INFO
```

#### From Local Machine

```bash
# Port forward
kubectl port-forward -n infra svc/redis-master 6379:6379

# Connect with redis-cli
redis-cli -h localhost -p 6379 -a your-redis-password

# Or use connection string
redis://your-redis-password@localhost:6379/0
```

### Redis Commands

```bash
# Connect
kubectl exec -it -n infra redis-master-0 -- redis-cli
AUTH password

# Check connections
CLIENT LIST

# Monitor commands in real-time
MONITOR

# Get memory usage
INFO memory

# Get key count
DBSIZE

# Flush specific database
SELECT 0
FLUSHDB

# Flush all databases (DANGEROUS!)
FLUSHALL
```

## Database Operations

### Connection Strings

#### PostgreSQL

```bash
# Full connection string
postgresql://user:password@host:port/database?sslmode=disable

# Application connection (from within cluster)
postgresql://game_stats_user:password@postgresql.infra:5432/game_stats

# Admin connection
postgresql://postgres:password@postgresql.infra:5432/postgres

# With SSL
postgresql://user:password@host:port/database?sslmode=require
```

#### Redis

```bash
# Simple
redis://password@redis-master.infra:6379/0

# With database selection
redis://:password@redis-master.infra:6379/1
```

### Query Database

#### List Databases

```bash
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -c "\l"
```

#### List Tables

```bash
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats -c "\dt"
```

#### Run Query

```bash
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats -c \
  "SELECT * FROM games LIMIT 10;"
```

#### Execute SQL File

```bash
# Copy SQL file to pod
kubectl cp migrations/001_init.sql infra/postgresql-0:/tmp/

# Execute
kubectl exec -it -n infra postgresql-0 -- psql -U postgres -d game_stats -f /tmp/001_init.sql
```

### Database Size

```sql
-- Database size
SELECT 
  pg_database.datname,
  pg_size_pretty(pg_database_size(pg_database.datname)) AS size
FROM pg_database
ORDER BY pg_database_size(pg_database.datname) DESC;

-- Table sizes
SELECT 
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- Index sizes
SELECT
  schemaname,
  tablename,
  indexname,
  pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexname::regclass) DESC;
```

## Backup and Restore

### PostgreSQL Backups

#### Manual Backup

```bash
# Backup all databases
kubectl exec -n infra postgresql-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Backup specific database
kubectl exec -n infra postgresql-0 -- pg_dump -U postgres game_stats | gzip > game_stats-$(date +%Y%m%d).sql.gz

# Backup with custom format (faster restore)
kubectl exec -n infra postgresql-0 -- pg_dump -U postgres -Fc game_stats > game_stats-$(date +%Y%m%d).dump
```

#### Automated Backup CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: infra
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:15
            command:
            - /bin/sh
            - -c
            - |
              pg_dump -h postgresql -U postgres game_stats | gzip > /backup/game_stats-$(date +%Y%m%d-%H%M%S).sql.gz
              # Keep only last 7 days
              find /backup -type f -mtime +7 -delete
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgresql
                  key: postgres-password
            volumeMounts:
            - name: backup
              mountPath: /backup
          volumes:
          - name: backup
            persistentVolumeClaim:
              claimName: postgres-backups
          restartPolicy: OnFailure
```

#### Restore from Backup

```bash
# Restore all databases
gunzip -c backup-20260204.sql.gz | kubectl exec -i -n infra postgresql-0 -- psql -U postgres

# Restore specific database
kubectl exec -n infra postgresql-0 -- psql -U postgres -c "DROP DATABASE game_stats;"
kubectl exec -n infra postgresql-0 -- psql -U postgres -c "CREATE DATABASE game_stats;"
gunzip -c game_stats-20260204.sql.gz | kubectl exec -i -n infra postgresql-0 -- psql -U postgres -d game_stats

# Restore from custom format
kubectl exec -i -n infra postgresql-0 -- pg_restore -U postgres -d game_stats < game_stats-20260204.dump
```

### Redis Backups

#### Manual Backup

```bash
# Trigger RDB snapshot
kubectl exec -n infra redis-master-0 -- redis-cli -a password SAVE

# Copy RDB file
kubectl cp infra/redis-master-0:/data/dump.rdb ./redis-backup-$(date +%Y%m%d).rdb
```

#### Automated Backup

Redis automatically creates RDB snapshots based on:

```conf
save 900 1      # After 900 sec (15 min) if at least 1 key changed
save 300 10     # After 300 sec (5 min) if at least 10 keys changed
save 60 10000   # After 60 sec if at least 10000 keys changed
```

#### Restore Redis

```bash
# Stop Redis
kubectl scale statefulset redis-master -n infra --replicas=0

# Copy backup
kubectl cp redis-backup-20260204.rdb infra/redis-master-0:/data/dump.rdb

# Start Redis
kubectl scale statefulset redis-master -n infra --replicas=1
```

## Performance Tuning

### PostgreSQL Optimization

#### Indexes

```sql
-- Create index
CREATE INDEX idx_games_created_at ON games(created_at);

-- Analyze query performance
EXPLAIN ANALYZE SELECT * FROM games WHERE created_at > '2026-01-01';

-- List slow queries
SELECT 
  query,
  calls,
  total_time,
  mean_time,
  max_time
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;
```

#### Connection Pooling

Use PgBouncer for connection pooling:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: infra
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: pgbouncer
        image: bitnami/pgbouncer:1.21.0
        env:
        - name: POSTGRESQL_HOST
          value: postgresql
        - name: POSTGRESQL_PORT
          value: "5432"
        - name: PGBOUNCER_DATABASE
          value: game_stats
        - name: PGBOUNCER_POOL_MODE
          value: transaction
        - name: PGBOUNCER_MAX_CLIENT_CONN
          value: "100"
```

Update application connection string:
```
postgresql://game_stats_user:password@pgbouncer.infra:6432/game_stats
```

### Redis Optimization

#### Maxmemory Policy

```bash
kubectl exec -n infra redis-master-0 -- redis-cli -a password CONFIG SET maxmemory 256mb
kubectl exec -n infra redis-master-0 -- redis-cli -a password CONFIG SET maxmemory-policy allkeys-lru
```

#### Key Expiration

```bash
# Set TTL on keys
SET key value EX 3600  # Expire in 1 hour

# Check TTL
TTL key

# Remove expiration
PERSIST key
```

## Monitoring

### PostgreSQL Monitoring

#### Check Active Connections

```sql
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';

SELECT 
  pid,
  usename,
  application_name,
  client_addr,
  state,
  query
FROM pg_stat_activity
WHERE state != 'idle';
```

#### Long-Running Queries

```sql
SELECT
  pid,
  now() - pg_stat_activity.query_start AS duration,
  query
FROM pg_stat_activity
WHERE state = 'active'
AND now() - pg_stat_activity.query_start > interval '5 minutes';

-- Kill long-running query
SELECT pg_terminate_backend(pid);
```

#### Table Statistics

```sql
SELECT 
  schemaname,
  tablename,
  seq_scan,
  seq_tup_read,
  idx_scan,
  idx_tup_fetch,
  n_tup_ins,
  n_tup_upd,
  n_tup_del
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
```

### Redis Monitoring

```bash
# Server info
INFO server

# Memory stats
INFO memory

# Keyspace stats
INFO keyspace

# Slow log
SLOWLOG GET 10

# Monitor commands in real-time
MONITOR
```

## Troubleshooting

### PostgreSQL Issues

#### Can't Connect

```bash
# Check pod is running
kubectl get pods -n infra -l app=postgresql

# Check logs
kubectl logs -n infra postgresql-0

# Check service
kubectl get svc -n infra postgresql

# Test connection from another pod
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql "postgresql://postgres:password@postgresql.infra:5432/postgres"
```

#### Out of Connections

```sql
-- Check max connections
SHOW max_connections;

-- Check current connections
SELECT count(*) FROM pg_stat_activity;

-- Increase max_connections (requires restart)
ALTER SYSTEM SET max_connections = 200;
```

#### Disk Full

```bash
# Check disk usage
kubectl exec -n infra postgresql-0 -- df -h

# Clean old WAL files
kubectl exec -n infra postgresql-0 -- psql -U postgres -c "CHECKPOINT;"

# Vacuum databases
kubectl exec -n infra postgresql-0 -- psql -U postgres -d game_stats -c "VACUUM FULL;"
```

### Redis Issues

#### High Memory Usage

```bash
# Check memory
kubectl exec -n infra redis-master-0 -- redis-cli -a password INFO memory

# Find large keys
kubectl exec -n infra redis-master-0 -- redis-cli -a password --bigkeys

# Set eviction policy
kubectl exec -n infra redis-master-0 -- redis-cli -a password CONFIG SET maxmemory-policy allkeys-lru
```

#### Connection Refused

```bash
# Check pod
kubectl get pods -n infra -l app=redis

# Check logs
kubectl logs -n infra redis-master-0

# Verify password
kubectl get secret redis -n infra -o jsonpath="{.data.redis-password}" | base64 -d
```

## Related Documentation

- [Provisioning Guide](provisioning.md)
- [Operations Runbook](OPERATIONS-RUNBOOK.md)
- [Monitoring Guide](monitoring.md)
