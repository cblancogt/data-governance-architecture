# 00 - Environment Setup

SQL Server 2022 Developer Edition configured for the Hight Transactionality governance lab.

## Environment

| Component | Value |
|-----------|-------|
| SQL Server | 2022 (RTM) - 16.0.1000.6 |
| Collation | SQL_Latin1_General_CP1_CI_AS |
| Recovery Model | FULL |
| Python | 3.14.2 |
| pyodbc | 5.3.0 |
| MDS | Not configured — will be implemented if required |

## Filegroups

| Filegroup | Size | Purpose |
|-----------|------|---------|
| PRIMARY | 256 MB | Transactional tables (OLTP) |
| ANALYTICS | 128 MB | Dimensional models (read-heavy) |
| ARCHIVE | 512 MB | Historical telemetry (bulk, retention-managed) |

## Files

| File | Description |
|------|-------------|
| 01_create_database.sql | Database creation with filegroups and FULL recovery |
| 02_verify_environment.sql | Filegroups, recovery model and server config verification |
| 03_verify_mds.sql | MDS check + manual setup steps |
| config.py | Connection parameters |
| connection.py | Reusable connection function |
| connectivity_test.py | Python to SQL Server verification |

## Execution Order

1. Create folders `C:\SQLData\` and `C:\SQLLog\`
2. Run `01_create_database.sql`
3. Run `02_verify_environment.sql`
4. Run `python connectivity_test.py`