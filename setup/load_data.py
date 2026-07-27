"""Create the portfolio database and load every project's raw CSV extract into it.

    python setup/load_data.py            # all four projects
    python setup/load_data.py uzcard     # one schema only

Connection settings come from .env at the repo root (copy .env.example first).
The load is idempotent: the schema drops and recreates everything, so re-running gives
a clean database rather than duplicated rows.
"""

import sys
from pathlib import Path

import psycopg2
from psycopg2 import sql

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = Path(__file__).parent / "schema.sql"

# schema -> project folder -> {table: csv filename}
PROJECTS = {
    "uzcard": (
        "uzcard-payments-analysis",
        {
            "customers": "ds_customers.csv",
            "cards": "ds_cards.csv",
            "mcc_categories": "ds_mcc_categories.csv",
            "merchants": "ds_merchants_2.csv",
            "terminals": "ds_terminals_2.csv",
            "transactions": "ds_transactions_2.csv",
        },
    ),
    "merchanthub": (
        "merchanthub-acquiring",
        {
            "regions": "ds_regions.csv",
            "merchant_categories": "ds_merchant_categories.csv",
            "merchants": "ds_merchants_1.csv",
            "terminals": "ds_terminals_1.csv",
            "settlements": "ds_settlements.csv",
            "transactions": "ds_transactions_1.csv",
            "disputes": "ds_disputes.csv",
        },
    ),
    "walletapp": (
        "walletapp-funnel-retention",
        {
            "channels": "ds_channels.csv",
            "plans": "ds_plans.csv",
            "users": "ds_users_2.csv",
            "subscriptions": "ds_subscriptions.csv",
            "charges": "ds_charges.csv",
            "app_events": "ds_app_events.csv",
        },
    ),
    "oqpay": (
        "oqpay-superapp-rootcause",
        {
            "categories": "ds_categories.csv",
            "merchants": "ds_merchants_3.csv",
            "products": "ds_products.csv",
            "users": "ds_users_1.csv",
            "couriers": "ds_couriers.csv",
            "orders": "ds_orders.csv",
            "order_items": "ds_order_items.csv",
            "payments": "ds_payments.csv",
            "deliveries": "ds_deliveries.csv",
            "reviews": "ds_reviews.csv",
            "events": "ds_events.csv",
            "support_tickets": "ds_support_tickets.csv",
        },
    ),
}

# Columns the extract writes in float notation ("10835.0") that are logically integers.
# They are loaded as DOUBLE PRECISION and converted once the COPY has finished.
POST_LOAD_CASTS = [
    ("merchanthub", "transactions", "settlement_id", "INTEGER"),
]


def read_env() -> dict[str, str]:
    """Parse .env without pulling in python-dotenv for five key/value pairs."""
    env_file = ROOT / ".env"
    if not env_file.exists():
        raise SystemExit(f"No .env found at {env_file}. Copy .env.example to .env and fill it in.")

    env = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip('"').strip("'")

    if not env.get("PGPASSWORD"):
        raise SystemExit("PGPASSWORD is empty in .env — fill it in before loading.")
    return env


def ensure_database(env: dict[str, str]) -> None:
    """CREATE DATABASE if it is not there yet. Runs against the server's `postgres` db."""
    con = psycopg2.connect(
        host=env["PGHOST"], port=env["PGPORT"], dbname="postgres",
        user=env["PGUSER"], password=env["PGPASSWORD"],
    )
    con.autocommit = True  # CREATE DATABASE cannot run inside a transaction block
    with con.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (env["PGDATABASE"],))
        if cur.fetchone():
            print(f"Database '{env['PGDATABASE']}' already exists — reusing it.")
        else:
            cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(env["PGDATABASE"])))
            print(f"Created database '{env['PGDATABASE']}'.")
    con.close()


def load(env: dict[str, str], wanted: list[str]) -> None:
    missing = []
    for schema in wanted:
        folder, files = PROJECTS[schema]
        raw = ROOT / folder / "data" / "raw"
        missing += [str(raw / f) for f in files.values() if not (raw / f).exists()]
    if missing:
        raise SystemExit("Missing raw files:\n  " + "\n  ".join(missing))

    con = psycopg2.connect(
        host=env["PGHOST"], port=env["PGPORT"], dbname=env["PGDATABASE"],
        user=env["PGUSER"], password=env["PGPASSWORD"],
    )
    with con, con.cursor() as cur:
        # schema.sql drops and recreates all four schemas, so it is only safe to run when
        # loading everything. A single-project run reuses the existing structure.
        if len(wanted) == len(PROJECTS):
            cur.execute(SCHEMA.read_text(encoding="utf-8"))
            print("Schema applied — 4 schemas created.\n")
        else:
            print("Partial load: reusing existing schema.\n")

        total = 0
        for schema in wanted:
            folder, files = PROJECTS[schema]
            raw = ROOT / folder / "data" / "raw"
            print(f"[{schema}]")
            for table, filename in files.items():
                if len(wanted) < len(PROJECTS):
                    cur.execute(
                        sql.SQL("TRUNCATE {}.{}").format(
                            sql.Identifier(schema), sql.Identifier(table)
                        )
                    )
                with open(raw / filename, "r", encoding="utf-8") as fh:
                    # COPY ... CSV reads an empty unquoted field as NULL, which is what the
                    # extracts use for optional values such as decline_reason or resolved_ts.
                    cur.copy_expert(
                        sql.SQL("COPY {}.{} FROM STDIN WITH (FORMAT csv, HEADER true)")
                        .format(sql.Identifier(schema), sql.Identifier(table))
                        .as_string(cur),
                        fh,
                    )
                cur.execute(
                    sql.SQL("SELECT count(*) FROM {}.{}").format(
                        sql.Identifier(schema), sql.Identifier(table)
                    )
                )
                rows = cur.fetchone()[0]
                total += rows
                print(f"  {table:<20} {rows:>8,}   <- {filename}")
            print()

        for schema, table, column, target in POST_LOAD_CASTS:
            if schema in wanted:
                cur.execute(
                    sql.SQL("ALTER TABLE {}.{} ALTER COLUMN {} TYPE {} USING {}::{}").format(
                        sql.Identifier(schema), sql.Identifier(table), sql.Identifier(column),
                        sql.SQL(target), sql.Identifier(column), sql.SQL(target),
                    )
                )
                print(f"Cast {schema}.{table}.{column} -> {target}")

        cur.execute("ANALYZE")

    con.close()
    print(f"\n{total:,} rows loaded into '{env['PGDATABASE']}' "
          f"on {env['PGHOST']}:{env['PGPORT']}")


if __name__ == "__main__":
    requested = sys.argv[1:] or list(PROJECTS)
    unknown = [p for p in requested if p not in PROJECTS]
    if unknown:
        raise SystemExit(f"Unknown project(s): {', '.join(unknown)}. "
                         f"Choose from: {', '.join(PROJECTS)}")

    settings = read_env()
    ensure_database(settings)
    load(settings, requested)
