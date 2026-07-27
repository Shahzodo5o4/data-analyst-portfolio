-- ============================================================================
-- 02 - Declines: the segment number is hiding the real cause
-- ============================================================================
-- 6.1% of transactions are declined. This file finds who they belong to.
--
-- The first query reproduces the obvious answer ("students decline twice as
-- often"). Every query after it exists because that answer turns out to be a
-- textbook Simpson's paradox: the segment is a bystander, the product is the cause.
--
-- Run:  psql -d portfolio -f sql/02-decline-drivers.sql
-- ============================================================================

\echo '\n== Step 1: the obvious answer - students decline about twice as often =='

SELECT
    cu.customer_segment,
    count(*)                                                    AS txns,
    count(*) FILTER (WHERE t.txn_status = 'declined')           AS declines,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
          / count(*), 2)                                        AS decline_pct,
    rank() OVER (ORDER BY 1.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
                 / count(*) DESC)                               AS rk,
    -- LEAD reads the next segment's rate, which turns the ranking into a measurable
    -- gap rather than just an ordering. The last row is NULL by definition.
    round(100.0 * (1.0 * count(*) FILTER (WHERE t.txn_status = 'declined') / count(*)
          - lead(1.0 * count(*) FILTER (WHERE t.txn_status = 'declined') / count(*))
            OVER (ORDER BY 1.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
                  / count(*) DESC)), 2)                         AS gap_to_next_pts
FROM uzcard.transactions t
JOIN uzcard.cards c      ON c.card_id = t.card_id
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
GROUP BY cu.customer_segment
ORDER BY decline_pct DESC;

-- Students sit at 11.19% against a flat ~5.8% for everyone else: a 5.3 point cliff,
-- while the other three segments are within 0.07 points of each other. Taken alone
-- this says "students are a funding risk". It is the wrong conclusion.


\echo '\n== Step 2: the same picture split by card product tier =='
-- Virtual cards decline at 7.57% overall, which looks like a second, smaller story.
-- It is not a second story. It is the same one.

SELECT
    c.product_tier,
    count(*)                                          AS txns,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
          / count(*), 2)                              AS decline_pct
FROM uzcard.transactions t
JOIN uzcard.cards c ON c.card_id = t.card_id
GROUP BY c.product_tier
ORDER BY decline_pct DESC;


\echo '\n== Step 3: cross the two - the cell that breaks the story open =='

SELECT
    cu.customer_segment,
    c.product_tier,
    count(DISTINCT c.card_id)                         AS cards,
    count(DISTINCT cu.customer_id)                    AS customers,
    count(*)                                          AS txns,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
          / count(*), 2)                              AS decline_pct
FROM uzcard.transactions t
JOIN uzcard.cards c      ON c.card_id = t.card_id
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
GROUP BY cu.customer_segment, c.product_tier
ORDER BY decline_pct DESC;

-- student + virtual  = 20.23%   <- the entire problem lives in one cell
-- student + standard =  5.86%   <- indistinguishable from everyone else
-- student + gold     =  3.60%   <- better than everyone else
-- virtual + mass/payroll/premium = 5.65-5.99%  <- virtual cards are fine otherwise
--
-- Neither "student" nor "virtual" is the cause on its own. Only the combination is.


\echo '\n== Step 4: the decisive comparison - students WITHOUT a virtual card =='
-- If "student" were really the risk factor, removing virtual cards should leave the
-- students still elevated. It does not: the gap disappears entirely.

WITH classified AS (
    SELECT
        t.txn_status,
        cu.customer_segment = 'student' AS is_student,
        c.product_tier = 'virtual'      AS is_virtual
    FROM uzcard.transactions t
    JOIN uzcard.cards c      ON c.card_id = t.card_id
    JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
)
SELECT
    CASE
        WHEN is_student AND is_virtual      THEN '1. student, virtual card'
        WHEN is_student AND NOT is_virtual  THEN '2. student, other card'
        WHEN NOT is_student AND is_virtual  THEN '3. non-student, virtual card'
        ELSE                                     '4. non-student, other card'
    END                                                       AS group_name,
    count(*)                                                  AS txns,
    count(*) FILTER (WHERE txn_status = 'declined')           AS declines,
    round(100.0 * count(*) FILTER (WHERE txn_status = 'declined')
          / count(*), 2)                                      AS decline_pct
FROM classified
GROUP BY group_name
ORDER BY group_name;

-- Groups 2, 3 and 4 land between 5.69% and 5.86%. Group 1 is 20.23%.
-- Student cardholders on a normal card decline at 5.69% against 5.83% for
-- non-student cardholders on a normal card - a gap of -0.14 points, p = 0.80.
-- There is no student effect. There is a student-virtual-card effect.


\echo '\n== Step 5: is it one bad card, or the whole product? =='
-- A 20% rate on 1,122 transactions could be produced by a handful of broken cards.
-- Per-card rates rule that out.

WITH per_card AS (
    SELECT
        c.card_id,
        count(*)                                                     AS txns,
        100.0 * count(*) FILTER (WHERE t.txn_status = 'declined')
            / count(*)                                               AS decline_pct
    FROM uzcard.transactions t
    JOIN uzcard.cards c      ON c.card_id = t.card_id
    JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
    WHERE cu.customer_segment = 'student'
      AND c.product_tier = 'virtual'
    GROUP BY c.card_id
    HAVING count(*) >= 5          -- cards with too few transactions carry no rate
)
SELECT
    count(*)                                                          AS cards,
    round(avg(decline_pct)::numeric, 2)                               AS mean_card_pct,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY decline_pct)::numeric, 2)
                                                                      AS median_card_pct,
    count(*) FILTER (WHERE decline_pct = 0)                           AS never_declined,
    count(*) FILTER (WHERE decline_pct >= 15)                         AS over_15pct
FROM per_card;

-- 127 cards, median 20.0%, and 79 of them above 15%. The behaviour is the product's,
-- not one cardholder's.


\echo '\n== Step 6: rule out the obvious alternative - credit limits =='
-- If student virtual cards were simply configured with tighter limits, that would
-- explain everything and the finding would be trivial. They are not.

SELECT
    cu.customer_segment,
    c.product_tier,
    count(*)                                                    AS cards,
    count(*) FILTER (WHERE c.credit_limit = 0)                  AS zero_limit,
    round(avg(c.credit_limit))                                  AS avg_credit_limit,
    round(100.0 * count(*) FILTER (WHERE c.status <> 'active')
          / count(*), 1)                                        AS non_active_pct
FROM uzcard.cards c
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
WHERE cu.customer_segment = 'student' OR c.product_tier = 'virtual'
GROUP BY cu.customer_segment, c.product_tier
ORDER BY cu.customer_segment, c.product_tier;

-- Student virtual cards average a 1,223,838 UZS limit against 1,265,480 for student
-- standard cards, and a near-identical share of zero-limit (debit) cards. The limit
-- configuration is the same. The outcome is not.


\echo '\n== Step 7: rule out channel - is it just where virtual cards get used? =='

SELECT
    te.channel,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined'
          AND cu.customer_segment = 'student' AND c.product_tier = 'virtual')
          / nullif(count(*) FILTER (WHERE cu.customer_segment = 'student'
          AND c.product_tier = 'virtual'), 0), 2)               AS student_virtual_pct,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined'
          AND NOT (cu.customer_segment = 'student' AND c.product_tier = 'virtual'))
          / nullif(count(*) FILTER (WHERE NOT (cu.customer_segment = 'student'
          AND c.product_tier = 'virtual')), 0), 2)              AS everyone_else_pct,
    count(*) FILTER (WHERE cu.customer_segment = 'student'
          AND c.product_tier = 'virtual')                       AS student_virtual_txns
FROM uzcard.transactions t
JOIN uzcard.cards c      ON c.card_id = t.card_id
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
JOIN uzcard.terminals te ON te.terminal_id = t.terminal_id
GROUP BY te.channel
ORDER BY student_virtual_pct DESC;

-- The gap holds in all five channels. Virtual cards are not concentrated in some
-- riskier channel - their channel mix matches the other tiers almost exactly.


\echo '\n== Step 8: stability across the year =='
-- A one-off spike would suggest an incident. A flat line suggests a standing defect.

SELECT
    date_trunc('quarter', t.txn_ts)::date                       AS quarter,
    count(*) FILTER (WHERE cu.customer_segment = 'student'
          AND c.product_tier = 'virtual')                       AS student_virtual_txns,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined'
          AND cu.customer_segment = 'student' AND c.product_tier = 'virtual')
          / nullif(count(*) FILTER (WHERE cu.customer_segment = 'student'
          AND c.product_tier = 'virtual'), 0), 2)               AS student_virtual_pct,
    round(100.0 * count(*) FILTER (WHERE t.txn_status = 'declined'
          AND NOT (cu.customer_segment = 'student' AND c.product_tier = 'virtual'))
          / nullif(count(*) FILTER (WHERE NOT (cu.customer_segment = 'student'
          AND c.product_tier = 'virtual')), 0), 2)              AS everyone_else_pct
FROM uzcard.transactions t
JOIN uzcard.cards c      ON c.card_id = t.card_id
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
GROUP BY quarter
ORDER BY quarter;

-- 18.9% / 23.2% / 16.9% / 21.3% against a flat 5.8% baseline. Present in every
-- quarter of 2023, so this is how the product behaves, not something that happened.


\echo '\n== Step 9: does it fail differently, or just more often? =='

SELECT
    CASE WHEN cu.customer_segment = 'student' AND c.product_tier = 'virtual'
         THEN 'student virtual' ELSE 'everyone else' END        AS grp,
    t.decline_reason,
    count(*)                                                    AS declines,
    round(100.0 * count(*) / sum(count(*)) OVER (
          PARTITION BY CASE WHEN cu.customer_segment = 'student'
                            AND c.product_tier = 'virtual'
                       THEN 'student virtual' ELSE 'everyone else' END), 1) AS pct_of_group
FROM uzcard.transactions t
JOIN uzcard.cards c      ON c.card_id = t.card_id
JOIN uzcard.customers cu ON cu.customer_id = c.customer_id
WHERE t.txn_status = 'declined'
GROUP BY grp, t.decline_reason
ORDER BY grp, declines DESC;

-- The reason mix is broadly the same shape - funding reasons dominate in both
-- (69.6% vs 75.5%). Student virtual cards do not fail for exotic reasons; they hit
-- the same wall three and a half times as often.
