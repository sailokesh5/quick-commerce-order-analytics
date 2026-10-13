"""
Statistical checks on the planted patterns.
Run from the project root:  python scripts/stats_tests.py
Reads counts from qcommerce_v2 and tests whether differences between two
rates are bigger than random noise would produce.
"""
import math
import psycopg2
from scipy.stats import norm, fisher_exact
from db_config import DB_CONFIG

conn = psycopg2.connect(**DB_CONFIG)
cur = conn.cursor()
cur.execute("SELECT current_database();")
assert cur.fetchone()[0] == "qcommerce_v2", "Wrong database! Expected qcommerce_v2"


def counts(sql):
    """Run a query that returns one row: (events x, total n)."""
    cur.execute(sql)
    x, n = cur.fetchone()
    return int(x), int(n)


def compare(label_a, a, label_b, b):
    """Two-proportion z-test plus a 95% confidence interval for the difference."""
    x1, n1 = a
    x2, n2 = b
    p1, p2 = x1 / n1, x2 / n2
    diff = p1 - p2
    p_pool = (x1 + x2) / (n1 + n2)
    se_test = math.sqrt(p_pool * (1 - p_pool) * (1 / n1 + 1 / n2))   # assumes no real difference
    z = diff / se_test
    p_value = 2 * norm.sf(abs(z))          # sf = 1 - cdf, but accurate for tiny values
    se_ci = math.sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)       # used for the interval
    lo, hi = diff - 1.96 * se_ci, diff + 1.96 * se_ci
    print(f"  {label_a}: {x1}/{n1} = {100*p1:.2f}%")
    print(f"  {label_b}: {x2}/{n2} = {100*p2:.2f}%")
    print(f"  difference (A - B): {100*diff:+.2f} points, 95% CI [{100*lo:+.2f}, {100*hi:+.2f}]")
    p_text = "< 0.0001" if p_value < 1e-4 else f"{p_value:.4f}"
    print(f"  z = {z:.2f}, p-value = {p_text}", end="")
    if min(x1, n1 - x1, x2, n2 - x2) < 10:   # small cell counts: also run an exact test
        _, p_exact = fisher_exact([[x1, n1 - x1], [x2, n2 - x2]])
        print(f"   (Fisher exact p = {p_exact:.4f})", end="")
    print()
    print("  Conclusion:", "CI excludes 0, difference unlikely to be noise" if (lo > 0 or hi < 0)
          else "CI includes 0, cannot rule out noise")
    print()


CANCEL = "SUM((o.order_status = 'cancelled')::int), COUNT(*)"
THREE = "c.city_name IN ('Hyderabad', 'Pune', 'Gurgaon')"
SPIKE_WEEK = "date_trunc('week', o.order_placed_time)::date = DATE '2026-09-14'"

print("=== 1. Sep 14 spike: Hyderabad/Pune/Gurgaon, spike week vs their other weeks ===")
compare("spike week", counts(f"SELECT {CANCEL} FROM orders o JOIN cities c ON o.city_id=c.city_id WHERE {THREE} AND {SPIKE_WEEK}"),
        "other weeks", counts(f"SELECT {CANCEL} FROM orders o JOIN cities c ON o.city_id=c.city_id WHERE {THREE} AND NOT ({SPIKE_WEEK})"))

PAY = lambda platform, after: f"""
    SELECT COUNT(*) FILTER (WHERE e.stage = 'order_placed'),
           COUNT(*) FILTER (WHERE e.stage = 'payment_attempt')
    FROM sessions s JOIN session_events e ON e.session_id = s.session_id
    WHERE s.platform = '{platform}' AND e.stage IN ('payment_attempt', 'order_placed')
      AND (s.session_start::date >= DATE '2026-08-15') = {after}"""

print("=== 2a. Android payment success: after Aug 15 vs before ===")
compare("android after", counts(PAY("android", "true")), "android before", counts(PAY("android", "false")))
print("=== 2b. Control, iOS payment success: after Aug 15 vs before ===")
compare("ios after", counts(PAY("ios", "true")), "ios before", counts(PAY("ios", "false")))

BAND = lambda band: f"SELECT {CANCEL} FROM orders o JOIN city_dim d ON o.city_id=d.city_id WHERE d.store_band = '{band}'"
print("=== 3. Cancellation rate: Small-network vs Large-network cities ===")
compare("Small band", counts(BAND("Small")), "Large band", counts(BAND("Large")))

CLS = lambda cl, extra="": f"SELECT {CANCEL} FROM orders o JOIN city_dim d ON o.city_id=d.city_id WHERE d.hra_class = '{cl}' {extra}"
print("=== 4a. Cancellation rate: HRA class Y vs X, all orders ===")
compare("class Y", counts(CLS("Y")), "class X", counts(CLS("X")))
for band in ("Large", "Mid", "Small"):
    print(f"=== 4b. Class Y vs X, {band} band only ===")
    extra = f"AND d.store_band = '{band}'"
    compare("class Y", counts(CLS("Y", extra)), "class X", counts(CLS("X", extra)))

cur.close()
conn.close()