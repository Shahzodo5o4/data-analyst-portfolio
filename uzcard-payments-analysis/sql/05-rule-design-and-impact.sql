-- ============================================================================
-- 05 - From finding to decision: when the disputes happen, what a rule costs,
--      and what each finding is worth in money
-- ============================================================================
-- 03 established WHERE disputes sit: card-not-present, Betting and Online
-- Gaming, five merchants. That is a finding, not a decision. Three things have
-- to be added before anyone can act on it:
--
--   1. WHEN - a rule that fires all day costs more than one that fires for five
--      hours. The hour of the transaction was never cut in 03.
--   2. WHAT IT COSTS - coverage is free to promise. Every flagged transaction
--      is either a step-up prompt shown to a real customer or a case in a
--      review queue, so a rule has to be scored on load, not only on catch.
--   3. HOW MUCH IT IS WORTH - "declines" and "disputes" cannot be ranked
--      against each other in percentage points. They can be ranked in UZS.
--
-- Denominator is APPROVED transactions throughout, as in 03: a declined payment
-- never settles, so it can never be disputed.
--
-- Run:  psql -d portfolio -f sql/05-rule-design-and-impact.sql
-- ============================================================================


\echo '\n== 1. Dispute rate by hour of day, card-not-present =='

SELECT
    extract(hour FROM t.txn_ts)::int                             AS hour_of_day,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 2) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
WHERE te.channel = 'ECOM'
GROUP BY 1
ORDER BY 1;

-- The series is not a gradient, it is a cliff. Hours 00-04 run 19.5% - 27.0%.
-- Hours 05-23 run 0.000% with five exceptions, none above 0.45%. The whole of
-- the card-not-present dispute problem lives in a five-hour window.


\echo '\n== 2. Is the window a card-not-present effect, or does the clock do this everywhere? =='
-- A finding that reproduces in every channel is a property of the clock, not of
-- the channel, and would not justify a card-not-present rule.

SELECT
    te.channel,
    CASE WHEN extract(hour FROM t.txn_ts) < 5 THEN '00:00-04:59'
         ELSE '05:00-23:59' END                                  AS window,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
GROUP BY 1, 2
ORDER BY 1, 2;

-- ECOM at night: 160 disputes on 687 approved = 23.290%.
-- Every card-present channel at night: 0 disputes on 1,170 approved.
-- ATM, POS, P2P and QR are flat across the clock. The window is specific to
-- card-not-present - the two conditions only bite together.


\echo '\n== 3. The interaction: category x window =='
-- 03 named Betting and Online Gaming. Cross them against the window to see
-- which of the two conditions is actually carrying the effect.

SELECT
    CASE WHEN mc.category_name IN ('Betting', 'Online Gaming')
         THEN 'Betting / Online Gaming' ELSE 'every other category' END AS category_set,
    CASE WHEN extract(hour FROM t.txn_ts) < 5 THEN '00:00-04:59'
         ELSE '05:00-23:59' END                                  AS window,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
GROUP BY 1, 2
ORDER BY 1, 2;

--                           00:00-04:59        05:00-23:59
--   Betting / Online Gaming  46.921%  (160/341)   0.164%  (1/611)
--   every other category      0.000%  (0/1,516)   0.071%  (38/53,572)
--
-- Neither condition works alone. The same merchants during the day dispute at
-- 0.164%; every other category at night disputes at zero. The rate lives in
-- the intersection: 46.9% against 0.16%, a gap of 46.76 points
-- (z = 18.45, p < 0.001, 95% CI [41.45, 52.06]).
--
-- This is the same shape as the student virtual card finding in 02: neither
-- margin is remarkable, the cell is. Two of the three findings in this repo are
-- interactions, which is the argument for never stopping at a GROUP BY.


\echo '\n== 4. Rule out the obvious artifact: do these merchants only trade at night? =='
-- If Betting volume were nocturnal, the window would be a restatement of the
-- category and would add nothing to a rule.

SELECT
    extract(hour FROM t.txn_ts)::int                             AS hour_of_day,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes
FROM uzcard.transactions t
JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
WHERE mc.category_name IN ('Betting', 'Online Gaming')
GROUP BY 1
ORDER BY 1;

-- They trade around the clock: 341 approved in the five night hours against 611
-- across the other nineteen. Night is 36% of their volume and 99.4% of their
-- disputes. The window is a real second condition, not the category restated.


\echo '\n== 5. What is left of the e-commerce risk once the window is removed? =='

WITH tagged AS (
    SELECT
        t.is_disputed,
        te.channel = 'ECOM'                                      AS is_cnp,
        mc.category_name IN ('Betting', 'Online Gaming')
            AND extract(hour FROM t.txn_ts) < 5                  AS in_window
    FROM uzcard.transactions t
    JOIN uzcard.terminals te      ON te.terminal_id = t.terminal_id
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    WHERE t.txn_status = 'approved'
)
SELECT
    CASE WHEN NOT is_cnp                THEN 'card-present (all channels)'
         WHEN is_cnp AND in_window      THEN 'e-commerce, in the window'
         ELSE                                'e-commerce, outside the window' END AS bucket,
    count(*)                                                     AS approved,
    count(*) FILTER (WHERE is_disputed)                          AS disputes,
    round(100.0 * count(*) FILTER (WHERE is_disputed) / count(*), 3) AS dispute_pct
FROM tagged
GROUP BY 1
ORDER BY dispute_pct DESC;

-- e-commerce, in the window     :  160 / 341    = 46.921%
-- card-present (all channels)   :   31 / 42,538 =  0.073%
-- e-commerce, outside the window:    8 / 13,161 =  0.061%
--
-- Outside the window, card-not-present is marginally SAFER than card-present.
-- "E-commerce is 17x riskier" is true of the channel average and useless as a
-- basis for policy: it is one five-hour window at two categories, and blanket
-- friction on e-commerce would tax 13,161 clean transactions to reach 8 disputes.


\echo '\n== 6. Score the candidate rules: coverage against operating load =='
-- Every rule below is a step-up authentication trigger. Precision is not an
-- academic score here - it is the share of prompts shown to a customer who was
-- never going to dispute, and 1 - precision is the friction the business pays.

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
    ) AS r(id, rule)
),
fired AS (
    SELECT
        r.id, r.rule, b.is_disputed, b.amount_uzs,
        CASE r.id
            WHEN 1 THEN b.is_cnp
            WHEN 2 THEN b.is_cnp AND b.mcc_flag
            WHEN 3 THEN b.is_cnp AND b.target_cat
            WHEN 4 THEN b.is_cnp AND b.target_cat AND b.is_night
        END AS fires
    FROM base b CROSS JOIN rules r
)
SELECT
    f.rule,
    count(*) FILTER (WHERE f.fires)                              AS flagged,
    round(100.0 * count(*) FILTER (WHERE f.fires) / count(*), 2) AS pct_of_approved,
    round(count(*) FILTER (WHERE f.fires)::numeric / d.days, 1)  AS step_ups_per_day,
    count(*) FILTER (WHERE f.fires AND f.is_disputed)            AS disputes_caught,
    round(100.0 * count(*) FILTER (WHERE f.fires AND f.is_disputed)
          / count(*) FILTER (WHERE f.is_disputed), 1)            AS dispute_coverage_pct,
    round(100.0 * count(*) FILTER (WHERE f.fires AND f.is_disputed)
          / nullif(count(*) FILTER (WHERE f.fires), 0), 1)       AS precision_pct,
    round(sum(f.amount_uzs) FILTER (WHERE f.fires AND f.is_disputed) / 1e6, 1)
                                                                 AS uzs_protected_mln
FROM fired f CROSS JOIN observed_days d
GROUP BY f.id, f.rule, d.days
ORDER BY f.id;

--  rule                            flagged  /day  coverage  precision  protected
--  A  card-not-present              13,502  40.2     84.4%       1.2%   103.2 mln
--  B  A + high-risk MCC flag           952   2.8     80.9%      16.9%   102.4 mln
--  C  A + Betting / Online Gaming      952   2.8     80.9%      16.9%   102.4 mln
--  D  C + 00:00-04:59                  341   1.0     80.4%      46.9%   102.3 mln
--
-- Read the first and last rows together: D gives up 4 points of coverage and
-- 0.9 mln UZS against A, and costs 1 step-up prompt a day instead of 40. Nearly
-- half of D's prompts land on a transaction that really is disputed.
--
-- B and C are identical here, which is worth stating rather than hiding: once
-- card-not-present is required, the MCC flag and the two named categories select
-- the same 952 transactions, because Crypto/FX and Money Transfer settle on P2P
-- and QR, never on ECOM. The flag is over-broad only when used on its own (03).
--
-- One more rule was tested and is deliberately not shown as a recommendation:
-- "the five named merchants, 00:00-04:59" selects exactly the same 341
-- transactions as D. Naming merchants buys nothing over naming the categories,
-- and it would need re-cutting every time a merchant is onboarded.


\echo '\n== 7. Rank the two findings in money, not in percentage points =='
-- Declines and disputes are different currencies of failure. UZS is the only
-- axis both of them sit on.
--
-- ASSUMPTION, stated because it changes the size of the number: both figures are
-- EXPOSURE, not booked loss. A dispute may be resolved in the bank's favour, and
-- a declined customer may succeed on a retry. There is no retry linkage and no
-- dispute outcome in this data, so these are upper bounds. They are the right
-- numbers for ranking two fixes against each other, and the wrong numbers for a
-- P&L line.

WITH disputes AS (
    SELECT sum(t.amount_uzs) AS uzs
    FROM uzcard.transactions t
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    WHERE t.is_disputed
      AND mc.category_name IN ('Betting', 'Online Gaming')
),
decline_cells AS (
    SELECT
        cu.customer_segment = 'student' AND c.product_tier = 'virtual'  AS is_cell,
        count(*)                                                        AS txns,
        count(*) FILTER (WHERE t.txn_status = 'declined')               AS declined,
        avg(t.amount_uzs) FILTER (WHERE t.txn_status = 'declined')      AS avg_ticket
    FROM uzcard.transactions t
    JOIN uzcard.cards c      ON c.card_id = t.card_id
    JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
    GROUP BY 1
),
declines AS (
    -- excess declines = the declines this cell would not have had at the
    -- rest-of-book rate, valued at the cell's own average declined ticket
    SELECT
        cell.txns * (cell.declined::numeric / cell.txns
                     - rest.declined::numeric / rest.txns) * cell.avg_ticket AS uzs
    FROM (SELECT * FROM decline_cells WHERE is_cell)     AS cell
    CROSS JOIN (SELECT * FROM decline_cells WHERE NOT is_cell) AS rest
)
SELECT finding, round(uzs)::bigint AS uzs_at_risk, round(uzs / 1e6, 1) AS mln_uzs, fix
FROM (
    SELECT 'Disputes: Betting and Online Gaming, card-not-present'   AS finding,
           uzs,
           'Step-up authentication on rule D - 1 prompt a day'       AS fix
    FROM disputes
    UNION ALL
    SELECT 'Declines: the student virtual card',
           uzs,
           'Product audit on 134 cards held by 107 customers'
    FROM declines
) ranked
ORDER BY uzs DESC;

-- Disputes: Betting and Online Gaming  102.4 mln UZS   (89.9% of all disputed value)
-- Declines: the student virtual card    16.2 mln UZS   (162 excess declines x 100,231)
--
-- The dispute finding is worth 6.3x the decline finding. It is also the cheaper
-- of the two to act on. That settles the order of the recommendations, and it is
-- the opposite of the order the two findings arrive in when you read the
-- analysis front to back.


\echo '\n== 8. Does the rule need more capacity as e-commerce grows? =='
-- The honest version of "watch e-commerce". The book onboards all year and the
-- card-not-present share climbs from 17.3% to 28.5%, so the question is whether
-- the anti-fraud queue has to grow with it.

WITH base AS (
    SELECT
        date_trunc('quarter', t.txn_ts)::date                    AS quarter,
        t.amount_uzs,
        t.is_disputed,
        te.channel = 'ECOM'                                      AS is_cnp,
        mc.category_name IN ('Betting', 'Online Gaming')
            AND extract(hour FROM t.txn_ts) < 5                  AS in_window
    FROM uzcard.transactions t
    JOIN uzcard.terminals te      ON te.terminal_id = t.terminal_id
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    WHERE t.txn_status = 'approved'
),
days AS (
    SELECT date_trunc('quarter', txn_ts)::date AS quarter,
           count(DISTINCT date_trunc('day', txn_ts)) AS days
    FROM uzcard.transactions GROUP BY 1
)
SELECT
    b.quarter,
    count(*)                                                     AS approved,
    round(100.0 * count(*) FILTER (WHERE b.is_cnp) / count(*), 1) AS ecom_share_pct,
    count(*) FILTER (WHERE b.is_cnp AND b.in_window)             AS rule_d_flagged,
    round(count(*) FILTER (WHERE b.is_cnp AND b.in_window)::numeric / d.days, 1)
                                                                 AS step_ups_per_day,
    round(sum(b.amount_uzs) FILTER (WHERE b.is_disputed) / 1e6, 1) AS disputed_mln
FROM base b
JOIN days d ON d.quarter = b.quarter
GROUP BY b.quarter, d.days
ORDER BY b.quarter;

--  quarter     approved  ecom share  flagged  /day  disputed
--  2023-01-01     4,013       17.3%       80   1.0    24.7 mln
--  2023-04-01     9,915       19.0%       80   1.0    26.6 mln
--  2023-07-01    16,031       21.7%       93   1.1    30.5 mln
--  2023-10-01    26,081       28.5%       88   1.0    31.9 mln
--
-- The answer is no. Approved volume grows 6.5x across the year and the
-- card-not-present share gains 11.2 points, while the rule's load stays at one
-- transaction a day, because the exposure is anchored to five merchants whose
-- own volume is flat. Dispute exposure rises 29% while the book grows 550%.
--
-- So "invest in card-not-present capacity" is the wrong ask. The rule ships at
-- current headcount, and the thing to monitor is not e-commerce volume - it is
-- whether a sixth merchant ever joins the five.
