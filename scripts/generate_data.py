import numpy as np
from datetime import date, datetime, timedelta
import psycopg2
from psycopg2.extras import execute_values
from db_config import DB_CONFIG

# ---------- settings (every number here is an assumption, not sourced data) ----------
SEED = 42
rng = np.random.default_rng(SEED)           # same seed = same data every run
TODAY = date(2026, 10, 1)                   # fixed cutoff date, so reruns are identical
NUM_USERS = 4000

CHANNELS = ['organic', 'referral', 'paid_ad', 'social']
CHANNEL_P = [0.45, 0.20, 0.25, 0.10]
PLATFORMS = ['android', 'ios', 'web']
PLATFORM_P = [0.62, 0.30, 0.08]
TRAVEL_RATE = 0.04                          # share of sessions made from a non-home city

# how session activity behaves over a user's lifetime
R0, TAU, FLOOR = 0.30, 90.0, 0.25           # base rate, fade speed (days), long-run floor
WEEKDAY_W = [0.9, 0.9, 0.9, 0.95, 1.1, 1.3, 1.25]   # Mon..Sun
HOUR_W = np.array([1, 0.5, 0.3, 0.2, 0.2, 0.5, 1.5, 3, 4, 3.5, 3, 3.5,
                   4, 3.5, 3, 3, 3.5, 4.5, 6, 7.5, 8, 7, 5, 2.5], dtype=float)
HOUR_P = HOUR_W / HOUR_W.sum()

# funnel: chance of moving to this stage, given the previous stage was reached
STAGES = ['app_open', 'browse', 'product_view', 'add_to_cart',
          'checkout_start', 'payment_attempt', 'order_placed']
BASE_P = {'browse': 0.80, 'product_view': 0.65, 'add_to_cart': 0.45,
          'checkout_start': 0.70, 'payment_attempt': 0.85, 'order_placed': 0.88}
GAP_SECONDS = {'browse': (15, 90), 'product_view': (20, 150), 'add_to_cart': (15, 120),
               'checkout_start': (10, 60), 'payment_attempt': (15, 90), 'order_placed': (5, 30)}
CHANNEL_CART = {'organic': 1.00, 'referral': 1.15, 'paid_ad': 0.90, 'social': 0.85}
BAND_CART = {'Large': 1.00, 'Mid': 0.97, 'Small': 0.92}

# planted patterns (disclosed in the README)
ANDROID_BUG_DATE = date(2026, 8, 15)                   # android payment success drops after this
INCIDENT_START, INCIDENT_END = date(2026, 9, 14), date(2026, 9, 20)   # Mon-Sun
INCIDENT_CITY_NAMES = ("Hyderabad", "Pune", "Gurgaon")

# orders
CANCEL_BASE = {'Large': 0.04, 'Mid': 0.07, 'Small': 0.11}
DELIVERY_MEDIAN_MIN = {'Large': 11.5, 'Mid': 12.5, 'Small': 14.0}
REASONS = ['out_of_stock', 'long_wait_time', 'changed_plans', 'delivery_partner_issue']
AOV_MEDIAN = 320

# ---------- connect, with a safety check ----------
conn = psycopg2.connect(**DB_CONFIG)
cur = conn.cursor()
cur.execute("SELECT current_database();")
assert cur.fetchone()[0] == "qcommerce_v2", "Wrong database! Expected qcommerce_v2"
cur.execute("TRUNCATE session_events, orders, sessions, users RESTART IDENTITY;")

# ---------- cities (read from the database, not hardcoded) ----------
cur.execute("SELECT city_id, city_name, store_count, store_band FROM city_dim ORDER BY city_id;")
cities = cur.fetchall()
city_ids = np.array([c[0] for c in cities])
city_p = np.array([c[2] for c in cities], dtype=float)
city_p = city_p / city_p.sum()                           # more stores = more users
name_of = {c[0]: c[1] for c in cities}
band_of = {c[0]: c[3] for c in cities}
INCIDENT_CITY_IDS = {cid for cid, nm in name_of.items() if nm in INCIDENT_CITY_NAMES}

# ---------- users ----------
d1 = rng.integers(0, 541, NUM_USERS)
d2 = rng.integers(0, 541, NUM_USERS)
days_ago = np.minimum(d1, d2)                            # recency skew: more recent signups
home = rng.choice(city_ids, size=NUM_USERS, p=city_p)
chan = rng.choice(CHANNELS, size=NUM_USERS, p=CHANNEL_P)
users_data = [(TODAY - timedelta(days=int(d)), int(h), str(c))
              for d, h, c in zip(days_ago, home, chan)]
execute_values(cur, "INSERT INTO users (signup_date, home_city_id, signup_channel) VALUES %s",
               users_data)
conn.commit()
cur.execute("SELECT user_id, signup_date, home_city_id, signup_channel FROM users ORDER BY user_id;")
users = cur.fetchall()
print("Inserted", len(users), "users.")

# ---------- planning sessions ----------
def draw_offset(T, flat, decay):
    """Pick a day (after signup) from an activity curve that fades but never hits zero."""
    if rng.random() < flat / (flat + decay):
        return float(rng.uniform(0, T))
    u = rng.random()
    return float(-TAU * np.log(1 - u * (1 - np.exp(-T / TAU))))

def plan_sessions(user_id, signup_date, home_city_id, channel):
    T = (TODAY - signup_date).days
    pref = str(rng.choice(PLATFORMS, p=PLATFORM_P))
    propensity = float(rng.lognormal(-0.405, 0.9))       # a few users are very active
    flat = FLOOR * T
    decay = (1 - FLOOR) * TAU * (1 - np.exp(-T / TAU))
    n_extra = int(rng.poisson(R0 * propensity * (flat + decay))) if T > 0 else 0
    plans = []
    for i in range(n_extra + 1):
        if i == 0:
            day = 0                                       # first session = signup day
        else:
            while True:                                   # weekend-heavy days
                day = min(int(draw_offset(T, flat, decay)), T)
                d = signup_date + timedelta(days=day)
                if rng.random() <= WEEKDAY_W[d.weekday()] / max(WEEKDAY_W):
                    break
        d = signup_date + timedelta(days=day)
        hour = int(rng.choice(24, p=HOUR_P))
        start = datetime.combine(d, datetime.min.time()) + timedelta(
            hours=hour, minutes=int(rng.integers(0, 60)), seconds=int(rng.integers(0, 60)))
        city_id = int(rng.choice(city_ids, p=city_p)) if rng.random() < TRAVEL_RATE else home_city_id
        platform = pref if rng.random() < 0.9 else str(rng.choice(PLATFORMS, p=PLATFORM_P))
        plans.append((start, user_id, city_id, platform, channel))
    return plans

all_plans = []
for user_id, signup_date, home_city_id, channel in users:
    all_plans.extend(plan_sessions(user_id, signup_date, home_city_id, channel))
all_plans.sort(key=lambda p: p[0])                        # session_ids follow time order

# ---------- funnel and orders ----------
def stage_prob(stage, channel, band, platform, session_date):
    p = BASE_P[stage]
    if stage == 'add_to_cart':
        p *= CHANNEL_CART[channel] * BAND_CART[band]
    if stage == 'order_placed' and platform == 'android' and session_date >= ANDROID_BUG_DATE:
        p = 0.70                                          # planted: android payment problem
    return min(p, 0.99)

def make_order(sid, user_id, city_id, placed):
    band = band_of[city_id]
    peak = 19 <= placed.hour <= 22
    p_cancel = CANCEL_BASE[band] + (0.02 if peak else 0.0)
    incident = (INCIDENT_START <= placed.date() <= INCIDENT_END) and city_id in INCIDENT_CITY_IDS
    if incident:
        p_cancel += 0.22                                  # planted: one-week supply problem
    amount = round(float(np.clip(rng.lognormal(np.log(AOV_MEDIAN), 0.5), 49, 2500)), 2)
    if rng.random() < p_cancel:
        if incident:
            w = [0.85, 0.06, 0.05, 0.04]
        elif band == 'Small':
            w = [0.38, 0.34, 0.18, 0.10]
        else:
            w = [0.30, 0.30, 0.25, 0.15]
        reason = str(rng.choice(REASONS, p=w))
        return (sid, user_id, city_id, placed, None, amount, 'cancelled', reason)
    median = DELIVERY_MEDIAN_MIN[band] * (1.15 if peak else 1.0)
    minutes = float(np.clip(rng.lognormal(np.log(median), 0.28), 6, 60))
    delivered = placed + timedelta(seconds=int(minutes * 60))
    return (sid, user_id, city_id, placed, delivered, amount, 'delivered', None)

sessions_rows, events_rows, orders_rows = [], [], []
for sid, (start, user_id, city_id, platform, channel) in enumerate(all_plans, start=1):
    sessions_rows.append((sid, user_id, city_id, start, platform))
    band = band_of[city_id]
    t = start
    events_rows.append((sid, 'app_open', t))
    placed = False
    for stage in STAGES[1:]:
        if rng.random() >= stage_prob(stage, channel, band, platform, start.date()):
            break                                         # user dropped off here
        lo, hi = GAP_SECONDS[stage]
        t = t + timedelta(seconds=int(rng.integers(lo, hi + 1)))
        events_rows.append((sid, stage, t))
        if stage == 'order_placed':
            placed = True
    if placed:
        orders_rows.append(make_order(sid, user_id, city_id, t))

# ---------- insert ----------
execute_values(cur, "INSERT INTO sessions (session_id, user_id, city_id, session_start, platform) VALUES %s",
               sessions_rows, page_size=10000)
cur.execute("SELECT setval(pg_get_serial_sequence('sessions','session_id'), (SELECT MAX(session_id) FROM sessions));")
execute_values(cur, "INSERT INTO session_events (session_id, stage, event_time) VALUES %s",
               events_rows, page_size=10000)
execute_values(cur, """INSERT INTO orders (session_id, user_id, city_id, order_placed_time,
                       order_delivered_time, order_amount, order_status, cancellation_reason)
                       VALUES %s""", orders_rows, page_size=10000)
conn.commit()
print("Inserted", len(sessions_rows), "sessions,", len(events_rows), "events,", len(orders_rows), "orders.")

cur.close()
conn.close()