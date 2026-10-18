#!/usr/bin/env python3
"""
Offline tests for wetbulb.star.

- Swaps fetch_forecast / fetch_obs for fixtures and renders each scenario
  with the real app code (no network needed).
- Checks the Starlark wet bulb math against the Backyard Snowstorm chart.

Usage: PIXLET=/path/to/pixlet python3 tests/run_tests.py
Renders land in tests/out/.
"""
import csv
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "wetbulb.star")
OUT = os.path.join(HERE, "out")
PIXLET = os.environ.get("PIXLET", "pixlet")


def c(f):
    return (f - 32) * 5 / 9


def esw(t):
    return 6.112 * math.exp(17.62 * t / (243.12 + t))


def wb_c(t, td, p=1013.25):
    if td >= t:
        return t
    e, lo, hi = esw(td), td, t
    for _ in range(60):
        tw = (lo + hi) / 2
        f = esw(tw) - 6.53e-4 * (1 + 0.000944 * tw) * p * (t - tw) - e
        lo, hi = (lo, tw) if f > 0 else (tw, hi)
    return (lo + hi) / 2


def td_for_wb(target_f, spread_f=4.0):
    """Air temp = target + spread; solve dewpoint so wet bulb == target."""
    t = c(target_f + spread_f)
    target = c(target_f)
    lo, hi = t - 30, t
    for _ in range(60):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if wb_c(t, mid) < target else (lo, mid)
    return round(t, 3), round((lo + hi) / 2, 3)


def forecast_literal(start_hour, wb_series_f, current_wb_f=None):
    times, ts, tds = [], [], []
    for i, w in enumerate(wb_series_f):
        h = (start_hour + i) % 24
        times.append('"2026-12-15T%02d:00"' % h)
        t, td = td_for_wb(w)
        ts.append(str(t))
        tds.append(str(td))
    cw = current_wb_f if current_wb_f is not None else wb_series_f[0]
    ct, ctd = td_for_wb(cw)
    n = len(wb_series_f)
    return (
        "{"
        '"times": [%s], "t": [%s], "td": [%s], "p": [%s], "om_wb": [%s],'
        '"current": {"t": %s, "td": %s, "p": 1013.0}'
        "}"
        % (
            ",".join(times),
            ",".join(ts),
            ",".join(tds),
            ",".join(["1013.0"] * n),
            ",".join(ts),
            ct,
            ctd,
        )
    )


def obs_literal(wb_f, age_min):
    if wb_f is None:
        return "None"
    t, td = td_for_wb(wb_f)
    return '{"t": %s, "td": %s, "age_min": %s}' % (t, td, age_min)


def app_source(rename_main=False):
    src = open(APP).read()
    if rename_main:
        src = re.sub(r"^def main\(", "def _app_main(", src, flags=re.M)
    src = re.sub(r"^def fetch_forecast\(", "def _real_fetch_forecast(", src, flags=re.M)
    src = re.sub(r"^def fetch_obs\(", "def _real_fetch_obs(", src, flags=re.M)
    return src


def run(name, extra, config=(), rename_main=False):
    d = os.path.join(OUT, "_src", name)  # pixlet loads every .star in a folder
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name + ".star")
    open(path, "w").write(app_source(rename_main) + "\n# ---- test fixtures ----\n" + extra)
    gif = os.path.join(OUT, name + ".gif")
    if os.path.exists(gif):
        os.remove(gif)
    r = subprocess.run(
        [PIXLET, "render", path, "--gif", "-o", gif] + list(config),
        capture_output=True,
        text=True,
    )
    # pixlet writes a 0-byte file when main returns [] - treat as "no frame"
    return r, os.path.exists(gif) and os.path.getsize(gif) > 0


SCENARIOS = [
    # name, start hour, now(obs) wb, 13 hourly wb values (index 0 = current hour), obs age, expect
    ("falling", 17, 31, [31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 22, 21, 22], 20, "GO 9P-6A LO21"),
    ("rising", 4, 21, [21, 21, 20, 21, 22, 23, 25, 27, 28, 30, 31, 33, 34], 20, "GO NOW-12P LO20"),
    ("nogo", 13, 33, [33, 33, 33, 33, 32, 32, 31, 31, 30, 30, 29, 29, 30], 20, "NO WINDOW 12H"),
    ("great", 2, 16, [16, 15, 15, 14, 14, 14, 15, 17, 19, 21, 24, 27, 29], 20, "GO NOW-2P LO14"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    failures = 0

    # 1. Chart check via the Starlark implementation
    rows = list(csv.reader(open(os.path.join(HERE, "chart.csv"))))
    rh = [int(x) for x in rows[0][1:]]
    cells = []
    for row in rows[1:]:
        tf = int(row[0])
        for h, v in zip(rh, row[1:]):
            tdc = None
            t = c(tf)
            e = h / 100 * esw(t)
            # dewpoint from vapor pressure (inverse Magnus)
            ln = math.log(e / 6.112)
            tdc = 243.12 * ln / (17.62 - ln)
            cells.append((tf, h, int(v), t, tdc))
    lines = ",".join("(%d,%d,%d,%r,%r)" % cell for cell in cells)
    grid = """
def fetch_forecast(lat, lon, tz):
    return None
def fetch_obs(station, now):
    return None
def main(config):
    for tf, h, v, t, td in [%s]:
        print("GRID %%d %%d %%d %%s" %% (tf, h, v, str(c_to_f(wet_bulb_c(t, td, 1013.25)))))
    return []
""" % lines
    r, _ = run("chart_check", grid, rename_main=True)
    got = re.findall(r"GRID (\d+) (\d+) (\d+) ([\d.]+)", r.stdout + r.stderr)
    exact = sum(1 for _, _, v, w in got if int(math.floor(float(w) + 0.5)) == int(v))
    worst = max(abs(float(w) - int(v)) for _, _, v, w in got) if got else 99
    ok = len(got) == len(cells) and worst < 1.0
    failures += not ok
    print("%s chart check: %d/%d cells exact after rounding, worst %.2fF" % (
        "PASS" if ok else "FAIL", exact, len(got), worst))

    # 2. Render scenarios
    for name, start, now_wb, series, age, expect in SCENARIOS:
        extra = """
def fetch_forecast(lat, lon, tz):
    return %s
def fetch_obs(station, now):
    return %s
""" % (forecast_literal(start, series), obs_literal(now_wb, age))
        r, made = run(name, extra, ["hide_above=0"])
        log = r.stdout + r.stderr
        ok = made and "source=nws" in log
        failures += not ok
        print("%s render %-8s expect '%s'" % ("PASS" if ok else "FAIL", name, expect))
        if not ok:
            print(log)

    # 3. Stale obs -> Open-Meteo fallback
    extra = """
def fetch_forecast(lat, lon, tz):
    return %s
def fetch_obs(station, now):
    return %s
""" % (forecast_literal(17, SCENARIOS[0][3], current_wb_f=30), obs_literal(25, 180))
    r, made = run("stale_obs", extra)
    ok = made and "source=open-meteo" in (r.stdout + r.stderr)
    failures += not ok
    print("%s stale obs falls back to open-meteo" % ("PASS" if ok else "FAIL"))

    # 4. Missing obs -> fallback
    extra = """
def fetch_forecast(lat, lon, tz):
    return %s
def fetch_obs(station, now):
    return None
""" % forecast_literal(17, SCENARIOS[0][3])
    r, made = run("no_obs", extra)
    ok = made and "source=open-meteo" in (r.stdout + r.stderr)
    failures += not ok
    print("%s missing obs falls back to open-meteo" % ("PASS" if ok else "FAIL"))

    # 5. Warm -> hidden (no output file)
    warm = [45, 46, 47, 47, 46, 45, 44, 43, 42, 41, 40, 40, 39]
    extra = """
def fetch_forecast(lat, lon, tz):
    return %s
def fetch_obs(station, now):
    return %s
""" % (forecast_literal(13, warm), obs_literal(45, 20))
    r, made = run("hidden", extra)
    ok = (not made) and r.returncode == 0 and "hidden:" in (r.stdout + r.stderr)
    failures += not ok
    print("%s warm forecast renders nothing (exit %d, file=%s)" % ("PASS" if ok else "FAIL", r.returncode, made))

    # 6. Forecast down -> error frame
    extra = """
def fetch_forecast(lat, lon, tz):
    return None
def fetch_obs(station, now):
    return None
"""
    r, made = run("no_data", extra)
    ok = made
    failures += not ok
    print("%s forecast failure renders NO DATA frame" % ("PASS" if ok else "FAIL"))

    print("\n%d failure(s)" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
