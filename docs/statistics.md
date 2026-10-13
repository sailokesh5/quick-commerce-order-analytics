# Statistical checks on the patterns in the data

## What I tested and why

The data in this project is made up (synthetic). I put some patterns into it on purpose. So these tests do not discover facts about a real company. They show how I would check whether a pattern is real.

Every test asks one question: **is the difference between two rates big enough that it is probably not luck?**

I used two tools:
- **p-value:** how likely it is to see a difference this big if the two groups were really the same. A small p-value (below 0.05) means the difference is probably not luck.
- **95% confidence interval:** a range where the true difference probably lies. If the range does not include 0, the difference is probably real. The range also shows how big the difference could be.

The test is a two-proportion z-test. The code is in `scripts/stats_tests.py`. All gaps below are in percentage points.

## Results

### 1. The cancellation spike in the week of Sep 14 (Hyderabad, Pune, Gurgaon)

| | Cancelled / orders | Rate |
|---|---|---|
| Week of Sep 14 | 24 / 85 | 28.24% |
| Same cities, other weeks | 134 / 2,843 | 4.71% |

Gap: +23.52 points. 95% CI: [+13.92, +33.12]. p < 0.0001.

In that week, more than 1 in 4 orders were cancelled in these three cities. In their other weeks it was about 1 in 21. The gap is too big to be luck. Even the low end of the range is almost 14 points.

**Caution:** I picked this week after I saw it was the worst one. That makes the p-value look better than it should.

### 2. Store network size (Small vs Large cities)

| | Cancelled / orders | Rate |
|---|---|---|
| Small band | 315 / 2,686 | 11.73% |
| Large band | 406 / 8,064 | 5.03% |

Gap: +6.69 points. 95% CI: [+5.39, +8.00]. p < 0.0001.

Cities with small store networks cancel about 2.3 times as often as cities with large networks. The range is narrow and far from zero, so the gap is real in this data. I built this gap into the data on purpose, so this test confirms the data behaves as designed.

### 3. Android payment success after Aug 15

| | Orders / payment attempts | Success rate |
|---|---|---|
| Android before Aug 15 | 6,737 / 7,655 | 88.01% |
| Android after Aug 15 | 1,392 / 2,034 | 68.44% |
| iOS before Aug 15 (control) | 3,246 / 3,686 | 88.06% |
| iOS after Aug 15 (control) | 882 / 992 | 88.91% |

Android: −19.57 points. 95% CI: [−21.72, −17.42]. p < 0.0001.
iOS: +0.85 points. 95% CI: [−1.37, +3.07]. p = 0.46.

Android payment success fell by about 20 points. The range is narrow and far from zero, so this is not luck.

I also tested iOS over the same dates as a **control group**. Its range includes zero, so nothing changed there. This points to a problem on Android, and not to something that hit the whole company. The data cannot say what caused it.

### 4. HRA class Y vs class X, overall and inside each store band

| Group | Class Y | Class X | Gap (Y − X) | 95% CI | p |
|---|---|---|---|---|---|
| All orders | 9.73% (379/3,895) | 5.53% (519/9,386) | +4.20 | [+3.16, +5.24] | < 0.0001 |
| Large band | 5.98% (55/920) | 4.91% (351/7,144) | +1.07 | [−0.55, +2.68] | 0.16 |
| Mid band | 6.55% (39/595) | 7.13% (138/1,936) | −0.57 | [−2.87, +1.72] | 0.63 |
| Small band | 11.97% (285/2,380) | 9.80% (30/306) | +2.17 | [−1.41, +5.75] | 0.27 |

Overall, class Y cities look worse by about 4 points, and that gap is statistically significant. But when I compare cities with the same store band, the gap mostly disappears. All three ranges include zero.

This suggests the overall gap comes from store band, not from HRA class. Class Y cities are mostly small networks (61% of their orders are in the Small band), and small networks cancel more. When a hidden factor creates a misleading gap like this, it is called **confounding**.

**Caution:** the class X group in the Small band has only 306 orders, so that comparison is weak. "The range includes zero" means "I cannot rule out luck". It does not mean "there is no difference".

## Limitations

- The data is synthetic and I planted every pattern. The tests find what I put in.
- I chose the spike week after looking at the data. That makes its p-value too optimistic.
- The tests treat every order as independent, but one user can place many orders. The real uncertainty is a bit bigger than the ranges show.
- I ran about eight tests. When you run many tests, some can look significant by luck. Here the big effects are very clear, so this does not change the conclusions.
- Significant does not mean important. The overall class gap was significant, but it turned out to be mostly about store band, not class.