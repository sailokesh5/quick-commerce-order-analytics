-- ============================================================
-- 02_data_checks.sql
-- Purpose: confirm the generated data behaves as designed.
-- Select ONE query, then run it with Ctrl+E, Ctrl+E.
-- ============================================================

-- A. Funnel: sessions reaching each stage
SELECT stage, COUNT(*) AS sessions_reaching_stage
FROM session_events
GROUP BY stage
ORDER BY sessions_reaching_stage DESC;

-- B. Cancellation rate by store band
SELECT d.store_band,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 1) AS cancel_pct
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
GROUP BY d.store_band
ORDER BY cancel_pct;

-- C. On-time delivery (within the 15-minute SLA) by store band
SELECT d.store_band,
       COUNT(*) FILTER (WHERE o.order_status = 'delivered') AS delivered,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_delivered_time - o.order_placed_time <= INTERVAL '15 minutes')
             / COUNT(*) FILTER (WHERE o.order_status = 'delivered'), 1) AS pct_within_15min
FROM orders o
JOIN city_dim d ON o.city_id = d.city_id
GROUP BY d.store_band
ORDER BY pct_within_15min;

-- D. Weekly cancellation rate in the three incident cities
SELECT date_trunc('week', o.order_placed_time)::date AS week,
       COUNT(*) AS orders,
       ROUND(100.0 * SUM((o.order_status = 'cancelled')::int) / COUNT(*), 1) AS cancel_pct
FROM orders o
JOIN cities c ON o.city_id = c.city_id
WHERE c.city_name IN ('Hyderabad', 'Pune', 'Gurgaon')
  AND o.order_placed_time >= '2026-08-24'
GROUP BY 1
ORDER BY 1;

-- E. Payment success by platform, before and after Aug 15
SELECT s.platform,
       (s.session_start::date >= '2026-08-15') AS after_aug15,
       COUNT(*) FILTER (WHERE e.stage = 'payment_attempt') AS attempts,
       ROUND(100.0 * COUNT(*) FILTER (WHERE e.stage = 'order_placed')
             / NULLIF(COUNT(*) FILTER (WHERE e.stage = 'payment_attempt'), 0), 1) AS pay_success_pct
FROM sessions s
JOIN session_events e ON e.session_id = s.session_id
WHERE e.stage IN ('payment_attempt', 'order_placed')
GROUP BY 1, 2
ORDER BY 1, 2;

-- ============================================================
-- INTEGRITY CHECKS: I write these myself. Each should return 0 rows (or 0).
-- ============================================================
-- 1. TODO: delivered orders where delivered time is NOT after placed time
SELECT *
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_time <= order_placed_time;
-- 2. TODO: sessions that start before the user's signup date
SELECT *
FROM sessions
JOIN users u ON sessions.user_id = u.user_id
WHERE sessions.session_start < u.signup_date;
-- 3. TODO: orders whose city differs from their session's city
SELECT *
FROM orders o
JOIN sessions s ON o.session_id = s.session_id
WHERE o.city_id <> s.city_id;
-- 4. TODO: orders whose session has no 'order_placed' event
SELECT o.order_id
FROM orders o
LEFT JOIN session_events e
       ON e.session_id = o.session_id
      AND e.stage = 'order_placed'
WHERE e.event_id IS NULL;
-- 5. TODO: users who have no sessions at all
SELECT u.*
FROM users u
LEFT JOIN sessions s ON u.user_id = s.user_id
WHERE s.session_id IS NULL;