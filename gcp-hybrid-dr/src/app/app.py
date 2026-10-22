#!/usr/bin/env python3
"""Tiny "business" web app for the simulated on-prem primary site.

Serves an orders list backed by SQLite (the thing the DR strategy protects)
and a /health endpoint used by the Cloud DNS failover health check.

Run under gunicorn behind nginx (see src/app/nginx-app.conf):
    gunicorn --bind 127.0.0.1:8000 app:app
Initialise the database once:
    python3 app.py --init-db
"""

import os
import socket
import sqlite3
import sys
from datetime import datetime, timezone

from flask import Flask, jsonify
from markupsafe import escape

DB_PATH = os.environ.get("DR_DB_PATH", "/var/lib/dr-app/app.db")

app = Flask(__name__)

SEED_ORDERS = [
    ("ORD-1001", "Anvil, 50kg", 129.00),
    ("ORD-1002", "Rocket skates", 79.50),
    ("ORD-1003", "Giant rubber band", 12.25),
    ("ORD-1004", "Tunnel paint kit", 44.99),
    ("ORD-1005", "Earthquake pills", 8.75),
]


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = get_db()
    try:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS orders (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   order_ref TEXT NOT NULL UNIQUE,
                   item TEXT NOT NULL,
                   amount REAL NOT NULL,
                   created_at TEXT NOT NULL
               )"""
        )
        now = datetime.now(timezone.utc).isoformat()
        conn.executemany(
            "INSERT OR IGNORE INTO orders (order_ref, item, amount, created_at)"
            " VALUES (?, ?, ?, ?)",
            [(ref, item, amount, now) for ref, item, amount in SEED_ORDERS],
        )
        conn.commit()
    finally:
        conn.close()


@app.route("/")
def index():
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT order_ref, item, amount, created_at FROM orders"
            " ORDER BY id DESC"
        ).fetchall()
    finally:
        conn.close()

    # Escape every value before it goes into the HTML. The endpoint is
    # public (port 80 from 0.0.0.0/0) and the schema is designed for
    # user-supplied orders, so interpolating raw column values would be
    # a stored-XSS hole waiting for the first real order.
    items = "\n".join(
        "<tr><td>{}</td><td>{}</td><td>${:.2f}</td><td>{}</td></tr>".format(
            escape(str(r["order_ref"])),
            escape(str(r["item"])),
            r["amount"],
            escape(str(r["created_at"])),
        )
        for r in rows
    )
    return (
        "<!DOCTYPE html><html><head><title>ACME Orders — Primary Site</title>"
        "<style>body{font-family:sans-serif;margin:2rem}"
        "table{border-collapse:collapse}td,th{border:1px solid #ccc;"
        "padding:.4rem .8rem}</style></head><body>"
        f"<h1>ACME Orders</h1><p>Served by <b>{escape(socket.gethostname())}</b>"
        " (primary site)</p>"
        "<table><tr><th>Ref</th><th>Item</th><th>Amount</th><th>Created</th>"
        f"</tr>{items}</table></body></html>"
    )


@app.route("/health")
def health():
    """Health endpoint polled by the Cloud DNS failover health check.

    Returns 200 only if the database is actually readable — a web server
    fronting a dead database should fail over, not report healthy.
    """
    try:
        conn = get_db()
        try:
            conn.execute("SELECT 1 FROM orders LIMIT 1").fetchone()
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return jsonify(status="unhealthy", error=str(exc)), 503
    return jsonify(
        status="ok",
        site="primary",
        host=socket.gethostname(),
        time=datetime.now(timezone.utc).isoformat(),
    )


if __name__ == "__main__":
    if "--init-db" in sys.argv:
        init_db()
        print(f"initialised {DB_PATH}")
    else:
        app.run(host="127.0.0.1", port=8000)
