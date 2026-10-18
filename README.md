# Tidbyt Wet Bulb

A [Tidbyt](https://tidbyt.com) app for backyard snowmaking. It shows the current wet bulb temperature, the 3-hour trend, a 12-hour forecast chart, and the best snowmaking window for your location. GitHub Actions updates it every 30 minutes - no server, no local machine.

![Animation](docs/animation.gif)

![Scenarios](docs/preview.png)

## What it shows

| Area | Meaning |
|---|---|
| Big number (top left) | Current wet bulb (F), colored by zone |
| Arrow + number | Change over the next 3 hours (cyan ▼ falling, orange ▲ rising, gray - flat) |
| Bars (right) | Next 12 hours, one bar per hour, colored by zone. 1px per degree, 19F floor, 40F ceiling |
| Dotted line | 28F - bars above it are in the no-go zone |
| White underline | Best window - longest run of hours at 27F or colder |
| Bottom row | `GO start-end LO##` (window and its lowest wet bulb), or `NO WINDOW 12H` |
| Animation | Bars grow in left to right (about 1 second), the window underline follows, then the chart holds |

It only appears on your Tidbyt when the current wet bulb or any of the next 12 hours is at or below 39F (configurable). The rest of the time it removes itself from the rotation.

### Snowmaking zones

Based on the Backyard Snowstorm snowmaking chart.

| Wet bulb | Zone | Color |
|---|---|---|
| 19F and below | Great - light, dry snow | Pale cyan |
| 20-23F | Good - dry, packable | Cyan |
| 24-26F | Marginal - dense, heavy | Blue |
| 27F | Wet snow | Yellow |
| 28F and above | No go | Red |

## Set it up for your location

You need a Tidbyt and a GitHub account. About 10 minutes.

### 1. Copy the repo
Click **Use this template > Create a new repository** (or fork it). Public repos get unlimited free GitHub Actions minutes, so public is the simplest choice - your keys stay in Secrets either way.

### 2. Get your Tidbyt keys
In the Tidbyt mobile app: **Settings > General > Get API Key**. Copy the **Device ID** and **API Key**.

### 3. Add secrets
Repo **Settings > Secrets and variables > Actions > Secrets > New repository secret**:

| Secret | Value |
|---|---|
| `TIDBYT_DEVICE_ID` | Device ID from step 2 |
| `TIDBYT_API_KEY` | API Key from step 2 |

### 4. Add variables
Same page, **Variables** tab > **New repository variable**:

| Variable | Required | Example | Notes |
|---|---|---|---|
| `LAT` | Yes | `42.5039` | Your latitude (4 decimals is plenty) |
| `LON` | Yes | `-71.0723` | Your longitude, negative for the western hemisphere |
| `STATION` | No | `KBED` | NWS station for the current reading. Blank = nearest station |
| `HIDE_ABOVE` | No | `39` | Hide the app when nothing in the next 12h is at or below this (F). `0` = always show |
| `TIMEZONE` | No | `America/New_York` | Blank = the location's own timezone |
| `INSTALLATION_ID` | No | `wetbulb` | Only change if you run more than one copy on the same Tidbyt |

**Picking a station:** open `https://api.weather.gov/points/<LAT>,<LON>/stations` in a browser to see nearby stations, nearest first. An inland airport usually tracks a backyard better than a coastal one.

Or with the GitHub CLI:
```
gh secret set TIDBYT_DEVICE_ID -R <you>/<repo>
gh secret set TIDBYT_API_KEY -R <you>/<repo>
gh variable set LAT --body "42.5039" -R <you>/<repo>
gh variable set LON --body "-71.0723" -R <you>/<repo>
gh variable set STATION --body "KBED" -R <you>/<repo>
```

### 5. Turn on the workflow
- **Forks only:** open the **Actions** tab and click **I understand my workflows, go ahead and enable them**. Template copies are enabled already.
- Run it once: **Actions > Push Wet Bulb to Tidbyt > Run workflow**.
- Open the run and expand **Render and push**. You should see a line like `source=nws station=KBED now_wb=32.4F ...`.

If a secret or variable is missing, the **Check configuration** step fails and says which one.

## How it works

| Value | Source |
|---|---|
| Current wet bulb | Latest NWS station observation (api.weather.gov) |
| Fallback current | Open-Meteo `current` - used when the NWS reading is missing, older than 90 min, or you're outside the US |
| 12-hour forecast | Open-Meteo hourly temperature, dewpoint and surface pressure |

Wet bulb is calculated from temperature, dewpoint and pressure with an iterative psychrometric solve (Magnus vapor pressure, WMO psychrometer coefficient). It matches the snowmaking chart on 120 of 136 test cells after rounding (worst 0.71F) and agrees with MetPy within 0.15F. Each run logs the calculated value next to Open-Meteo's own wet bulb as a cross-check.

**Schedule:** every 30 minutes at :10 and :40, year-round. When it's warm the app hides itself, so summer runs do nothing visible. A monthly keepalive job stops GitHub from pausing the schedule after 60 days without commits.

**Outside the US:** works anywhere Open-Meteo covers. NWS observations are US-only, so the current reading comes from Open-Meteo instead. Display is in Fahrenheit.

## Local preview and tests

Install [Pixlet](https://github.com/tidbyt/pixlet/releases) (Mac: `brew install tidbyt/tidbyt/pixlet`).

```
pixlet serve wetbulb.star                       # live preview at http://localhost:8080
pixlet render wetbulb.star lat=44.27 lon=-71.30 hide_above=0   # any location, always show
PIXLET=pixlet python3 tests/run_tests.py        # offline tests, renders to tests/out/
```

The tests check the wet bulb math against the snowmaking chart (`tests/chart.csv`) and render fixture scenarios with the real app code: falling, rising, great, no-go, stale observation, missing observation, too warm (hidden), cooling to 39F (shown), and forecast outage.

## Credits

- Weather data by [Open-Meteo.com](https://open-meteo.com) (CC BY 4.0) and the National Weather Service
- Snowmaking zones from the Backyard Snowstorm snowmaking chart
- Built with [Pixlet](https://github.com/tidbyt/pixlet)

MIT licensed - see [LICENSE](LICENSE).
