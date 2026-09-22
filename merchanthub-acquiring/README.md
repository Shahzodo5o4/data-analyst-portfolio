# MerchantHub acquiring — not started

Track C. Settlement and acquiring: 80,000 transactions across 1,200 merchants and 2,527
terminals over 2025, with 51,052 settlements and 1,986 disputes.

## The question this one opens on

The data-quality scan already found where to start, so this project does not begin with
exploration.

**871 approved transactions were never settled.**

`settlement_id` is NULL on 9.3% of the book, which at first looks like it simply mirrors
the failed ones. It does not:

| status | unsettled | total | share |
| --- | ---: | ---: | ---: |
| declined | 5,713 | 5,713 | 100% |
| reversed | 822 | 822 | 100% |
| **approved** | **871** | **73,465** | **1.19%** |

Declined and reversed transactions having no settlement is correct behaviour. Approved
ones having none is money that was authorised against the cardholder and never paid out
to the merchant. That is not a footnote — it is the central question.

What has to be established before it can be called a finding: whether the 871 concentrate
on particular merchants, terminals, regions or dates; whether they are a settlement job
that failed on specific days rather than a merchant-level problem; and what the exposure
is in UZS. Until then it is an anomaly, not a leak.

## What is here

Nothing yet beyond the data contract. The CSVs are gitignored — see
[`data/README.md`](data/README.md) for the files this project expects and how to load
them.

## Known constraint

26 calendar days are absent from the 2025 transaction window, the same sparsity as the
other schemas. Daily granularity is not usable; anything time-based has to be cut weekly
or monthly. `disputes` extends to 2026-02-11, six weeks past the last transaction, which
is correct — disputes are raised after the fact.

## Planned shape

```
sql/          numbered files, each runs standalone and prints its results
notebooks/    the same analysis with charts and significance tests
dashboard/    star-schema views, build spec, the report
assets/       charts and report screenshots
```

The three tracks that are complete follow this layout; see
[`../uzcard-payments-analysis/`](../uzcard-payments-analysis/) for the worked example.
