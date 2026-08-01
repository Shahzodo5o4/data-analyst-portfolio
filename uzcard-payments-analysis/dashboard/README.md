# Dashboard — build specification

Power BI Desktop, two pages, connected live to the star-schema views in
[`views.sql`](views.sql). This file is the spec the `.pbix` is built from, so the
report can be rebuilt from scratch without guessing at layout or measure definitions.

The two pages answer different questions for different people. Page 1 is for whoever
owns the P&L and wants to know whether anything is wrong. Page 2 is for the anti-fraud
analyst who has to act on it before lunch.

---

## Before opening Power BI

```bash
psql -d portfolio -f dashboard/views.sql
```

The script ends with two smoke tests. They must print `60,320 · 6.10% · 0.355%` and the
four `card_profile` rows at `20.23 / 5.86 / 5.83 / 5.69`. If they do not, the model is
quoting something the analysis never said — fix that before building visuals.

## Connecting

**Get data → PostgreSQL database** · server `localhost:5433` · database `portfolio`.
Choose **Import**, not DirectQuery: the fact is 60,320 rows, which imports in seconds and
makes every interaction instant.

The server runs PostgreSQL 18.4 with `scram-sha-256` authentication. Power BI's built-in
connector handles that through its bundled Npgsql driver, but only on reasonably current
builds — a release older than about 2021 fails with
`The authentication method 10 is not supported`. Two fallbacks if that happens:

- install a current Power BI Desktop (the Microsoft Store build keeps itself updated), or
- connect through **ODBC** instead, using the `psqlODBC` driver already installed on this
  machine, with the DSN-less string
  `Driver={PostgreSQL Unicode};Server=localhost;Port=5433;Database=portfolio;`

Select these six views only:

```
uzcard.fact_transactions      60,320 rows   the fact
uzcard.dim_date                  362 rows   calendar
uzcard.dim_customer            2,000 rows
uzcard.dim_card                3,286 rows
uzcard.dim_merchant              600 rows
uzcard.dim_terminal            2,124 rows
```

## Model relationships

All single-direction, many-to-one, from fact to dimension:

| From | To | Cardinality |
| --- | --- | --- |
| `fact_transactions[date_key]` | `dim_date[date_key]` | many-to-one |
| `fact_transactions[card_id]` | `dim_card[card_id]` | many-to-one |
| `fact_transactions[customer_id]` | `dim_customer[customer_id]` | many-to-one |
| `fact_transactions[merchant_id]` | `dim_merchant[merchant_id]` | many-to-one |
| `fact_transactions[terminal_id]` | `dim_terminal[terminal_id]` | many-to-one |

Mark `dim_date` as the date table (`date_key`). Hide every key column from report view —
nothing should be draggable onto a visual except attributes and measures.

Do **not** create a relationship from `dim_card[customer_id]` to `dim_customer`. The fact
already reaches both, and a second path makes the model ambiguous.

---

## Measures

The status flags are pre-split into integers in the fact, so every measure is a plain
`SUM` or a ratio of two. No `CALCULATE` filter juggling, and the approved-only dispute
denominator cannot be bypassed by accident.

```dax
Transactions      = COUNTROWS('fact_transactions')
Approved          = SUM('fact_transactions'[is_approved])
Declined          = SUM('fact_transactions'[is_declined])
Disputes          = SUM('fact_transactions'[is_disputed])
Approved value    = SUM('fact_transactions'[approved_amount_uzs])

Decline rate      = DIVIDE([Declined], [Transactions])
Dispute rate      = DIVIDE([Disputes], [Approved])
Funding share of declines =
    DIVIDE(SUM('fact_transactions'[is_funding_decline]), [Declined])

-- book-wide baselines, immune to the visual's own filters, so a bar can be
-- compared against the whole book rather than against its own slice
Decline rate (book)  = CALCULATE([Decline rate], ALL('fact_transactions'), ALL('dim_card'),
                                 ALL('dim_customer'), ALL('dim_merchant'), ALL('dim_terminal'))
Decline gap vs book  = [Decline rate] - [Decline rate (book)]

-- share of the visible period, for the channel trend
Share of month =
    DIVIDE([Transactions],
           CALCULATE([Transactions], ALLEXCEPT('dim_date', 'dim_date'[month_start])))

-- dispute concentration, for the watchlist
Dispute share = DIVIDE([Disputes], CALCULATE([Disputes], ALL('dim_merchant')))
```

Format `Decline rate`, `Dispute rate`, `Share of month`, `Dispute share` as percentage —
2 decimals for decline, **3 for dispute** (the interesting differences live in the third
place). `Approved value` as whole UZS with thousands separators.

---

## Colours

Same palette as the notebook charts, so a screenshot from either sits beside the other
without clashing.

| Role | Hex | Used for |
| --- | --- | --- |
| Accent | `#2a78d6` | primary bars, lines, the ECOM series |
| Critical | `#d03b3b` | the outlier only — never a normal series |
| Neutral | `#c9c8c2` | every bar that is not the point of the visual |
| Ink | `#0b0b0b` | titles, KPI values |
| Secondary ink | `#52514e` | subtitles, labels |
| Muted | `#898781` | axis text |
| Gridline | `#e1e0d9` | horizontal gridlines only |
| Canvas | `#fcfcfb` | page background |

One rule carries most of the visual clarity: **grey by default, red only for the thing
the visual exists to show.** A chart where four bars are four different colours has
spent its colour budget on decoration.

Turn off: visual borders, shadows, the vertical gridlines, and data labels on every
point (label the endpoints only).

### Applying it

All of the above is already encoded in [`theme.json`](theme.json). Load it once, before
placing any visual: **View → Themes → Browse for themes →** `dashboard/theme.json`.

It sets the eight palette colours, the type ramp (Segoe UI, 32pt KPI values / 13pt titles
/ 10pt labels), the `#fcfcfb` canvas, horizontal-only gridlines in `#e1e0d9`, and it turns
off borders, shadows, visual headers, legends and data labels globally. Applying it means
the only formatting left to do by hand is the *per-visual* work the theme cannot know
about: the conditional `#d03b3b` rules, the constant line, and the endpoint labels on the
channel chart. The globally-off legend is deliberate and wants no exception — the channel
lines are direct-labelled instead.

Setting `"good"`/`"bad"` in the theme also drives the table's data bars and any
conditional-formatting default, so those pick up the right red without extra clicking.

---

## Page 1 — Overview

*Audience: product and P&L owners. Question: is anything wrong, and how big is it?*

**Canvas** 1280 × 720. A 12-column grid with 16px gutters, 24px page margin.

### Row 1 — KPI cards (four, full width, 130px tall)

| Card | Measure | Subtitle |
| --- | --- | --- |
| Transactions | `[Transactions]` | 2023 full year |
| Decline rate | `[Decline rate]` | 1 in 16 payments fails |
| Dispute rate | `[Dispute rate]` | of approved transactions |
| Approved value | `[Approved value]` | UZS settled |

Value in Ink at 32pt semibold, label in Secondary ink at 11pt uppercase with letter
spacing. No sparklines, no conditional arrows — there is no prior year to compare to and
a fake trend indicator would be a lie.

### Row 2 left — Decline rate by card profile *(the headline)*

Bar chart. Axis `dim_card[card_profile]`, value `[Decline rate]`.
Conditional formatting on the bars: `#d03b3b` when `card_profile = "student · virtual"`,
otherwise `#c9c8c2`. Add a constant line at the book average in Secondary ink, dashed,
labelled — set its value with `fx` bound to `[Decline rate (book)]` (6.10%) rather than
typing a number, so it cannot drift from the model. Note this is the *book* rate, not the
5.83% non-student rate quoted in the README; the two answer different questions and
mixing them up mislabels the line.

Title: **"One card product carries the whole decline gap"**
Subtitle: "Students on any other card decline at the book average."

This visual is the reason the page exists. Give it the most space in the row.

### Row 2 right — Decline rate by segment

Bar chart, axis `dim_customer[segment]`, value `[Decline rate]`, all bars neutral.

Title: **"The segment view, for comparison"**
Subtitle: "This is the same data — and it points at the wrong thing."

Placing the misleading view *next to* the correct one is the argument. Do not delete it
because it is wrong; it is wrong in an instructive way, and it is the view most people
would have built.

### Row 3 — Channel share over time

Line chart. Axis `dim_date[month_start]`, legend `dim_terminal[channel]`,
value `[Share of month]`. ECOM in `#2a78d6`, every other channel in Neutral at 60%
opacity. Direct-label the line ends; no legend box.

Title: **"E-commerce is the only channel gaining share"**
Subtitle: "Share of monthly transactions — monthly because 26 calendar days are missing."

### Slicers (top-right, one row)

`dim_date[quarter_name]` · `dim_terminal[channel]` · `dim_customer[segment]`
Dropdown style, not tiles. No slicer on `card_profile` — page 1 should not let someone
filter away the finding.

---

## Page 2 — Merchant risk

*Audience: anti-fraud. Question: which merchants do I act on today?*

### Row 1 — The two labels, side by side

Two clustered bar charts of equal size.

**Left — "The MCC flag separates disputes 49-fold"**
Axis `dim_merchant[mcc_high_risk]`, value `[Dispute rate]`.

**Right — "The bank's own label runs backwards"**
Axis `dim_merchant[bank_risk_tier]`, value `[Dispute rate]`, with
`dim_merchant[mcc_high_risk] = TRUE` as a visual-level filter. Bars descend left to
right — that descent *is* the finding, so the axis must read low → medium → high.

Two clicks are needed for that, because neither default gives it. Sorting by value is
circular (it would order the bars by the very thing being claimed), and sorting by the
label is alphabetical, which yields high / low / medium. Instead select
`dim_merchant[bank_risk_tier]` in the Data pane and set **Column tools → Sort by column
→ `bank_risk_tier_order`**, then sort the visual by `bank_risk_tier` ascending. The
ordinal rank ships from `views.sql` so the order is a property of the data, not of one
report that could be rebuilt without it.

Add a text box beneath the right chart, 9pt Secondary ink:

> Based on 15 merchants (4 low, 4 medium, 7 high). Significant at transaction level
> (z = 7.44) and consistent in direction across both MCC strata, but the merchant count
> is small — read this as "the label is not working", not as an effect size.

Stating the limitation *inside the report* is the point. A dashboard that only shows the
flattering half of a finding is how a wrong decision gets made six months later.

### Row 2 — Merchant watchlist (the operational output)

Table visual, sorted by `[Disputes]` descending, top 15 rows.

| Column | Field |
| --- | --- |
| Merchant | `dim_merchant[merchant_name]` |
| Category | `dim_merchant[category_name]` |
| Bank label | `dim_merchant[bank_risk_tier]` |
| Approved | `[Approved]` |
| Disputes | `[Disputes]` |
| Dispute rate | `[Dispute rate]` |
| Share of all disputes | `[Dispute share]` |

Conditional formatting: background `#fbeceb` on the **Bank label** cell when the value is
`low` or `medium` — the mismatch between the label and the dispute count is what the
analyst needs to see at a glance. Data bars on **Disputes** in `#d03b3b`.

Title: **"Five merchants carry 80.9% of every dispute"**

### Row 3 left — Dispute rate by category

Horizontal bar, axis `dim_merchant[category_name]`, value `[Dispute rate]`, top 12 by
value. `#d03b3b` where `is_priority_category = TRUE`, Neutral elsewhere.

Subtitle: "Betting and Online Gaming are 1.7% of approved volume and 80.9% of disputes."

### Row 3 right — Dispute rate by channel

Bar, axis `dim_terminal[channel]`, value `[Dispute rate]`. ECOM in `#d03b3b`.

Subtitle: "1.244% card-not-present against 0.073% card-present — 17×."

### Slicers

`dim_merchant[category_group]` · `dim_merchant[bank_risk_tier]` · `dim_date[quarter_name]`

---

## Publishing it

A `.pbix` is a binary — GitHub renders nothing. So:

1. Commit `dashboard/uzcard-payments.pbix`.
2. Export both pages to PNG at 1280 × 720 into `assets/` as
   `10-dashboard-overview.png` and `11-dashboard-merchant-risk.png`.
3. Embed the overview screenshot near the top of the project README, above the
   fold — for most visitors the screenshot *is* the dashboard.

If the report is later published to Power BI Service, put the public link in the project
README as well; a live link beats a screenshot when one is available.

---

## What this spec deliberately leaves out

- **No map visual.** `device_city` exists, but geography carried no signal — decline
  rates across all 14 regions sit between 5.45% and 7.39% with small denominators. A map
  would look impressive and say nothing.
- **No daily granularity anywhere.** 26 calendar days are missing from 2023, spread
  evenly across weekdays. A daily line would show dips that are artefacts.
- **No gauge, no donut, no KPI trend arrow.** There is no target to measure against and
  no prior period to trend, so all three would be decoration.
