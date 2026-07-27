"""Data-quality and profiling scan across every schema in the portfolio database.

    python setup/profile_data.py

Answers the questions that have to be settled before any analysis is trustworthy:
referential integrity, null density, time coverage, and the distinct values of every
low-cardinality categorical column. Prints a report; changes nothing.
"""

from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parent.parent

# child schema.table.column -> parent schema.table.column
RELATIONSHIPS = [
    ("uzcard.cards.customer_id", "uzcard.customers.customer_id"),
    ("uzcard.transactions.card_id", "uzcard.cards.card_id"),
    ("uzcard.transactions.merchant_id", "uzcard.merchants.merchant_id"),
    ("uzcard.transactions.terminal_id", "uzcard.terminals.terminal_id"),
    ("uzcard.terminals.merchant_id", "uzcard.merchants.merchant_id"),
    ("uzcard.merchants.mcc_code", "uzcard.mcc_categories.mcc_code"),

    ("merchanthub.merchants.category_id", "merchanthub.merchant_categories.category_id"),
    ("merchanthub.merchants.region_id", "merchanthub.regions.region_id"),
    ("merchanthub.terminals.merchant_id", "merchanthub.merchants.merchant_id"),
    ("merchanthub.terminals.region_id", "merchanthub.regions.region_id"),
    ("merchanthub.transactions.terminal_id", "merchanthub.terminals.terminal_id"),
    ("merchanthub.transactions.settlement_id", "merchanthub.settlements.settlement_id"),
    ("merchanthub.settlements.merchant_id", "merchanthub.merchants.merchant_id"),
    ("merchanthub.disputes.txn_id", "merchanthub.transactions.txn_id"),

    ("walletapp.users.channel_id", "walletapp.channels.channel_id"),
    ("walletapp.subscriptions.user_id", "walletapp.users.user_id"),
    ("walletapp.subscriptions.plan_id", "walletapp.plans.plan_id"),
    ("walletapp.charges.subscription_id", "walletapp.subscriptions.subscription_id"),
    ("walletapp.charges.user_id", "walletapp.users.user_id"),
    ("walletapp.app_events.user_id", "walletapp.users.user_id"),

    ("oqpay.products.merchant_id", "oqpay.merchants.merchant_id"),
    ("oqpay.products.category_id", "oqpay.categories.category_id"),
    ("oqpay.orders.user_id", "oqpay.users.user_id"),
    ("oqpay.order_items.order_id", "oqpay.orders.order_id"),
    ("oqpay.order_items.product_id", "oqpay.products.product_id"),
    ("oqpay.payments.order_id", "oqpay.orders.order_id"),
    ("oqpay.payments.user_id", "oqpay.users.user_id"),
    ("oqpay.deliveries.order_id", "oqpay.orders.order_id"),
    ("oqpay.deliveries.courier_id", "oqpay.couriers.courier_id"),
    ("oqpay.reviews.order_id", "oqpay.orders.order_id"),
    ("oqpay.reviews.user_id", "oqpay.users.user_id"),
    ("oqpay.events.user_id", "oqpay.users.user_id"),
    ("oqpay.events.product_id", "oqpay.products.product_id"),
    ("oqpay.support_tickets.user_id", "oqpay.users.user_id"),
    ("oqpay.support_tickets.order_id", "oqpay.orders.order_id"),
]

MAX_DISTINCT = 12  # above this a column is treated as an identifier, not a category


def read_env() -> dict[str, str]:
    env = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def rule(title: str) -> None:
    print(f"\n{'=' * 78}\n{title}\n{'=' * 78}")


def integrity(cur) -> None:
    rule("1. REFERENTIAL INTEGRITY  (orphan rows = child key with no matching parent)")
    clean = 0
    for child, parent in RELATIONSHIPS:
        cs, ct, cc = child.split(".")
        ps, pt, pc = parent.split(".")
        cur.execute(f"""
            SELECT count(*) FILTER (WHERE c.{cc} IS NOT NULL AND p.{pc} IS NULL),
                   count(*) FILTER (WHERE c.{cc} IS NULL),
                   count(*)
            FROM {cs}.{ct} c
            LEFT JOIN {ps}.{pt} p ON c.{cc} = p.{pc}
        """)
        orphans, nulls, total = cur.fetchone()
        if orphans or nulls:
            share = orphans / total * 100 if total else 0
            note = f"{orphans:>7,} orphans ({share:5.2f}%)" if orphans else " " * 22
            note += f"   {nulls:,} NULL keys" if nulls else ""
            print(f"  !! {child:<46} -> {parent:<42} {note}")
        else:
            clean += 1
    print(f"\n  {clean} of {len(RELATIONSHIPS)} relationships are fully intact.")


def nulls(cur) -> None:
    rule("2. NULL DENSITY  (columns with any missing values)")
    cur.execute("""
        SELECT table_schema, table_name, column_name
        FROM information_schema.columns
        WHERE table_schema IN ('uzcard','merchanthub','walletapp','oqpay')
        ORDER BY table_schema, table_name, ordinal_position
    """)
    columns = cur.fetchall()
    current = None
    for schema, table, column in columns:
        cur.execute(f'SELECT count(*) FILTER (WHERE "{column}" IS NULL), count(*) '
                    f'FROM {schema}.{table}')
        missing, total = cur.fetchone()
        if missing:
            if current != (schema, table):
                print(f"\n  {schema}.{table}")
                current = (schema, table)
            print(f"      {column:<24} {missing:>8,} / {total:,}  ({missing / total * 100:5.1f}%)")


def duplicates(cur) -> None:
    rule("3. DUPLICATE BUSINESS KEYS  (beyond the declared primary keys)")
    checks = [
        ("uzcard.cards", "customer_id, card_type, issue_date"),
        ("uzcard.transactions", "card_id, txn_ts, amount_uzs"),
        ("merchanthub.transactions", "terminal_id, txn_ts, amount_uzs"),
        ("merchanthub.disputes", "txn_id"),
        ("walletapp.subscriptions", "user_id, plan_id, started_at"),
        ("oqpay.payments", "order_id, attempt_no"),
        ("oqpay.deliveries", "order_id"),
        ("oqpay.reviews", "order_id"),
    ]
    for table, keys in checks:
        cur.execute(f"""
            SELECT count(*), coalesce(sum(n) - count(*), 0)
            FROM (SELECT count(*) AS n FROM {table} GROUP BY {keys} HAVING count(*) > 1) d
        """)
        groups, extra = cur.fetchone()
        verdict = f"{groups:,} duplicated groups, {extra:,} surplus rows" if groups else "unique"
        print(f"  {table:<28} by ({keys:<34}) -> {verdict}")


def time_coverage(cur) -> None:
    rule("4. TIME COVERAGE")
    columns = [
        ("uzcard.transactions", "txn_ts"),
        ("uzcard.customers", "onboarding_date"),
        ("uzcard.cards", "issue_date"),
        ("merchanthub.transactions", "txn_ts"),
        ("merchanthub.settlements", "batch_date"),
        ("merchanthub.disputes", "opened_date"),
        ("walletapp.users", "signup_ts"),
        ("walletapp.app_events", "event_ts"),
        ("walletapp.charges", "charged_at"),
        ("oqpay.orders", "ordered_ts"),
        ("oqpay.events", "event_ts"),
        ("oqpay.deliveries", "promised_ts"),
    ]
    for table, column in columns:
        cur.execute(f"SELECT min({column})::date, max({column})::date, "
                    f"count(DISTINCT {column}::date) FROM {table}")
        lo, hi, days = cur.fetchone()
        span = (hi - lo).days + 1 if lo and hi else 0
        gap = "" if days == span else f"   << only {days} of {span} days present"
        print(f"  {table + '.' + column:<38} {lo} -> {hi}  ({span} days){gap}")


def categoricals(cur) -> None:
    rule(f"5. CATEGORICAL COLUMNS  (<= {MAX_DISTINCT} distinct values)")
    cur.execute("""
        SELECT table_schema, table_name, column_name
        FROM information_schema.columns
        WHERE table_schema IN ('uzcard','merchanthub','walletapp','oqpay')
          AND data_type IN ('text','boolean','integer')
          AND column_name NOT LIKE '%\\_id'
        ORDER BY table_schema, table_name, ordinal_position
    """)
    current = None
    for schema, table, column in cur.fetchall():
        cur.execute(f'SELECT count(DISTINCT "{column}") FROM {schema}.{table}')
        n = cur.fetchone()[0]
        if not 0 < n <= MAX_DISTINCT:
            continue
        cur.execute(f"""
            SELECT "{column}"::text, count(*) FROM {schema}.{table}
            GROUP BY 1 ORDER BY 2 DESC
        """)
        rows = cur.fetchall()
        total = sum(c for _, c in rows)
        if current != (schema, table):
            print(f"\n  {schema}.{table}")
            current = (schema, table)
        shown = " · ".join(f"{v} {c / total * 100:.1f}%" for v, c in rows[:8])
        print(f"      {column:<20} [{n}] {shown}")


def main() -> None:
    env = read_env()
    con = psycopg2.connect(
        host=env["PGHOST"], port=env["PGPORT"], dbname=env["PGDATABASE"],
        user=env["PGUSER"], password=env["PGPASSWORD"],
    )
    with con, con.cursor() as cur:
        integrity(cur)
        nulls(cur)
        duplicates(cur)
        time_coverage(cur)
        categoricals(cur)
    con.close()


if __name__ == "__main__":
    main()
