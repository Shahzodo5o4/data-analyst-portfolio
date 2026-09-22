# Raw data

The CSV extracts are **not committed** — they are course-issued data and would add
several megabytes of unreviewable binary-ish content to every clone. `.gitignore` blocks
`**/data/raw/*.csv`.

**One exception, stated so the rule is not quietly broken.**
[`../dashboard/web/index.html`](../dashboard/web/index.html) is a self-contained build of
the report and carries the transaction table inside it — all 60,320 rows, encoded as
index arrays rather than CSV, plus the 600 merchant names. It has to: the page filters
client-side with no server behind it, and at the grain the three pages slice on a
pre-aggregated cube still comes to 36,155 cells, so aggregating buys little. The data is
generated, not production traffic, so nothing here is disclosed that the course did not
already hand out — but a reader who takes the line above literally would be surprised, so
it is written down.

## What belongs here

Drop these six files into `data/raw/`:

| File | Rows | Loads into |
| --- | ---: | --- |
| `ds_customers.csv` | 2,000 | `uzcard.customers` |
| `ds_cards.csv` | 3,286 | `uzcard.cards` |
| `ds_mcc_categories.csv` | 28 | `uzcard.mcc_categories` |
| `ds_merchants_2.csv` | 600 | `uzcard.merchants` |
| `ds_terminals_2.csv` | 2,124 | `uzcard.terminals` |
| `ds_transactions_2.csv` | 60,320 | `uzcard.transactions` |

Source: Uzcard Academy Module 2 course dataset, Track A (card issuing and payment
processing). Generated data, not production traffic.

## Loading them

From the repo root:

```bash
python setup/load_data.py uzcard
```

The loader validates that all six files are present before touching the database, and
`TRUNCATE`s each table first so a re-run replaces rather than appends.

## Column notes

- `ds_transactions_2.decline_reason` is empty on approved rows — `COPY … CSV` reads an
  empty unquoted field as NULL, which is the intended behaviour.
- Booleans arrive as `True` / `False`; PostgreSQL accepts both.
- `txn_ts` covers 2023-01-01 → 2023-12-28, with 26 calendar days absent. That sparsity is
  in the source, not the load — see [`../../setup/DATA-QUALITY.md`](../../setup/DATA-QUALITY.md).
