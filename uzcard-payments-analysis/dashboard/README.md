# Dashboard — build specification

Power BI Desktop, three pages, connected live to the star-schema views in
[`views.sql`](views.sql). This file is the spec the `.pbix` is built from, so the
report can be rebuilt from scratch without guessing at layout or measure definitions.

The three pages answer different questions for different people. Page 1 is for whoever
owns the P&L and wants to know whether anything is wrong. Page 2 is for the anti-fraud
analyst who has to act on it before lunch. Page 3 is for whoever has to approve the rule
and staff the queue it creates — it carries the money and the operating cost.

---

## Before opening Power BI

```bash
psql -d portfolio -f dashboard/views.sql
```

The script ends with six smoke tests. They must print `60,320 · 6.10% · 0.355%`, the four
`card_profile` rows at `20.23 / 5.86 / 5.83 / 5.69`, the risk-tier descent
`6.498 / 3.607 / 1.526`, the four interaction cells at `46.921 / 0.164 / 0.000 / 0.071`,
the rule-D line `341 · 1.0 · 160 · 46.9%`, and the four-row scorecard. If any of them
drift, the model is quoting something the analysis never said — fix that before building
visuals.

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

Select these eight views only:

```
uzcard.fact_transactions      60,320 rows   the fact
uzcard.dim_date                  362 rows   calendar
uzcard.dim_customer            2,000 rows
uzcard.dim_card                3,286 rows
uzcard.dim_merchant              600 rows
uzcard.dim_terminal            2,124 rows
uzcard.dim_hour                   24 rows   hour label + the night-window band
uzcard.rule_scorecard              4 rows   the four candidate rules, pre-scored
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
| `fact_transactions[hour_of_day]` | `dim_hour[hour_of_day]` | many-to-one |

Mark `dim_date` as the date table (`date_key`). Hide every key column from report view —
nothing should be draggable onto a visual except attributes and measures.

Do **not** create a relationship from `dim_card[customer_id]` to `dim_customer`. The fact
already reaches both, and a second path makes the model ambiguous.

`rule_scorecard` stays **disconnected** — no relationship to anything. Its grain is one
row per candidate rule, which nothing else in the model shares, and joining it to the fact
on any column would silently filter it. Power BI will not warn about this; leave it
standing alone and let the page-3 table read it directly. Because it is disconnected, the
page-3 slicers do not filter it — that is intended and is called out on the page.

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

-- share of the visible period, for the channel trend. Only the channel filter is
-- removed from the denominator; whatever date grain the axis supplies is left alone,
-- so the measure does not break when the axis changes from month_start to month_name.
Share of month =
    DIVIDE([Transactions],
           CALCULATE([Transactions], ALL('dim_terminal')))

-- dispute concentration, for the watchlist
Dispute share = DIVIDE([Disputes], CALCULATE([Disputes], ALL('dim_merchant')))

-- ── page 3: the money and the operating cost ────────────────────────────────
-- Exposure, not realised loss. The card subtitle has to say so.
Disputed value    = SUM('fact_transactions'[disputed_amount_uzs])

-- The rule is one pre-computed flag in the fact, so these stay plain SUMs too.
Rule D prompts    = SUM('fact_transactions'[is_rule_d])
Rule D caught     = CALCULATE([Disputes], 'fact_transactions'[is_rule_d] = 1)
Rule D protected  = CALCULATE([Disputed value], 'fact_transactions'[is_rule_d] = 1)

-- 336, not 365: the same missing-days correction the analysis uses. DISTINCTCOUNT
-- over the fact's own dates means a quarter slicer rescales it correctly instead of
-- dividing a quarter's prompts by a year.
Observed days       = DISTINCTCOUNT('fact_transactions'[date_key])
Rule D prompts/day  = DIVIDE([Rule D prompts], [Observed days])
Rule D precision    = DIVIDE([Rule D caught], [Rule D prompts])
Rule D coverage     = DIVIDE([Rule D caught], CALCULATE([Disputes], ALL('fact_transactions')))
```

Format `Decline rate`, `Dispute rate`, `Share of month`, `Dispute share`,
`Rule D precision` and `Rule D coverage` as percentage — 2 decimals for decline, **3 for
dispute** (the interesting differences live in the third place), 1 for the two rule
measures. `Approved value`, `Disputed value` and `Rule D protected` as whole UZS with
thousands separators. `Rule D prompts/day` to one decimal.

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

Column *i* starts at `x = 24 + (i − 1) × 104`; a visual spanning *n* columns is
`104n − 16` wide. Column 12 therefore ends at 1256, leaving the 24px right margin. Every
visual below is given as span + absolute pixels, because "roughly half the row" is how
visuals end up overlapping — Power BI's Format → General → Position accepts the numbers
directly.

| Band | y | Height | Contents |
| --- | ---: | ---: | --- |
| Header | 24 | 62 | page title (left, y 39) · three slicers, cols 7-8, 9-10, 11-12 |
| Row 1 | 102 | 106 | four KPI cards, span 3 each — x 24 / 336 / 648 / 960, w 296 |
| Subtitle | 210 | 22 | four text boxes — x 44 / 356 / 668 / 980, w 256 |
| Row 2 | 248 | 240 | card profile span 7 (x 24, w 712) · segment span 5 (x 752, w 504) |
| Row 3 | 504 | 192 | channel share, span 12 (x 24, w 1232) |

A slicer needs **62px**, not the 32 a header line suggests: at 10pt the title and the
dropdown box each claim their own row, and below about 56 the dropdown has nowhere to
open and simply never appears. Every band below the header therefore sits 30px lower
than a naive grid would put it.

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

**Clustered bar chart** — horizontal, not a column chart. Axis `dim_card[card_profile]`,
value `[Decline rate]`. The four category names run to 24 characters
(`non-student · other card`); under vertical columns Power BI either rotates them 45° or
truncates them, and a rotated label on the visual that carries the finding is a bad
trade. Horizontal bars give each name a full line at 10pt.

Conditional formatting on the bars: `#d03b3b` when `card_profile = "student · virtual"`,
otherwise `#c9c8c2`. Add a constant line at the book average in Secondary ink, dashed,
labelled — set its value with `fx` bound to `[Decline rate (book)]` (6.10%) rather than
typing a number, so it cannot drift from the model. On a horizontal bar the constant line
is vertical, which reads correctly: every bar either crosses it or does not. Note this is
the *book* rate, not the 5.83% non-student rate quoted in the README; the two answer
different questions and mixing them up mislabels the line.

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

Line chart. Axis **`dim_date[month_name]`** — not `month_start`. A date axis renders
"Jan 2023" and, at 1232px with twelve points, Power BI drops every other label rather
than crowd them; `month_name` is three characters and all twelve fit. Set **Column tools
→ Sort by column → `month_number`** first, or the axis reads Apr, Aug, Dec. Being text,
the axis is categorical and the `Type` setting disappears — that is expected, not a
missing option.

Legend `dim_terminal[channel]`, value `[Share of month]`. ECOM in `#2a78d6` at stroke
width 3, every other channel in Neutral. Direct-label the line ends via **Series labels**;
no legend box. Power BI drops labels it cannot fit, so ATM and P2P may not render — group
them under one `QR · ATM · P2P` note rather than leaving two of five unlabelled.

Title: **"E-commerce is the only channel gaining share"**
Subtitle: "Share of monthly transactions — monthly because 26 calendar days are missing."

### Slicers (top-right, one row)

`dim_date[quarter_name]` · `dim_terminal[channel]` · `dim_customer[segment]`
Dropdown style, not tiles. Use the **classic Slicer** visual — the newer *List slicer
(preview)* has no Style setting and therefore no dropdown at all, only the Selection
options. Set it under Format → Visual → Slicer settings → Options → Style → Dropdown.

No slicer on `card_profile` — page 1 should not let someone filter away the finding.

A collapsed slicer is a trap worth naming: at 32px the visual shows its header and
nothing else, so a selection left behind is invisible while it silently filters the whole
page. If the KPI cards ever read something other than 60,320, check the slicers before
suspecting the model.

---

## Page 2 — Merchant risk

*Audience: anti-fraud. Question: which merchants do I act on today?*

**Canvas** 1280 × 720, same grid and the same 62px slicer band as page 1.

| Band | y | Height | Contents |
| --- | ---: | ---: | --- |
| Header | 24 | 62 | page title (left, y 39) · three slicers, cols 7-8, 9-10, 11-12 |
| Row 1 | 102 | 184 / 144 | MCC flag span 6 (x 24, h 184) · bank label span 6 (x 648, h 144) |
| Caption | 250 | 36 | text box under the right chart (x 648, w 608) |
| Row 2 | 302 | 226 | merchant watchlist, span 12 (x 24, w 1232) |
| Row 3 | 544 | 152 | category span 7 (x 24, w 712) · channel span 5 (x 752, w 504) |

The right chart is shorter than its neighbour because the caption belongs to it: chart
plus caption is 184, the same as the left column. The eye reads the column, not the
chart. Drop the right chart's subtitle — the caption below already does that job and
gives the plot another 16px.

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

Set **Format → Grid → Options → Row padding** to `1`. At the default 4 a row is ~30px and
six of them overflow a 226px box, so the visual scrolls and the PNG export carries the
scrollbar with it. At 1 the same box holds seven rows without one.

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

**Column chart**, axis `dim_merchant[category_name]`, value `[Dispute rate]`, **top 3**
by value. `#d03b3b` where `is_priority_category = TRUE`, Neutral elsewhere.

Horizontal bars stack categories down a 152px band and Power BI enforces a minimum bar
height, so anything past three rows produces a scrollbar that survives into the PNG
export. Vertical columns spread the same categories across 712px of width instead. Three
is also enough: Betting 17.742%, Online Gaming 13.942%, then Grocery at 0.177%. The third
column is not filler, it is the cliff.

Subtitle: "Betting and Online Gaming are 1.7% of approved volume and 80.9% of disputes."

### Row 3 right — Dispute rate by channel

Bar, axis `dim_terminal[channel]`, value `[Dispute rate]`. ECOM in `#d03b3b`.

Subtitle: "1.244% card-not-present against 0.073% card-present — 17×."

### Slicers

`dim_merchant[category_group]` · `dim_merchant[bank_risk_tier]` · `dim_date[quarter_name]`

---

## Page 3 — The rule, and what it costs

*Audience: whoever approves the rule and staffs the queue. Question: how much money is
on the table, and what does catching it cost per day?*

Pages 1 and 2 show where the problem is. This page exists because "80.9% of disputes" is
not a decision — a rule that flags 40 transactions a day and one that flags 1 both cover
roughly the same disputes, and only one of them is deployable.

**Canvas** 1280 × 720, same 12-column grid as page 1.

| Band | y | Height | Contents |
| --- | ---: | ---: | --- |
| Header | 24 | 62 | page title (left, y 39) · three slicers, cols 7-8, 9-10, 11-12 |
| Row 1 | 102 | 106 | four KPI cards, span 3 each — x 24 / 336 / 648 / 960, w 296 |
| Subtitle | 210 | 22 | four text boxes — x 44 / 356 / 668 / 980, w 256 |
| Row 2 | 248 | 200 | hour profile span 7 (x 24, w 712) · interaction matrix span 5 (x 752, w 504) |
| Row 3 | 464 | 232 | rule scorecard span 7 (x 24, w 712) · quarterly load span 5 (x 752, w 504) |

### Row 1 — KPI cards

| Card | Measure | Subtitle |
| --- | --- | --- |
| Disputed value | `[Disputed value]` | exposure, not booked loss |
| Protected by rule D | `[Rule D protected]` | 89.9% of it |
| Prompts a day | `[Rule D prompts/day]` | across 336 observed days |
| Precision | `[Rule D precision]` | 1 prompt in 2 is a real dispute |

The first subtitle is not decoration. `is_disputed` is a flag with no resolution or
chargeback outcome, so this number is volume at risk and would be wrong to read as a loss.
A KPI card without that line invites exactly the wrong reading.

### Row 2 left — Dispute rate by hour *(the headline)*

**Column chart** — this is the one place vertical columns beat horizontal bars, because
the x-axis is a clock and the reader already knows which way it runs. Axis
`dim_hour[hour_label]`, value `[Dispute rate]`, visual-level filter
`dim_terminal[channel] = "ECOM"`.

`hour_label` is text, so Power BI will sort it alphabetically — `00:00`, `01:00` … happens
to come out right here, but only by luck of the zero padding. Set **Column tools → Sort by
column → `hour_of_day`** anyway, the same way `bank_risk_tier` is handled on page 2: the
order is a property of the data, not a coincidence of the label format.

Colour the window by putting **`dim_hour[time_band]` in the Legend** well and setting the
two series directly — `00:00-04:59` in `#d03b3b`, `05:00-23:59` in `#2a78d6`. A `fx →
Field value` measure is the textbook route but depends on the Postgres boolean surviving
the import as a real boolean, which it does not always do; a legend needs no DAX at all.

Use a **stacked** column chart, not clustered. With a legend present, clustered reserves a
slot per series in every category and halves the bar width even though each hour belongs
to exactly one band. Stacked puts both series in the same slot and the bars stay full
width.

Data labels off — twenty-four columns will not carry them, and only five matter.

Title: **"Card-not-present disputes are not spread across the day"**
Subtitle: "160 of 168 happen between 00:00 and 04:59."

### Row 2 right — The interaction

**Matrix.** Rows `dim_merchant[category_set]`, columns `dim_hour[time_band]`, values
`[Dispute rate]`. Four cells, no totals — switch row and column subtotals off, because a
total across an interaction is the marginal number this page exists to discredit.

Conditional background on the value cells: `#d03b3b` at 12% opacity above 1%, canvas
elsewhere. The reader should see one hot cell out of four.

Title: **"Neither condition does this alone"**
Subtitle: "The same merchants trade all day at 0.164%. Every other category at night is at
zero."

### Row 3 left — The four candidate rules

The four KPI cards above read the **fact-based** measures, not `rule_scorecard`. Both
would print 1.0 / 80.4% / 46.9% / 102.3 mln on an unfiltered page, but only the fact-based
ones respond to the Quarter and Category slicers sitting three centimetres above them. A
KPI that ignores the slicer next to it is a bug the reader discovers, not a design choice.

`rule_scorecard` earns its place as a pre-scored table, not as a measure source: the four
candidate rules are a fixed comparison, computed once in SQL where they can be reviewed.

Table visual reading `rule_scorecard` directly — a disconnected table, so the page slicers
do not touch it. Columns in order: `rule`, `flagged`, `prompts_per_day`, `coverage_pct`,
`precision_pct`, `uzs_protected`. Sort by `rule_order` (Column tools → Sort by column on
`rule`), not by any of the values.

Bold the `D` row. Data bars on `prompts_per_day` in `#c9c8c2` — 40.2 against 1.0 is the
whole argument, and a bar makes the ratio visible without a second chart.

Title: **"Same coverage, a fortieth of the work"**

Add a text box beneath, 9pt Secondary ink:

> B and C are identical because Crypto/FX and Money Transfer never settle on ECOM, so
> requiring card-not-present already excludes them. A fifth rule — the five named
> merchants in the same window — selects exactly the same 341 transactions as D.

### Row 3 right — Prompts a day, by quarter

**Line and clustered column chart.** Axis `dim_date[quarter_name]`; columns `[Approved]`
in Neutral, line `[Rule D prompts/day]` in `#d03b3b` at stroke width 3.

Two measures three orders of magnitude apart on one chart is the most common way a
dashboard lies, so the second axis is only safe under one condition: **set the secondary
range manually to 0–2.** Left on Auto, Power BI fits it to the data, 1.0 → 1.1 fills a
third of the plot, and the chart contradicts its own title. Pinned to 0–2 the line is
visibly flat and the argument survives.

The comparison is worth making visually rather than in prose. "Volume grew 6.5×, load did
not move" is the whole reason the rule ships at current headcount, and a reader takes that
from two shapes faster than from a sentence.

Title: **"The load does not grow with the book"**
Subtitle: "Approved volume rises 6.5× across 2023; the rule still fires once a day."

### Slicers

`dim_date[quarter_name]` · `dim_merchant[category_group]`

No slicer on `dim_hour` — the window is the finding, and a page that lets someone filter
to 14:00 and conclude "there is no dispute problem" is worse than no page.

### The caveat, on the page

Bottom of the canvas, 9pt Secondary ink, full width:

> The 00:00–04:59 boundary is sharper than real behaviour: this is generated course data.
> Re-fit the window against live data before deploying the rule. Coverage and precision
> are in-sample — scored on the same year they were fitted on.

---

## Publishing it

A `.pbix` is a binary — GitHub renders nothing. So:

1. Commit `dashboard/uzcard-payments.pbix`.
2. Export all three pages to PNG at 1280 × 720 into `assets/` as
   `10-dashboard-overview.png`, `11-dashboard-merchant-risk.png` and
   `14-dashboard-rule.png`. (12 and 13 are the notebook's hour-window and
   rule-tradeoff charts — the numbering is chronological, not thematic.)
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
  evenly across weekdays. A daily line would show dips that are artefacts. The hour
  profile on page 3 is not an exception: it aggregates every day in the year into 24
  buckets, so evenly-spread missing days cancel out instead of punching holes.
- **No gauge, no donut, no KPI trend arrow.** There is no target to measure against and
  no prior period to trend, so all three would be decoration.
