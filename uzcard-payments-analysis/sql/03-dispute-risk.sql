-- ============================================================================
-- 03 - Disputes: the bank has two risk labels, and only one of them works
-- ============================================================================
-- Disputes are rare (0.33% of transactions) but they are the expensive failure:
-- the money has already moved. This file asks where they concentrate, and then
-- asks whether the bank's own risk labelling would have caught them.
--
-- The denominator throughout is APPROVED transactions. A declined payment never
-- settles, so it can never be disputed - including it would deflate every rate.
--
-- Run:  psql -d portfolio -f sql/03-dispute-risk.sql
-- ============================================================================

\echo '\n== Where disputes concentrate: channel =='

SELECT
    te.channel,
    count(*) FILTER (WHERE t.txn_status = 'approved')           AS approved,
    count(*) FILTER (WHERE t.is_disputed)                       AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
GROUP BY te.channel
ORDER BY dispute_pct DESC;

-- ECOM 1.244% against 0.073% for all card-present channels combined
-- (31 disputes / 42,538 approved): card-not-present is 17x more dispute-prone.


\echo '\n== Where disputes concentrate: merchant category =='

SELECT
    mc.category_name,
    mc.is_high_risk,
    count(*) FILTER (WHERE t.txn_status = 'approved')           AS approved,
    count(*) FILTER (WHERE t.is_disputed)                       AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 2) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
GROUP BY mc.category_name, mc.is_high_risk
HAVING count(*) FILTER (WHERE t.is_disputed) > 0
ORDER BY dispute_pct DESC;

-- Betting 17.74% and Online Gaming 13.94% sit two orders of magnitude above the
-- next category (Grocery, 0.18%). Everything else is background noise.


\echo '\n== Label 1: the MCC high-risk flag =='

WITH by_flag AS (
    SELECT
        mc.is_high_risk,
        count(*) FILTER (WHERE t.txn_status = 'approved') AS approved,
        count(*) FILTER (WHERE t.is_disputed)             AS disputes
    FROM uzcard.transactions t
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    GROUP BY mc.is_high_risk
)
SELECT
    is_high_risk,
    approved,
    disputes,
    round(100.0 * disputes / approved, 3)                        AS dispute_pct,
    round(100.0 * approved / sum(approved) OVER (), 1)           AS pct_of_volume,
    round(100.0 * disputes / sum(disputes) OVER (), 1)           AS pct_of_disputes
FROM by_flag
ORDER BY is_high_risk DESC;

-- High-risk MCCs are 8.2% of approved volume and 81.4% of all disputes: a 49x
-- separation. This label works - but it is broader than it needs to be.


\echo '\n== The MCC flag is over-broad: half of what it flags is clean =='

SELECT
    mc.category_name,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 2) AS dispute_pct
FROM uzcard.mcc_categories mc
LEFT JOIN uzcard.merchants m    ON m.mcc_code = mc.mcc_code
LEFT JOIN uzcard.transactions t ON t.merchant_id = m.merchant_id
WHERE mc.is_high_risk
GROUP BY mc.category_name
ORDER BY disputes DESC;

-- Four categories carry the flag. Two of them - Crypto/FX (2,857 approved,
-- 1 dispute) and Money Transfer (768 approved, 0 disputes) - are clean, and
-- together they are 79% of the flagged volume.
--
-- Dropping them sharpens the target dramatically:
--   flagged as high-risk MCC : 8.2% of volume -> 81.4% of disputes
--   Betting + Online Gaming  : 1.7% of volume -> 80.9% of disputes
--
-- Same coverage of the problem, a fifth of the false positives. Any step-up
-- authentication rule should name the two categories, not the flag.


\echo '\n== Label 2: the merchant risk_tier assigned by the bank =='

SELECT
    m.risk_tier,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.merchants m ON m.merchant_id = t.merchant_id
GROUP BY m.risk_tier
ORDER BY dispute_pct DESC;

-- 0.541% / 0.396% / 0.310% for high / medium / low. Ordered correctly, but the
-- whole range is under a fifth of a point. Next to a 49x separation this is noise.


\echo '\n== The test that matters: does risk_tier add anything ON TOP of the MCC flag? =='
-- A risk label is only useful if it separates merchants that the MCC flag treats
-- the same. So hold the MCC flag constant and look inside each stratum.

SELECT
    mc.is_high_risk                                              AS mcc_high_risk,
    m.risk_tier,
    count(DISTINCT m.merchant_id)                                AS merchants,
    count(*) FILTER (WHERE t.txn_status = 'approved')            AS approved,
    count(*) FILTER (WHERE t.is_disputed)                        AS disputes,
    round(100.0 * count(*) FILTER (WHERE t.is_disputed)
          / nullif(count(*) FILTER (WHERE t.txn_status = 'approved'), 0), 3) AS dispute_pct
FROM uzcard.transactions t
JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
GROUP BY mc.is_high_risk, m.risk_tier
ORDER BY mcc_high_risk DESC,
         CASE m.risk_tier WHEN 'low' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END;

-- Inside high-risk MCCs:   low 6.498%  >  medium 3.607%  >  high 1.526%
-- Inside normal MCCs:      low 0.086%  >  medium 0.046%  >  high 0.027%
--
-- The ordering is BACKWARDS in both strata. Merchants the bank labelled low-risk
-- dispute the most. Inside high-risk MCCs the low-vs-high gap is 4.97 points
-- (z = 7.44, p < 0.001); inside normal MCCs it is 0.06 points and not significant
-- (z = 1.19, p = 0.23).
--
-- Caveat stated plainly: the high-risk MCC stratum contains only 15 merchants
-- (4 low, 4 medium, 7 high). The inversion is statistically significant at the
-- transaction level and consistent in direction across both strata, but it rests
-- on a small merchant count and should be read as "this label is not working"
-- rather than as a precise effect size.


\echo '\n== How concentrated is the exposure? =='
-- If disputes were spread across hundreds of merchants, enforcement would be a
-- policy problem. If they sit on a handful, it is an operational one.

WITH per_merchant AS (
    SELECT
        m.merchant_id,
        m.merchant_name,
        mc.category_name,
        m.risk_tier,
        count(*) FILTER (WHERE t.is_disputed) AS disputes
    FROM uzcard.transactions t
    JOIN uzcard.merchants m       ON m.merchant_id = t.merchant_id
    JOIN uzcard.mcc_categories mc ON mc.mcc_code = m.mcc_code
    GROUP BY m.merchant_id, m.merchant_name, mc.category_name, m.risk_tier
),
ranked AS (
    SELECT
        *,
        sum(disputes) OVER (ORDER BY disputes DESC, merchant_id)  AS running_disputes,
        sum(disputes) OVER ()                                     AS total_disputes,
        row_number() OVER (ORDER BY disputes DESC, merchant_id)   AS rn
    FROM per_merchant
    WHERE disputes > 0
)
SELECT
    rn                                                    AS merchant_rank,
    merchant_name,
    category_name,
    risk_tier                                             AS bank_risk_label,
    disputes,
    round(100.0 * running_disputes / total_disputes, 1)   AS cumulative_pct_of_disputes
FROM ranked
WHERE rn <= 10
ORDER BY rn;

-- Five merchants out of 600 carry 80.9% of every dispute in the book. Four of the
-- five are Betting, one is Online Gaming - and the bank has three of them labelled
-- low or medium risk. Only rank 4 is labelled high.
--
-- This is the whole argument in one table: the exposure is not a category-wide
-- policy problem, it is five named merchants that the bank's own risk labelling
-- failed to flag.
