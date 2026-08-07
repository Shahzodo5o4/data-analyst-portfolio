-- ============================================================================
-- Dashboard semantic layer — a star schema over the uzcard schema
-- ============================================================================
-- Power BI is pointed at these views, never at the raw tables. Three reasons:
--
--   1. A star schema (one fact, five conformed dimensions) is what Power BI's
--      engine is built for. Importing the normalised tables and letting the
--      report author re-join them pushes modelling work into DAX, where it is
--      slower and much harder to review.
--   2. Business logic lives in one place. "Dispute rate" means disputes over
--      APPROVED transactions everywhere — encoded here once, so a report can
--      not accidentally redefine it.
--   3. The derived attributes the analysis needs (card_profile, age_band,
--      tenure) are computed in SQL where they can be tested, not in the report.
--
-- Run:  psql -d portfolio -f dashboard/views.sql
-- ============================================================================

DROP VIEW IF EXISTS uzcard.fact_transactions, uzcard.dim_date, uzcard.dim_customer,
                    uzcard.dim_card, uzcard.dim_merchant, uzcard.dim_terminal,
                    uzcard.dim_hour, uzcard.rule_scorecard CASCADE;


-- ---------------------------------------------------------------- dimensions

-- Generated from the observed transaction window rather than a fixed range, so
-- the calendar can never be shorter than the facts it has to cover.
CREATE VIEW uzcard.dim_date AS
SELECT
    d::date                                   AS date_key,
    extract(year    FROM d)::int              AS year,
    extract(quarter FROM d)::int              AS quarter,
    'Q' || extract(quarter FROM d)::int       AS quarter_name,
    date_trunc('month', d)::date              AS month_start,
    to_char(d, 'Mon')                         AS month_name,
    extract(month FROM d)::int                AS month_number,
    extract(week  FROM d)::int                AS iso_week,
    to_char(d, 'Dy')                          AS day_name,
    extract(isodow FROM d)::int               AS day_number,
    extract(isodow FROM d) >= 6               AS is_weekend
FROM generate_series(
        (SELECT min(txn_ts)::date FROM uzcard.transactions),
        (SELECT max(txn_ts)::date FROM uzcard.transactions),
        interval '1 day') AS d;


-- full_name is deliberately not exposed: it is personal data and no visual needs it.
CREATE VIEW uzcard.dim_customer AS
SELECT
    customer_id,
    customer_segment                          AS segment,
    income_band,
    region,
    gender,
    onboarding_date,
    date_part('year', age(DATE '2023-12-31', birth_date))::int AS age,
    CASE
        WHEN age(DATE '2023-12-31', birth_date) < interval '25 years' THEN 'under 25'
        WHEN age(DATE '2023-12-31', birth_date) < interval '35 years' THEN '25-34'
        WHEN age(DATE '2023-12-31', birth_date) < interval '50 years' THEN '35-49'
        ELSE '50+'
    END                                       AS age_band,
    (DATE '2023-12-31' - onboarding_date) / 30 AS tenure_months
FROM uzcard.customers;


-- card_profile is the finding, promoted to a first-class attribute. Every visual
-- that needs the Simpson's paradox slices on this one column instead of rebuilding
-- the CASE expression in DAX.
CREATE VIEW uzcard.dim_card AS
SELECT
    c.card_id,
    c.customer_id,
    c.card_type,
    c.product_tier,
    c.status                                  AS card_status,
    c.credit_limit,
    c.credit_limit = 0                        AS is_debit,
    c.product_tier = 'virtual'                AS is_virtual,
    CASE
        WHEN cu.customer_segment = 'student' AND c.product_tier = 'virtual'
            THEN 'student · virtual'
        WHEN cu.customer_segment = 'student'
            THEN 'student · other card'
        WHEN c.product_tier = 'virtual'
            THEN 'non-student · virtual'
        ELSE 'non-student · other card'
    END                                       AS card_profile
FROM uzcard.cards c
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id;


-- Both risk labels sit side by side on purpose: the dashboard's job on page 2 is
-- to let someone compare them.
CREATE VIEW uzcard.dim_merchant AS
SELECT
    m.merchant_id,
    m.merchant_name,
    m.region                                  AS merchant_region,
    m.risk_tier                               AS bank_risk_tier,
    -- low/medium/high is an ordinal scale, but every BI tool sorts text
    -- alphabetically and would render it high, low, medium. The page 2 chart is
    -- read as a descent from low to high, so the order carries the finding and
    -- has to travel with the data rather than be re-created in the report.
    CASE m.risk_tier WHEN 'low' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END
                                              AS bank_risk_tier_order,
    mc.mcc_code,
    mc.category_name,
    mc.category_group,
    mc.is_high_risk                           AS mcc_high_risk,
    -- the sharper target from the analysis: two categories, not the whole flag
    mc.category_name IN ('Betting', 'Online Gaming') AS is_priority_category,
    -- the same split with a label instead of a boolean, so the page 3 matrix reads
    -- as words rather than as True / False
    CASE WHEN mc.category_name IN ('Betting', 'Online Gaming')
         THEN 'Betting / Online Gaming' ELSE 'every other category' END AS category_set
FROM uzcard.merchants m
JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code;


-- 24 rows. The hour is a dimension and not a column on the fact for the same
-- reason the date is: it needs a label, a sort order and a grouping, and a report
-- that rebuilds "is this the night window?" in DAX can get it wrong once per visual.
CREATE VIEW uzcard.dim_hour AS
SELECT
    h                                         AS hour_of_day,
    to_char(make_time(h::int, 0, 0), 'HH24:00') AS hour_label,
    h < 5                                     AS is_night_window,
    CASE WHEN h < 5 THEN '00:00-04:59' ELSE '05:00-23:59' END AS time_band
FROM generate_series(0, 23) AS h;


CREATE VIEW uzcard.dim_terminal AS
SELECT
    terminal_id,
    merchant_id,
    channel,
    channel <> 'ECOM'                         AS is_card_present,
    device_city,
    is_active
FROM uzcard.terminals;


-- ---------------------------------------------------------------------- fact

-- Grain: one row per transaction. The status flags are pre-split into integers so
-- every measure in the report is a plain SUM - no FILTER logic to get wrong, and
-- the approved-only dispute denominator is impossible to bypass by accident.
CREATE VIEW uzcard.fact_transactions AS
SELECT
    t.transaction_id,
    t.txn_ts,
    t.txn_ts::date                            AS date_key,
    t.card_id,
    c.customer_id,
    t.merchant_id,
    t.terminal_id,
    t.amount_uzs,
    t.txn_status,
    t.decline_reason,
    t.entry_mode,
    t.is_recurring,
    (t.txn_status = 'approved')::int          AS is_approved,
    (t.txn_status = 'declined')::int          AS is_declined,
    (t.txn_status = 'reversed')::int          AS is_reversed,
    t.is_disputed::int                        AS is_disputed,
    extract(hour FROM t.txn_ts)::int          AS hour_of_day,
    CASE WHEN t.txn_status = 'approved' THEN t.amount_uzs ELSE 0 END AS approved_amount_uzs,
    -- the money side of a dispute: exposure, not realised loss (see README method notes)
    CASE WHEN t.is_disputed THEN t.amount_uzs ELSE 0 END AS disputed_amount_uzs,
    -- funding vs everything else: the split the decline analysis turns on
    (t.decline_reason IN ('insufficient_funds', 'limit'))::int AS is_funding_decline,
    -- The step-up rule, as one pre-computed flag. It spans three dimensions
    -- (channel, merchant category, hour), so leaving it to the report would mean
    -- re-deriving a three-way condition in every visual that mentions the rule.
    -- Scored on approved transactions only, exactly as the analysis scores it: a
    -- declined payment never settles and so can never turn into a dispute.
    (t.txn_status = 'approved'
     AND te.channel = 'ECOM'
     AND mc.category_name IN ('Betting', 'Online Gaming')
     AND extract(hour FROM t.txn_ts) < 5)::int AS is_rule_d
FROM uzcard.transactions t
JOIN uzcard.cards c            ON c.card_id = t.card_id
JOIN uzcard.terminals te       ON te.terminal_id = t.terminal_id
JOIN uzcard.merchants m        ON m.merchant_id = t.merchant_id
JOIN uzcard.mcc_categories mc  ON mc.mcc_code = m.mcc_code;


-- ----------------------------------------------------------- rule scorecard
-- Four candidate step-up rules, already scored. This is an aggregate summary, not
-- a fact table: it loads into the model as a DISCONNECTED table with no
-- relationship, because its grain is "one row per rule" and nothing else in the
-- model shares that grain. Precomputing it here is what stops the report from
-- quoting a precision figure the analysis never produced.
CREATE VIEW uzcard.rule_scorecard AS
WITH base AS (
    SELECT
        t.amount_uzs,
        t.is_disputed,
        te.channel = 'ECOM'                                      AS is_cnp,
        mc.is_high_risk                                          AS mcc_flag,
        mc.category_name IN ('Betting', 'Online Gaming')         AS target_cat,
        extract(hour FROM t.txn_ts) < 5                          AS is_night
    FROM uzcard.transactions t
    JOIN uzcard.terminals te      ON te.terminal_id = t.terminal_id
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    WHERE t.txn_status = 'approved'
),
observed_days AS (
    SELECT count(DISTINCT date_trunc('day', txn_ts)) AS days FROM uzcard.transactions
),
rules AS (
    SELECT * FROM (VALUES
        (1, 'A  card-not-present'),
        (2, 'B  A + high-risk MCC flag'),
        (3, 'C  A + Betting / Online Gaming'),
        (4, 'D  C + 00:00-04:59')
    ) AS r(rule_order, rule)
),
fired AS (
    SELECT r.rule_order, r.rule, b.is_disputed, b.amount_uzs,
           CASE r.rule_order
               WHEN 1 THEN b.is_cnp
               WHEN 2 THEN b.is_cnp AND b.mcc_flag
               WHEN 3 THEN b.is_cnp AND b.target_cat
               WHEN 4 THEN b.is_cnp AND b.target_cat AND b.is_night
           END AS fires
    FROM base b CROSS JOIN rules r
)
SELECT
    f.rule_order,
    f.rule,
    count(*) FILTER (WHERE f.fires)                              AS flagged,
    round(count(*) FILTER (WHERE f.fires)::numeric / d.days, 1)  AS prompts_per_day,
    round(100.0 * count(*) FILTER (WHERE f.fires AND f.is_disputed)
          / count(*) FILTER (WHERE f.is_disputed), 1)            AS coverage_pct,
    round(100.0 * count(*) FILTER (WHERE f.fires AND f.is_disputed)
          / nullif(count(*) FILTER (WHERE f.fires), 0), 1)       AS precision_pct,
    sum(f.amount_uzs) FILTER (WHERE f.fires AND f.is_disputed)   AS uzs_protected
FROM fired f CROSS JOIN observed_days d
GROUP BY f.rule_order, f.rule, d.days;


-- ---------------------------------------------------------------- smoke tests
-- The numbers below must match the README. If a view is edited and these drift,
-- the dashboard is quoting something the analysis never said.

\echo '\n== Smoke test: these must match the README =='

SELECT
    count(*)                                                        AS transactions,
    round(100.0 * sum(is_declined) / count(*), 2)                   AS decline_pct,
    round(100.0 * sum(is_disputed) / sum(is_approved), 3)           AS dispute_pct,
    to_char(sum(approved_amount_uzs), '999,999,999,999')            AS approved_uzs
FROM uzcard.fact_transactions;
-- expected: 60,320 · 6.10% · 0.355% · 11,536,051,000

SELECT
    dc.card_profile,
    count(*)                                                        AS txns,
    round(100.0 * sum(f.is_declined) / count(*), 2)                 AS decline_pct
FROM uzcard.fact_transactions f
JOIN uzcard.dim_card dc ON dc.card_id = f.card_id
GROUP BY dc.card_profile
ORDER BY decline_pct DESC;
-- expected: student · virtual 20.23 | non-student · virtual 5.86
--           non-student · other 5.83 | student · other 5.69

-- The page 2 headline: sorted by bank_risk_tier_order the dispute rate must
-- descend. If it ever climbs, either the label started working or the sort
-- column is wrong — both change what the chart is allowed to claim.
SELECT
    dm.bank_risk_tier,
    dm.bank_risk_tier_order,
    count(*) FILTER (WHERE f.is_approved = 1)                       AS approved,
    sum(f.is_disputed)                                              AS disputes,
    round(100.0 * sum(f.is_disputed)
          / nullif(count(*) FILTER (WHERE f.is_approved = 1), 0), 3) AS dispute_pct
FROM uzcard.fact_transactions f
JOIN uzcard.dim_merchant dm ON dm.merchant_id = f.merchant_id
WHERE dm.mcc_high_risk
GROUP BY dm.bank_risk_tier, dm.bank_risk_tier_order
ORDER BY dm.bank_risk_tier_order;
-- expected, in this order: low 6.498 | medium 3.607 | high 1.526

-- The page 3 headline: the interaction. Neither condition does this on its own,
-- so all four cells have to be present for the visual to be honest.
SELECT
    CASE WHEN dm.is_priority_category THEN 'Betting / Online Gaming'
         ELSE 'every other category' END                             AS category_set,
    dh.time_band,
    count(*) FILTER (WHERE f.is_approved = 1)                        AS approved,
    sum(f.is_disputed)                                               AS disputes,
    round(100.0 * sum(f.is_disputed)
          / nullif(count(*) FILTER (WHERE f.is_approved = 1), 0), 3) AS dispute_pct
FROM uzcard.fact_transactions f
JOIN uzcard.dim_merchant dm ON dm.merchant_id = f.merchant_id
JOIN uzcard.dim_hour dh     ON dh.hour_of_day = f.hour_of_day
GROUP BY 1, 2
ORDER BY 1, 2;
-- expected: Betting/Online Gaming  00:00-04:59  46.921 | 05:00-23:59  0.164
--           every other category   00:00-04:59   0.000 | 05:00-23:59  0.071

-- The rule the report recommends, straight from the fact flag. If the flag and the
-- scorecard ever disagree, one of the two was edited without the other.
SELECT
    sum(f.is_rule_d)                                                 AS flagged,
    round(sum(f.is_rule_d)::numeric
          / (SELECT count(DISTINCT date_key) FROM uzcard.fact_transactions), 1)
                                                                     AS prompts_per_day,
    sum(f.is_disputed) FILTER (WHERE f.is_rule_d = 1)                AS disputes_caught,
    round(100.0 * sum(f.is_disputed) FILTER (WHERE f.is_rule_d = 1)
          / nullif(sum(f.is_rule_d), 0), 1)                          AS precision_pct,
    to_char(sum(f.disputed_amount_uzs) FILTER (WHERE f.is_rule_d = 1),
            '999,999,999')                                           AS uzs_protected
FROM uzcard.fact_transactions f;
-- expected: 341 · 1.0 · 160 · 46.9% · 102,283,700

SELECT rule, flagged, prompts_per_day, coverage_pct, precision_pct,
       to_char(uzs_protected, '999,999,999') AS uzs_protected
FROM uzcard.rule_scorecard
ORDER BY rule_order;
-- expected: A 13,502 · 40.2 · 84.4 · 1.2   | B 952 · 2.8 · 80.9 · 16.9
--           C    952 ·  2.8 · 80.9 · 16.9  | D 341 · 1.0 · 80.4 · 46.9
