# Data quality assessment

Produced by `python setup/profile_data.py` against the loaded `portfolio` database
(1,671,191 rows across four schemas). Everything below was checked before any analysis
started, because a finding is only as trustworthy as the data underneath it.

## Verdict

The extracts are structurally sound. **33 of 35 parent/child relationships are fully
intact — zero orphan rows anywhere in the portfolio.** The two exceptions are nullable
columns, not broken references. Every declared primary key holds, and no duplicate
business keys were found on any of the eight composite keys tested.

Three issues are material enough to change how the analysis is written. They are listed
first.

---

## Material findings

### 1. `oqpay.events.product_id` is empty in 100% of 780,000 rows

Not a load error — verified against the raw CSV, where 0 of 780,000 rows carry a value.
The column exists in the header and is never populated, including on `view_product` and
`add_to_cart` events where a product reference is the whole point.

**Consequence for Track D:** no product-level funnel is possible from the clickstream.
The funnel has to be built on `event_type` alone (`app_open → search → view_product →
add_to_cart → checkout_start → order_placed → payment_success`), and any product-level
question must be answered from `oqpay.order_items` instead, which only covers orders that
were actually placed. This is a real limitation to state in the project README rather
than something to work around silently.

### 2. 871 approved transactions in `merchanthub` were never settled

`settlement_id` is NULL for 9.3% of transactions, which at first looks like it simply
mirrors the failed ones. It does not:

| status | unsettled | total | share |
| --- | ---: | ---: | ---: |
| declined | 5,713 | 5,713 | 100% |
| reversed | 822 | 822 | 100% |
| **approved** | **871** | **73,465** | **1.19%** |

Declined and reversed transactions having no settlement is correct behaviour. Approved
ones having none is money that was authorised against the cardholder but never paid out
to the merchant. This is a candidate for the central question of the Track C project
rather than a footnote.

### 3. Daily granularity is not usable — 26 calendar days are missing per year

`uzcard`, `merchanthub` and `oqpay` each have exactly 26 absent days in their main fact
table. The gaps are spread evenly across weekdays (about 4 of 52 for every day of the
week), so they are not weekends, holidays, or an outage — they are random sparsity in
the generated data.

**Consequence:** daily time series would show spurious dips that mean nothing. All
trend work in every project is done at weekly or monthly granularity.

---

## Referential integrity

35 relationships tested with a LEFT JOIN orphan count. **No orphan rows were found in
any of them.** Two relationships carry NULL child keys, both explained above:

| Relationship | NULL keys | Interpretation |
| --- | ---: | --- |
| `merchanthub.transactions.settlement_id → settlements` | 7,406 | unsettled — see finding 2 |
| `oqpay.events.product_id → products` | 780,000 | column never populated — see finding 1 |

Foreign keys were deliberately left out of `schema.sql` so that this check produced an
answer instead of a failed load. Now that the answer is known, the absence of orphans is
itself a documented result.

## Nulls that are expected by design

These are not defects; they are the natural shape of the data and are handled explicitly
in the SQL rather than filled or dropped.

| Column | Null share | Why |
| --- | ---: | --- |
| `uzcard.transactions.decline_reason` | 93.9% | only declined transactions carry a reason; matches the 6.1% decline rate |
| `walletapp.app_events.amount` | 63.4% | only monetary events (`topup`, `transfer`) have an amount |
| `walletapp.subscriptions.canceled_at` | 79.3% | 79.3% of subscriptions are still active — the mirror of the 20.7% cancel rate |
| `merchanthub.disputes.resolved_date` | 15.3% | matches the 15.3% of disputes still `open` |
| `oqpay.support_tickets.resolved_ts` | 19.6% | unresolved tickets |
| `oqpay.deliveries.delivered_ts` | 2.1% | matches the 2.1% of deliveries with status `failed` |

Each of these cross-checks against a status column and agrees with it exactly, which is a
positive signal about the extract's internal consistency.

## Type handling

`merchanthub.transactions.settlement_id` is written in float notation (`10835.0`) in the
CSV, so it cannot be copied directly into an `INTEGER` column. It is loaded as
`DOUBLE PRECISION` and converted after the COPY in `load_data.py`. Cosmetic, but it
would have silently become a float column — and float keys do not join reliably.

## Time coverage

| Project | Fact table window |
| --- | --- |
| `uzcard` | 2023-01-01 → 2023-12-28 |
| `merchanthub` | 2025-01-01 → 2025-12-28 (disputes run to 2026-02-11) |
| `walletapp` | 2025-01-01 → 2026-06-29 (18 months) |
| `oqpay` | 2025-01-01 → 2025-12-30 |

`merchanthub.disputes` extending six weeks past the last transaction is correct — disputes
are opened after the fact, and that lag is itself measurable.

`walletapp` covering 18 months is the reason it is the right project for cohort retention
work: there is enough runway to follow a January cohort for a full year.

## Known caveat about the source

This is generated course data, not production data. It is internally consistent, but the
customer books onboard throughout each window, which inflates any growth rate computed
off a small January base. Growth is therefore measured as **share of period volume**,
never as raw month-over-month percentage change off the first month.
