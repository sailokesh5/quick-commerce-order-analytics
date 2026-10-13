# Insights report: three problems in the order data

The data is synthetic and I planted these patterns. This report shows how I would find them, size them, and explain them. The statistical checks behind every claim are in `docs/statistics.md`.

## The business in numbers

| Metric | Value |
|---|---|
| Orders | 13,281 |
| Cancellation rate | 6.76% |
| Average order value (delivered orders) | ₹362.90 |
| Median delivery time (promise: 10 to 15 minutes) | 12.73 minutes |
| Delivered within 15 minutes | 70.89% |
| Sessions that end in an order | 11.47% |

**Why the median:** delivery times have a long slow tail, so the average is pulled up by a few very slow orders. I report the median, and the share delivered within the promise.

**Funnel:** 115,770 sessions open the app, 92,494 browse, 60,061 view a product, 26,043 add to cart, 18,199 start checkout, 15,514 attempt payment and 13,281 place an order. The biggest drop is between product view and add to cart (43.4% continue).

## Finding 1: Android payments broke on Aug 15

- Payment success on Android fell from **88.0%** (6,737 of 7,655 attempts) to **68.4%** (1,392 of 2,034), a drop of 19.6 points.
- iOS stayed at 88% to 89% and web did not change, so this is not a company-wide payment problem.
- Estimated impact: about **398 lost orders**, worth roughly ₹1.4 lakh at the average order value. This is an estimate that assumes Android would have kept its earlier success rate.
- What the data cannot say: why. It fits an Android-specific app release or payment gateway issue starting around Aug 15.

**Recommendation:** check the Android release dated around Aug 15 and the gateway error logs, and fix or roll back. Add a daily alert on payment success by platform, so a drop like this is seen in days, not weeks.

## Finding 2: a one-week cancellation spike in three cities

- In the week of Sep 14, **28.2%** of orders (24 of 85) were cancelled in Hyderabad, Pune and Gurgaon, against **4.7%** in those cities in other weeks. The gap is 23.5 points and far larger than noise.
- **87.5%** of those cancellations (21 of 24) were out of stock, against about 28% in other weeks. This points to a supply problem and not to customers changing their minds.
- About 20 extra orders were cancelled that week.
- Company-wide, the weekly rate only moved from 6.3% to 11.8%, because the other 17 cities were stable. Splitting by city is what shows where it happened.

**Recommendation:** review stock levels and replenishment at the dark stores in these three cities for Sep 14 to 20, and add a stock-out alert per city.

## Finding 3: small store networks cancel more

- Cities with under 40 stores cancel **11.7%** of orders. Cities with 75 or more stores cancel **5.0%**. Mid-sized networks sit at 7.0%.
- In small networks, 38.1% of cancellations are out of stock and 36.2% are long waits, 74% together, against about 60% in the other bands.
- Delivery follows the same pattern. The share delivered within 15 minutes is 77.7% (large), 67.3% (mid) and 52.5% (small).

**Recommendation:** for small-network cities, focus on inventory depth and delivery partner coverage before spending on demand.

## Finding 4: city class is not the real driver

Class Y cities (from the government's HRA classification) cancel more than class X cities (9.7% vs 5.5%). But 61% of class Y orders are in small store networks, against 3% for class X. Once I compare cities with the same network size, the gap is not distinguishable from zero in any band. Network size is the hidden factor behind the gap, so a plan aimed at "smaller cities" would target the wrong thing.

## Caveats

- Synthetic data: the tests recover what I planted.
- The spike week was chosen after looking at the data, so its p-value is optimistic.
- The tests treat orders as independent, though one user can place several orders.
- Order volume per city follows store count, which is an assumption.