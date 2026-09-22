# Power BI rebuild checklist — matching the refined web layout

This applies the same refinements (sidebar navigation, lower density, fixed
watchlist) to the `.pbix`. Power BI can't literally copy the HTML, but every
change below is native and reproducible. Work on a copy of `uzcard-payments.pbix`.

## 0. Before you start
- Load `theme.json` (View → Themes → Browse) if not already applied.
- The three pages already exist. You will re-space them, not rebuild the model.

## 1. Turn the top slicer strip into a left rail (the big one)
This is what "put the tabs on the side" means in Power BI terms.
1. On each page, select the three slicers in the header and **move them to a
   vertical column down the left**, x ≈ 24, stacked with ~16px gaps, each ~200px wide.
2. Add a left **background panel**: Insert → Shapes → Rectangle, x 0 / y 0 /
   w 240 / h 720, fill `#fcfcfb`, add only a right border `#e1e0d9` (Format shape →
   Border → uncheck all sides except right, if your build supports it; otherwise a
   1px `#e1e0d9` line shape at x 240).
3. Put the page title at the top of that rail (two lines, `UZCARD / card payments`,
   Segoe UI Semibold), with `2023 · 60,320 txns` under it in `#898781`.
4. Page navigation between the three pages: Insert → **Buttons → Blank**, one per
   page, stacked under the title. Format → Action → Type = **Page navigation** →
   Destination = the target page. Style the current page's button with a left
   accent bar (a 2px `#0b0b0b` rectangle at its left edge) and Ink text; the others
   `#898781`. This is the sidebar tab list.
5. Shift every visual on the page right by 240px so nothing sits under the rail
   (Format → General → Position → X += 240, or drag).

## 2. Lower the density (fewer, larger visuals per screen)
- Increase the gaps between visuals to ~24px and let each chart grow into the
  freed space. Aim for **no more than 4 visuals in the main area per screen**
  besides the KPI row.
- Bump title font to 14–16pt and turn OFF: visual borders, shadows, and vertical
  gridlines (the theme already does most of this globally).
- On bar/column charts, remove per-bar data labels except the ones that matter;
  keep the axis clean.

## 3. Fix the merchant watchlist height (the table that was too long)
1. Select the watchlist table → **Format → Row → Options → Rows per page** (or
   filter to **Top N**): set a **Top 7 by Disputes** filter (Filters pane →
   Merchant → Top N → Top → 7 → By value → Disputes).
2. Set Row padding to 1 so 7 rows fit without a scrollbar.
3. This makes the Merchant risk page the same height as the others.

## 4. Colour discipline (one chromatic event per page)
- On the "two labels" page, make the **MCC-flag chart bars grey** (`#c9c8c2`);
  let bar height alone show the 49× gap. Keep **red** only on the tier chart's
  `low` bar (the inversion). Never blue + red as two highlights on one page.
- Segment chart on Overview: all bars grey — the finding lives in the card-profile
  chart, not here.

## 5. Data sanity (the decline-rate bug)
- `txn_status` has three values: `approved`, `declined`, `reversed`.
- `Decline rate` must be `DIVIDE([Declined], [Transactions])` where `[Declined]`
  counts **only** `txn_status = "declined"` — do NOT count `reversed` as declined,
  or the KPI reads 7.10% instead of the correct **6.10%**.

## 6. Re-export
Export each page to PNG at 1280×720 into `../assets/` as
`10-dashboard-overview.png`, `11-dashboard-merchant-risk.png`,
`14-dashboard-the-rule.png`, replacing the old screenshots.
