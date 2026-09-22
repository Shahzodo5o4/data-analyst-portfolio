# OQPay super-app — funnel and root cause · not started

Track D. A marketplace super-app: 100,000 orders from 15,000 users across 1,500
merchants, with 780,000 clickstream events, 99,542 deliveries, 53,671 reviews and 6,573
support tickets over 2025.

## The constraint, stated before the analysis rather than after

**`events.product_id` is empty in all 780,000 rows.**

Not a load error — verified against the raw CSV, where 0 of 780,000 rows carry a value.
The column exists in the header and is never populated, including on `view_product` and
`add_to_cart` events where a product reference is the entire point.

Two consequences, and neither is worked around silently:

- The clickstream funnel has to be built on `event_type` alone:
  `app_open → search → view_product → add_to_cart → checkout_start → order_placed → payment_success`
- Any product-level question has to be answered from `order_items` instead, which only
  covers orders that were actually placed — so the funnel and the product analysis sit on
  different populations and cannot be joined at the step level.

A project that quietly reported a product funnel from this data would be reporting
something the data cannot support.

## What is here

Nothing yet beyond the data contract. The CSVs are gitignored — see
[`data/README.md`](data/README.md) for the files this project expects and how to load
them.

## Other things the scan flagged

- `support_tickets.resolved_ts` is null on 19.6% of rows — matches the unresolved count
  exactly.
- `deliveries.delivered_ts` is null on 2.1% — matches the 2.1% with status `failed`
  exactly.

Both cross-check against their status column and agree, which is a positive signal about
the extract rather than a defect.

- 26 calendar days are absent from the 2025 window, as in the other schemas. Daily
  granularity is not usable.

## Planned shape

```
sql/          numbered files, each runs standalone and prints its results
notebooks/    the same analysis with charts and significance tests
dashboard/    star-schema views, build spec, the report
assets/       charts and report screenshots
```

The tracks that are complete follow this layout; see
[`../uzcard-payments-analysis/`](../uzcard-payments-analysis/) for the worked example.
