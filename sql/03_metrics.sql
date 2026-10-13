-- ============================================================
-- 03_metrics.sql
-- Database: qcommerce_v2
-- How to run: select ONE query, then press Ctrl+E, Ctrl+E.
-- All numbers below come from synthetic data (seed = 42).
-- ============================================================


-- ============================================================
-- PART A: THE 4 CORE METRICS
-- ============================================================

-- ------------------------------------------------------------
-- Metric 1: Funnel conversion (7 stages)
-- Counts sessions that reached each stage, then converts to
-- % of the previous stage and % of app_open.
-- The stages have no natural sort order, so CASE numbers them.
-- ------------------------------------------------------------
WITH stage_counts AS (
    SELECT
        stage,
        COUNT(*) AS sessions_reached,
        CASE stage
            WHEN 'app_open'        THEN 1
            WHEN 'browse'          THEN 2
            WHEN 'product_view'    THEN 3
            WHEN 'add_to_cart'     THEN 4
            WHEN 'checkout_start'  THEN 5
            WHEN 'payment_attempt' THEN 6
            WHEN 'order_placed'    THEN 7
        END AS step_order
    FROM session_events
    GROUP BY stage
)
SELECT
    stage,
    sessions_reached,
    ROUND(100.0 * sessions_reached / LAG(sessions_reached) OVER (ORDER BY step_order), 2) AS pct_prev_stage,
    ROUND(100.0 * sessions_reached / FIRST_VALUE(sessions_reached) OVER (ORDER BY step_order), 2) AS pct_app_open
FROM stage_counts
ORDER BY step_order;


-- ------------------------------------------------------------
-- Metric 2: Average order value (AOV)
-- Definition: delivered orders only, because a cancelled order
-- never produced revenue. The median is shown next to the mean
-- because order values are right-skewed (a few big baskets).
-- ------------------------------------------------------------
SELECT
    COUNT(*)                                                                   AS delivered_orders,
    ROUND(AVG(order_amount), 2)                                                AS aov_mean,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY order_amount)::numeric, 2) AS aov_median
FROM orders
WHERE order_status = 'delivered';


-- ------------------------------------------------------------
-- Metric 3: Cancellation rate (all orders in the denominator)
-- CASE turns the status text into 1/0 so SUM can count it.
-- ------------------------------------------------------------
SELECT
    COUNT(*)                                                                      AS total_orders,
    SUM(CASE WHEN order_status = 'cancelled' THEN 1 ELSE 0 END)                   AS cancelled_orders,
    ROUND(100.0 * SUM(CASE WHEN order_status = 'cancelled' THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                                          AS cancellation_rate_pct
FROM orders;


-- ------------------------------------------------------------
-- Metric 4: Delivery time (delivered orders only)
-- Company SLA: delivery within 15 minutes.
-- Median is the headline (delivery times are right-skewed);
-- p90 shows the slow tail; % within SLA is the promise-keeping rate.
-- ------------------------------------------------------------
WITH delivery_times AS (
    SELECT
        EXTRACT(EPOCH FROM (order_delivered_time - order_placed_time)) / 60.0 AS delivery_time_min
    FROM orders
    WHERE order_status = 'delivered'
)
SELECT
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delivery_time_min)::numeric, 2) AS median_delivery_min,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY delivery_time_min)::numeric, 2) AS p90_delivery_min,
    ROUND(100.0 * COUNT(*) FILTER (WHERE delivery_time_min <= 15.0) / COUNT(*), 2)    AS pct_within_15min_sla
FROM delivery_times;


-- ============================================================
-- PART B: SLICING THE METRICS
-- ============================================================

-- B1. Funnel by platform: step-to-step conversion.
-- PARTITION BY platform gives each platform its own funnel,
-- so LAG never compares one platform's stage with another's.
WITH stage_counts AS (
    SELECT s.platform,
           e.stage,
           CASE e.stage
               WHEN 'app_open'        THEN 1
               WHEN 'browse'          THEN 2
               WHEN 'product_view'    THEN 3
               WHEN 'add_to_cart'     THEN 4
               WHEN 'checkout_start'  THEN 5
               WHEN 'payment_attempt' THEN 6
               WHEN 'order_placed'    THEN 7
           END AS step_order,
           COUNT(*) AS sessions_reached
    FROM session_events e
    JOIN sessions s ON s.session_id = e.session_id
    GROUP BY s.platform, e.stage
)
SELECT platform, stage, sessions_reached,
       ROUND(100.0 * sessions_reached
             / LAG(sessions_reached) OVER (PARTITION BY platform ORDER BY step_order), 1) AS pct_prev_stage
FROM stage_counts
ORDER BY platform, step_order;


-- B2. Same funnel split before/after Aug 15, payment steps only.
-- LAG is computed in one CTE and the stage filter is applied afterwards.
-- Window functions run AFTER WHERE, so filtering earlier would remove
-- the rows LAG needs to look back at.
WITH stage_counts AS (
    SELECT s.platform,
           (s.session_start::date >= DATE '2026-08-15') AS after_aug15,
           e.stage,
           CASE e.stage
               WHEN 'app_open'        THEN 1
               WHEN 'browse'          THEN 2
               WHEN 'product_view'    THEN 3
               WHEN 'add_to_cart'     THEN 4
               WHEN 'checkout_start'  THEN 5
               WHEN 'payment_attempt' THEN 6
               WHEN 'order_placed'    THEN 7
           END AS step_order,
           COUNT(*) AS sessions_reached
    FROM session_events e
    JOIN sessions s ON s.session_id = e.session_id
    GROUP BY s.platform, (s.session_start::date >= DATE '2026-08-15'), e.stage
),
with_prev AS (
    SELECT *,
           ROUND(100.0 * sessions_reached
                 / LAG(sessions_reached) OVER (PARTITION BY platform, after_aug15 ORDER BY step_order), 1) AS pct_prev_stage
    FROM stage_counts
)
SELECT platform, after_aug15, stage, sessions_reached, pct_prev_stage
FROM with_prev
WHERE stage IN ('payment_attempt', 'order_placed')
ORDER BY platform, after_aug15, step_order;


-- B3. Company-wide weekly cancellation rate, with week-over-week change.
-- The first and last weeks are partial, so do not read much into them.
WITH weekly AS (
    SELECT date_trunc('week', order_placed_time)::date AS week,
           COUNT(*) AS orders,
           ROUND(100.0 * SUM((order_status = 'cancelled')::int) / COUNT(*), 2) AS cancel_pct
    FROM orders
    GROUP BY 1
)
SELECT week, orders, cancel_pct,
       ROUND(cancel_pct - LAG(cancel_pct) OVER (ORDER BY week), 2) AS change_vs_prev_week
FROM weekly
ORDER BY week;


-- B4. Cancellation rate by store band
SELECT d.store_band,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 2) AS cancel_pct
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
GROUP BY d.store_band
ORDER BY cancel_pct;


-- B5. Cancellation rate by HRA class
SELECT c.hra_class,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 2) AS cancel_pct
FROM orders o
JOIN cities c ON o.city_id = c.city_id
GROUP BY c.hra_class
ORDER BY cancel_pct;


-- B6. Both together: does the HRA gap survive once store band is held fixed?
SELECT d.hra_class, d.store_band,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 2) AS cancel_pct
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
GROUP BY d.hra_class, d.store_band
ORDER BY d.hra_class, d.store_band;


-- ============================================================
-- PART C: MY FINDINGS (write these in your own words)
-- ============================================================
-- B2  Where exactly is the platform problem, and what is the evidence?
--     The problem is isolated specifically to Android checkout/payment completion
--     (from 'payment_attempt' to 'order_placed'), starting on August 15, 2026.
--     Evidence:
--     - Before Aug 15: Android payment conversion was 88.0% (in line with iOS at 88.1% and Web at 89.4%).
--     - After Aug 15: Android payment conversion collapsed by ~19.6 percentage points to 68.4%.
--     - In contrast, iOS (88.9%) and Web (88.8%) stayed completely steady post-Aug 15.
--     - Funnel stages prior to payment (app_open -> checkout_start) on Android remained normal.
--     Conclusion: A client-side bug was introduced in an Android release around Aug 15 impacting
--     payment gateway handoff or confirmation.
--
-- B3  Why would someone who only watches the company-wide weekly
--     cancellation rate miss the Sep 14 spike?
--     Because the company-wide cancellation rate aggregates all 20 cities, heavily diluting
--     a severe localized crisis.
--     Evidence:
--     - On the week of Sep 14, national cancellation rate rose to 11.81% (up from 6.27% the prior week).
--       At a macro level, ~11.8% might look like an acceptable bump or normal seasonal noise.
--     - However, the incident was concentrated in just 3 cities (Hyderabad, Pune, Gurgaon), where
--       the cancellation rate surged to 28.24% (nearly 1 in 3 orders failing, driven by stockouts).
--     - The other 17 unaffected cities represented ~78% of order volume and cancelled at a healthy 7.09%,
--       effectively masking the localized operational failure in the national average.
--
-- B6  What does it say about store band versus HRA class?
--     The apparent difference between HRA city tiers is a confounding effect (Simpson's Paradox);
--     the real operational driver of cancellations is dark store density (store_band).
--     Evidence:
--     - In B5, HRA Class Y looks much worse overall than Class X (9.73% vs 5.53% cancellation rate).
--     - But in B6, when we hold store_band constant, the gap between HRA classes virtually disappears:
--       * Large band: Class X is 4.91% vs Class Y is 5.98%
--       * Mid band:   Class X is 7.13% vs Class Y is 6.55% (Class Y is actually lower!)
--       * Small band: Class X is 9.80% vs Class Y is 11.97% (both are elevated)
--     - The overall HRA gap exists only because 61% of Class Y orders are in 'Small' store networks,
--       compared to only 3% of Class X orders.
--     Conclusion: Customers in Tier 2 cities do not inherently cancel more; under-stored networks
--     suffer higher stockouts and delivery latency regardless of which city class they are in.
-- ============================================================
-- PART C: MY FINDINGS
-- Note: the data is synthetic and the patterns below were planted
-- by my generator (seed 42). This shows how I would detect and
-- explain them, not that I discovered facts about a real company.
-- ============================================================

-- ------------------------------------------------------------
-- B2  Platform problem: where exactly is it, and what is the evidence?
-- ------------------------------------------------------------
-- Finding: payment completion (payment_attempt -> order_placed) on Android
-- fell after Aug 15, 2026. iOS and web did not change.
--
-- Evidence (payment success rate):
--   Before Aug 15: android 88.0%, ios 88.1%, web 89.4%
--   After  Aug 15: android 68.4%, ios 88.9%, web 88.8%
--   Android dropped 19.6 percentage points; the other two stayed flat.
--
-- Estimated impact: after Aug 15 there were 2,034 Android payment attempts
--   and 1,392 became orders. At the earlier 88.0% rate we would expect about
--   1,790, so roughly 398 orders were lost. This is an estimate that assumes
--   Android would have kept converting at its earlier rate.
--
-- Not yet shown: whether the earlier funnel stages (app_open to
--   checkout_start) stayed normal on Android. B2 only displays the payment
--   steps. To check, remove the WHERE stage IN (...) line and compare.
--
-- Hypothesis (not a conclusion): consistent with an Android-specific app
--   release or payment-gateway issue starting around Aug 15. Next steps:
--   check release dates, break results down by app version, and look at
--   gateway error rates and logs.
--
-- Limit: this is a before/after comparison, so it shows a change on
--   Android, not proof of its cause.

-- ------------------------------------------------------------
-- B3  Why does the company-wide weekly rate hide where the spike is?
-- ------------------------------------------------------------
-- Finding: the company-wide number shows that something rose, but it
--   dilutes the size of the problem and cannot say where or why.
--
-- Evidence:
--   Company-wide, week of Sep 14: 11.81% (381 orders), up from 6.27% (383)
--   the week before.
--   In Hyderabad, Pune and Gurgaon that week: 28.24% (24 of 85 orders,
--   more than 1 in 4), against 3-7% in the preceding weeks.
--   The other 17 cities were 77.7% of that week's orders (296 of 381) and
--   cancelled at 7.09%, which pulls the blended number down.
--
-- Why segmenting matters: the blended rate says "cancellations rose".
--   Splitting by city is what shows it is concentrated in 3 cities.
--
-- Cause: 21 of the 24 cancellations (87.5%) in those 3 cities that week
--   were out_of_stock, against 27.6% out_of_stock in the same cities in
--   other weeks. So the spike looks like a supply problem, not customers
--   changing their minds.
--
-- Limit: that is only 24 cancellations, and each of those 3 cities has
--   about 70-90 orders a week, so a single week is noisy. The first and
--   last weeks in the data are partial. The stats stage will test whether
--   the spike is more than noise.

-- ------------------------------------------------------------
-- B6  Store band vs HRA class
-- ------------------------------------------------------------
-- Finding: most of the cancellation gap between HRA classes is explained
--   by store band, so the two are confounded.
--
-- Evidence:
--   Overall (B5): class Y 9.73% vs class X 5.53%, a gap of 4.2 points.
--   Holding store band fixed (B6):
--     Large: X 4.91% vs Y 5.98%  (Y higher by 1.07 points)
--     Mid:   X 7.13% vs Y 6.55%  (Y lower by 0.58 points)
--     Small: X 9.80% vs Y 11.97% (Y higher by 2.17 points)
--   Within bands the gap shrinks from 4.2 points to between -0.6 and +2.2.
--
-- Why: class Y orders are concentrated in small store networks.
--   61.1% of class Y orders are in the Small band (2,380 of 3,895),
--   against 3.3% of class X orders (306 of 9,386).
--
-- Checks:
--   - The Large-band gap is mostly the Sep 14-20 incident. Gurgaon is the
--     only Large-band class Y city, so the incident week hits a bigger share
--     of class Y's Large orders. Excluding that week, the Large gap falls from
--     1.07 to 0.27 points (X 4.76% vs Y 5.03%). Mid: X 7.07% vs Y 6.50%.
--     Small: X 10.07% vs Y 11.99%.
--   - The Small-band gap (about 2 points) rests on only about 300 class X
--     orders. A rough 95% interval for it (normal approximation) runs from
--     about -1.4 to +5.8 points, which includes zero, so it is consistent
--     with noise. To be tested properly in the stats stage.
--
-- Why small networks cancel more: of cancellations in Small-band cities,
--   38.1% were out_of_stock and 36.2% long_wait_time (74.3% combined),
--   against about 60% combined in the Large and Mid bands. The Large figure
--   includes the Sep incident.
--
-- Careful with the wording:
--   - This is confounding: store band is linked to both HRA class and
--     cancellation, so it creates a misleading gap. It is NOT Simpson's
--     paradox, which means the trend reverses inside the groups.
--   - Say "network size" or "store count", not "density": there is no
--     area or population denominator.
--   - Say "HRA class Y", not "Tier 2 customers".
--   - The generator made cancellations depend on store band, not on HRA
--     class, so this finding shows how to detect confounding. It is not a
--     discovery about real customers.


-- ============================================================
-- PART D: SUPPORTING QUERIES
-- These back up the numbers quoted in Part C.
-- Select ONE query at a time and run it with Ctrl+E, Ctrl+E.
-- ============================================================


-- ------------------------------------------------------------
-- S1  (supports B3) Weekly cancellation rate: Hyderabad, Pune and
--     Gurgaon vs the other 17 cities.
-- The CASE creates the two city groups; GROUP BY 1, 2 groups by the
-- first two SELECT columns (week and city_group).
-- Expected, week of Sep 14: incident cities 85 orders, 28.2%;
--                           other 17 cities 296 orders, 7.1%.
-- ------------------------------------------------------------
SELECT date_trunc('week', o.order_placed_time)::date AS week,
       CASE WHEN c.city_name IN ('Hyderabad', 'Pune', 'Gurgaon')
            THEN 'incident cities' ELSE 'other 17' END AS city_group,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 1) AS cancel_pct
FROM orders o
JOIN cities c ON o.city_id = c.city_id
GROUP BY 1, 2
ORDER BY 1, 2;


-- ------------------------------------------------------------
-- S2  (supports B3) Cancellation reasons in Hyderabad/Pune/Gurgaon:
--     week of Sep 14 vs all other weeks.
-- The CTE keeps only cancelled orders in those 3 cities and labels each
-- one by period. The window function turns counts into % within each period.
-- Expected:
--   week of Sep 14: out_of_stock 21 (87.5%), long_wait_time 2 (8.3%),
--                   delivery_partner_issue 1 (4.2%)
--   other weeks:    long_wait_time 45 (33.6%), changed_plans 38 (28.4%),
--                   out_of_stock 37 (27.6%), delivery_partner_issue 14 (10.4%)
-- ------------------------------------------------------------
WITH cancelled_incident AS (
    SELECT CASE WHEN date_trunc('week', o.order_placed_time)::date = DATE '2026-09-14'
                THEN 'week of Sep 14' ELSE 'other weeks' END AS period,
           o.cancellation_reason
    FROM orders o
    JOIN cities c ON o.city_id = c.city_id
    WHERE c.city_name IN ('Hyderabad', 'Pune', 'Gurgaon')
      AND o.order_status = 'cancelled'
)
SELECT period,
       cancellation_reason,
       COUNT(*) AS cancelled,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY period), 1) AS pct_of_period
FROM cancelled_incident
GROUP BY period, cancellation_reason
ORDER BY period, cancelled DESC;


-- ------------------------------------------------------------
-- S3  (supports B6) Share of each HRA class's orders that sit in each
--     store band.
-- COUNT(*) is the orders per class and band; SUM(COUNT(*)) OVER
-- (PARTITION BY hra_class) is the class total, so the division gives the share.
-- Expected: Small band is 61.1% of class Y orders and 3.3% of class X orders.
-- ------------------------------------------------------------
SELECT d.hra_class,
       d.store_band,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY d.hra_class), 1) AS share_pct
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
GROUP BY d.hra_class, d.store_band
ORDER BY d.hra_class, d.store_band;


-- ------------------------------------------------------------
-- S4  (supports B6) Cancellation reasons by store band.
-- The WHERE keeps only cancelled orders, so COUNT(*) is the number of
-- cancellations in each band.
-- Expected, Small band: 315 cancelled, out_of_stock 38.1%, long_wait_time 36.2%.
--           Large band: 406 cancelled, 31.0% and 29.3%.
--           Mid band:   177 cancelled, 27.1% and 32.2%.
-- ------------------------------------------------------------
SELECT d.store_band,
       COUNT(*) AS cancelled,
       COUNT(*) FILTER (WHERE o.cancellation_reason = 'out_of_stock')   AS out_of_stock,
       COUNT(*) FILTER (WHERE o.cancellation_reason = 'long_wait_time') AS long_wait_time,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.cancellation_reason = 'out_of_stock')   / COUNT(*), 1) AS pct_out_of_stock,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.cancellation_reason = 'long_wait_time') / COUNT(*), 1) AS pct_long_wait_time
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
WHERE o.order_status = 'cancelled'
GROUP BY d.store_band
ORDER BY d.store_band;


-- ------------------------------------------------------------
-- S5  (supports B2) Estimated lost Android orders after Aug 15.
-- Step 1 (CTE): for Android only, count payment attempts and orders placed,
--               before and after Aug 15 (two rows).
-- Step 2: self-join those two rows side by side. Expected orders = attempts
--         after Aug 15 x the success rate before Aug 15. Lost = expected - actual.
-- Note: the platform value is lowercase 'android'. Text comparison in
-- Postgres is case-sensitive, so 'Android' would match nothing.
-- Expected: attempts_after 2034, orders_after 1392, baseline_rate_pct 88.0,
--           expected_orders 1790, lost_orders 398.
-- ------------------------------------------------------------
WITH android AS (
    SELECT (s.session_start::date >= DATE '2026-08-15') AS after_aug15,
           COUNT(*) FILTER (WHERE e.stage = 'payment_attempt') AS attempts,
           COUNT(*) FILTER (WHERE e.stage = 'order_placed')    AS orders_placed
    FROM sessions s
    JOIN session_events e ON e.session_id = s.session_id
    WHERE s.platform = 'android'
      AND e.stage IN ('payment_attempt', 'order_placed')
    GROUP BY 1
)
SELECT a_after.attempts      AS attempts_after,
       a_after.orders_placed AS orders_after,
       ROUND(100.0 * a_before.orders_placed / a_before.attempts, 1) AS baseline_rate_pct,
       ROUND(a_after.attempts * a_before.orders_placed::numeric / a_before.attempts) AS expected_orders,
       ROUND(a_after.attempts * a_before.orders_placed::numeric / a_before.attempts
             - a_after.orders_placed) AS lost_orders
FROM android a_after
JOIN android a_before ON a_after.after_aug15 AND NOT a_before.after_aug15;


-- ------------------------------------------------------------
-- S6  (supports B6) The B6 query again (cancellation rate by HRA class
--     and store band), leaving out the incident week of Sep 14.
-- It is B6 with one extra WHERE line.
-- Expected:
--   X Large 6937 orders 4.76%   Y Large 894 orders 5.03%
--   X Mid   1867 orders 7.07%   Y Mid   585 orders 6.50%
--   X Small  298 orders 10.07%  Y Small 2319 orders 11.99%
-- ------------------------------------------------------------
SELECT d.hra_class,
       d.store_band,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 2) AS cancel_pct
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
WHERE date_trunc('week', o.order_placed_time)::date <> DATE '2026-09-14'
GROUP BY d.hra_class, d.store_band
ORDER BY d.hra_class, d.store_band;
