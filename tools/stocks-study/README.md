# How wide the stock ranges are, checked on 19,726 stocks

`jk stocks` gives a range for the next close: the last close moved **1.28 typical days** either
way, where a typical day is the spread (standard deviation) of the last 20 daily changes. A
bell curve says that holds 4 days in 5. This folder checks it on real prices, every day judged
only by the 20 days before it.

## The data

- Two years of daily closes from Yahoo Finance (`collect.py`). It took 20 symbols at a time and
  waited 1 second between requests, with 4 requests running at once.
- **45,593 symbols** were asked for:
  - every US-listed one in Nasdaq's symbol directory (`nasdaqlisted.txt` and `otherlisted.txt`, test issues left out);
  - every code in the Shanghai (600000-605999, 688000-689999), Shenzhen (000001-003999, 300001-301999), Hong Kong (0001-9999) and Tokyo (1300-9999) ranges.
- **24,037** of those had prices.
- `study.py` then left out:
  - series shorter than 200 days;
  - thinly traded ones, where more than 15% of days did not move;
  - any with a one-day move over 100% in log terms (an unadjusted split or a bad print).
- **19,726 series** were left, **8,148,955 stock-days** in all.

```
python -I collect.py <empty data folder>      # about an hour; resumes where it stopped
python -I study.py <data folder>\closes.jsonl
```

## What it found (closes to Nov 25, 2026)

Each typical day is judged by the 20 days before it; held = the close landed inside.

| range | held, all 8,148,955 stock-days | stocks within 5 points of the aim |
|---|---|---|
| 1 typical day (the old jk range, "2 in 3") | 71.25% | - |
| **1.28 typical days (4 in 5)** | **80.62%** | **98.4%** |
| 1.96 (the bell curve's 19 in 20) | 92.27% | - |
| **2.3 typical days (19 in 20)** | **94.97%** | - |

The 1.28 range held 80.4% in the US, 80.5% in Shanghai, 80.7% in Shenzhen, 81.1% in Hong
Kong and 81.0% in Tokyo. By year, it held 81.7% in the first year and 79.6% in the second.

Measured on the second year only, with nothing fitted to it:

| typical day from | 1.28 (bell curve) | fitted on year one | each stock's own past |
|---|---|---|---|
| **last 20 days** | **79.6%, 94.5% of stocks in 75-85%** | 77.7%, 84.2% | 78.0%, 91.4% |
| last 60 days | 81.1%, 83.5% | 75.8%, 53.1% | 76.6%, 66.9% |
| EWMA 0.94 | 81.2%, 88.5% | 76.3%, 61.6% | 77.0%, 76.9% |
| EWMA 0.97 | 81.9%, 79.6% | 75.0%, 44.7% | 76.0%, 58.4% |
| 20 and 60 mixed | 81.5%, 84.5% | 75.8%, 54.2% | 76.6%, 69.1% |

A week out, over 1,616,340 stock-weeks:

- The 1.28 spread times the square root of 5 held 80.27%.
- 80% of weeks fell within 1.27 typical weeks, and 95% within 2.32.

The direction of the next day, on the second year:

| rule | right |
|---|---|
| above its 20-day average means up | 50.3% of 4.5 million days |
| up yesterday means up today | 48.2% |
| after a move over 2 typical days, the other way | 55.0% of 289,652 days |

## What that means for jk

- **The 4-in-5 range: 1.28 typical days.** The bell curve's number is right on average.
  - It held 80.62% of all stock-days.
  - On 98.4% of stocks, it held between 75% and 85% of days.
  - Every market came out within a point of 80%: 80.4% to 81.1%.
- **The 19-in-20 range: 2.3, not the bell curve's 1.96.**
  - 1.96 held only 92.3%, because big days are more common than a bell curve allows.
  - On the data, 95% of days fell within 2.30 typical days.
- **A week out: the 4-in-5 spread times the square root of 5.** It held 80.3% of 1.6 million weeks.
- **Other ways to measure a typical day did not do better.** The study tried:
  - 60 days instead of 20;
  - weighted averages (EWMA 0.94 and 0.97);
  - a mix of the two;
  - fitting the multiple to the first year;
  - fitting it to each stock's own past.

  They either missed 80% further in the second year or left fewer stocks near 80%. The plain
  20-day spread with 1.28 was the best fit.
- **Which way a day goes is a coin flip.** None of the simple rules tested came near 80%:
  "above its average" was right 50.3% of days and "up yesterday" 48.2%. The best rule, a big move then a turn the other way, was right 55.0% of days, and it only applies on 1 day in 15.

  That is why `jk stocks` shows the trend's record next to a coin and never calls a direction.

From past prices only, not advice.
