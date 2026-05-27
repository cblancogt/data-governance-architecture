# ============================================================================
# P02 - Week 00: verify_environment.py
# Requires: config.py, connection.py
# ============================================================================

import sys
import pyodbc
from connection import get_connection

print(f"Python : {sys.version}")
print(f"pyodbc : {pyodbc.version}")

try:
    conn = get_connection()
    cur = conn.cursor()

    cur.execute("SELECT @@VERSION")
    print(f"SQL    : {cur.fetchone()[0].split(chr(10))[0]}")

    cur.execute("""
        SELECT name, recovery_model_desc, collation_name
        FROM sys.databases WHERE name = DB_NAME()
    """)
    row = cur.fetchone()
    print(f"DB     : {row.name}")
    print(f"Recovery: {row.recovery_model_desc}")
    print(f"Collation: {row.collation_name}")

    cur.execute("""
        SELECT fg.name, df.size * 8 / 1024 AS size_mb
        FROM sys.filegroups fg
        JOIN sys.database_files df ON fg.data_space_id = df.data_space_id
        ORDER BY fg.name
    """)
    print("Filegroups:")
    for r in cur.fetchall():
        print(f"  {r.name:20s} {r.size_mb} MB")

    cur.close()
    conn.close()
    print("\nConnection: OK")

except pyodbc.Error as e:
    print(f"\nConnection FAILED: {e}")
    sys.exit(1)