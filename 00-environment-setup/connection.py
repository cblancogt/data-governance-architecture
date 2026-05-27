import pyodbc
from config import SERVER, DATABASE, DRIVER

def get_connection():
    conn_str = (
        f"DRIVER={{{DRIVER}}};"
        f"SERVER={SERVER};"
        f"DATABASE={DATABASE};"
        "Trusted_Connection=yes;"
        "Connection Timeout=10;"
    )
    return pyodbc.connect(conn_str)