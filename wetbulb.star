"""
Tidbyt Wet Bulb - snowmaking conditions for any location.

Current wet bulb (NWS station obs, Open-Meteo fallback), 3-hour trend,
12-hour forecast bars colored by snowmaking zone, and the best window.
Zones follow the Backyard Snowstorm snowmaking chart (wet bulb, F).
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

# ---------- Config defaults (override via pixlet render key=value) ----------
# The GitHub workflow passes these from repository Variables.
DEFAULT_LAT = "42.5039"  # Wakefield, MA - local preview only
DEFAULT_LON = "-71.0723"
DEFAULT_STATION = ""  # NWS station ID; blank = nearest station to lat/lon
DEFAULT_TZ = "auto"  # Open-Meteo resolves the location's own timezone
DEFAULT_HIDE_ABOVE = "39"  # skip render when now + next 12h are all above this (F)
DEFAULT_CONTACT = "github.com/kkarner23/tidbyt-wetbulb"  # NWS asks for a contact in the User-Agent

WINDOW_MAX = 27  # best window = hours at Wet snow or better
OBS_MAX_AGE_MIN = 90  # older NWS obs falls back to Open-Meteo current

# ---------- Layout ----------
CHART_H = 22  # leaves a gap between the window underline and the bottom text
SCALE_MIN = 18  # 19F -> 1px, 40F+ -> 22px (1px per degree)
BAR_W = 2
BAR_STEP = 3
NO_GO_LINE_F = 28

# ---------- Animation ----------
FRAME_MS = 50  # 20 fps
BAR_STAGGER = 1  # frames between each bar starting to grow (left to right)
BAR_GROW = 5  # frames for one bar to reach full height
HOLD_MS = 15000  # hold the finished chart for the rest of the display time

# ---------- Zones (Backyard Snowstorm chart) ----------
def zone_color(wb):
    if wb <= 19:
        return "#c8f4ff"  # Great
    elif wb <= 23:
        return "#18c4f0"  # Good
    elif wb <= 26:
        return "#3a7bff"  # Marginal
    elif wb <= 27:
        return "#f5d90a"  # Wet snow
    return "#e5352b"  # No go

# ---------- Psychrometrics ----------
# Magnus saturation vapor pressure over water (hPa), T in C.
def es_water(t):
    return 6.112 * math.exp(17.62 * t / (243.12 + t))

# Wet bulb (C) from air temp (C), dewpoint (C), pressure (hPa).
# Solves e = es(Tw) - A * P * (T - Tw) by bisection, WMO psychrometer
# coefficient. Water-bulb form, which matches the snowmaking chart.
def wet_bulb_c(t, td, p):
    if td >= t:
        return t
    e = es_water(td)
    lo = td
    hi = t
    for _ in range(40):
        tw = (lo + hi) / 2.0
        a = 6.53e-4 * (1.0 + 0.000944 * tw)
        f = es_water(tw) - a * p * (t - tw) - e
        if f > 0:
            hi = tw
        else:
            lo = tw
    return (lo + hi) / 2.0

def c_to_f(c):
    return c * 9.0 / 5.0 + 32.0

def rnd(x):
    return int(math.floor(x + 0.5))

def f1(x):
    return str(math.floor(x * 10.0 + 0.5) / 10.0)

# ---------- Data ----------
def fetch_forecast(lat, lon, tz, ua):
    url = (
        "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s" % (lat, lon) +
        "&hourly=temperature_2m,dew_point_2m,surface_pressure,wet_bulb_temperature_2m" +
        "&current=temperature_2m,dew_point_2m,surface_pressure" +
        "&forecast_hours=13&timezone=%s" % tz
    )
    resp = http.get(url, headers = {"User-Agent": ua})
    if resp.status_code != 200:
        print("open-meteo error: status %d" % resp.status_code)
        return None
    data = resp.json()
    h = data["hourly"]
    c = data["current"]
    return {
        "times": h["time"],
        "t": h["temperature_2m"],
        "td": h["dew_point_2m"],
        "p": h["surface_pressure"],
        "om_wb": h["wet_bulb_temperature_2m"],
        "current": {
            "t": c["temperature_2m"],
            "td": c["dew_point_2m"],
            "p": c["surface_pressure"],
        },
    }

def nearest_station(lat, lon, ua):
    url = "https://api.weather.gov/points/%s,%s/stations" % (lat, lon)
    resp = http.get(url, headers = {"User-Agent": ua, "Accept": "application/geo+json"})
    if resp.status_code != 200:
        print("nws station lookup failed: status %d (outside the US?)" % resp.status_code)
        return None
    features = resp.json().get("features", [])
    if len(features) == 0:
        return None
    return features[0]["properties"]["stationIdentifier"]

def fetch_obs(station, lat, lon, now, ua):
    if station == "":
        station = nearest_station(lat, lon, ua)
        if station == None:
            return None
    url = "https://api.weather.gov/stations/%s/observations/latest" % station
    resp = http.get(url, headers = {"User-Agent": ua, "Accept": "application/geo+json"})
    if resp.status_code != 200:
        print("nws error: station %s status %d" % (station, resp.status_code))
        return None
    p = resp.json()["properties"]
    t = p["temperature"]["value"]
    td = p["dewpoint"]["value"]
    if t == None or td == None:
        print("nws obs missing temp/dewpoint")
        return None
    obs_time = time.parse_time(p["timestamp"])
    return {"t": t, "td": td, "age_min": (now - obs_time).minutes, "station": station}

# ---------- Model ----------
def build_model(fc, obs):
    n = len(fc["times"])
    hourly_wb = []
    for i in range(n):
        p = fc["p"][i] if fc["p"][i] != None else 1013.25
        hourly_wb.append(c_to_f(wet_bulb_c(fc["t"][i], fc["td"][i], p)))

    p_now = fc["current"]["p"] if fc["current"]["p"] != None else 1013.25
    if obs != None and obs["age_min"] <= OBS_MAX_AGE_MIN:
        now_wb = c_to_f(wet_bulb_c(obs["t"], obs["td"], p_now))
        source = "nws"
    else:
        cur = fc["current"]
        now_wb = c_to_f(wet_bulb_c(cur["t"], cur["td"], p_now))
        source = "open-meteo"

    # index 0 = current hour (now), 1..12 = next 12 hours
    vals = [rnd(now_wb)] + [rnd(v) for v in hourly_wb[1:13]]
    start_hour = int(fc["times"][0][11:13])

    print("source=%s station=%s now_wb=%sF hour0_calc=%sF hour0_openmeteo=%sF obs_age_min=%s" % (
        source,
        obs.get("station", "n/a") if obs != None else "n/a",
        f1(now_wb),
        f1(hourly_wb[0]),
        f1(c_to_f(fc["om_wb"][0])) if fc["om_wb"][0] != None else "n/a",
        f1(obs["age_min"]) if obs != None else "n/a",
    ))
    print("next12=%s" % str(vals[1:]))
    return {"now": vals[0], "vals": vals, "start_hour": start_hour, "trend": rnd(hourly_wb[3] - now_wb)}

def best_window(vals):
    best_s, best_len, cur_s, cur_len = -1, 0, -1, 0
    for i, v in enumerate(vals):
        if v <= WINDOW_MAX:
            if cur_len == 0:
                cur_s = i
            cur_len += 1
            if cur_len > best_len:
                best_s, best_len = cur_s, cur_len
        else:
            cur_len = 0
    return best_s, best_len

def hour_label(h):
    h = h % 24
    if h == 0:
        return "12A"
    if h < 12:
        return "%dA" % h
    if h == 12:
        return "12P"
    return "%dP" % (h - 12)

# ---------- Render ----------
def arrow(direction, color):
    if direction == 0:
        return render.Box(width = 5, height = 1, color = color)
    rows = [5, 3, 1] if direction < 0 else [1, 3, 5]
    return render.Column(
        cross_align = "center",
        children = [render.Box(width = w, height = 1, color = color) for w in rows],
    )

def render_view(m):
    now = m["now"]
    vals = m["vals"]
    fc = vals[1:]
    color = zone_color(now)

    delta = m["trend"]
    direction = 1 if delta >= 1 else (-1 if delta <= -1 else 0)
    acolor = "#18c4f0" if direction < 0 else ("#ff8c1a" if direction > 0 else "#888888")

    left = render.Column(
        children = [
            render.Row(children = [
                render.Text("%d" % now, font = "6x13", color = color),
                render.Padding(pad = (1, 2, 0, 0), child = render.Text("°", font = "tom-thumb", color = color)),
            ]),
            render.Box(width = 22, height = 3),
            render.Row(
                cross_align = "center",
                children = [
                    arrow(direction, acolor),
                    render.Box(width = 2, height = 1),
                    render.Text("%d" % abs(delta), font = "tom-thumb", color = acolor),
                ],
            ),
        ],
    )

    heights = [max(1, min(CHART_H, v - SCALE_MIN)) for v in fc]
    colors = [zone_color(v) for v in fc]

    # window underline spans bars first_bar..last_bar (bar i = hour i + 1)
    ws, wl = best_window(vals)
    first_bar = max(ws - 1, 0)
    last_bar = ws + wl - 2 if wl > 0 else -1

    if wl > 0:
        lo = min(vals[ws:ws + wl])
        start_lbl = "NOW" if ws == 0 else hour_label(m["start_hour"] + ws)
        bottom = render.Row(children = [
            render.Text("GO %s-%s" % (start_lbl, hour_label(m["start_hour"] + ws + wl)), font = "tom-thumb", color = "#ffffff"),
            render.Text(" LO%d" % lo, font = "tom-thumb", color = zone_color(lo)),
        ])
    else:
        bottom = render.Text("NO WINDOW 12H", font = "tom-thumb", color = "#e5352b")

    left_layer = render.Padding(pad = (1, -2, 0, 0), child = left)
    bottom_layer = render.Padding(pad = (1, 27, 0, 0), child = bottom)

    def frame(t):
        chart = chart_layers(heights, colors, first_bar, last_bar, t)
        return render.Stack(children = [
            left_layer,
            render.Padding(pad = (27, 0, 0, 0), child = render.Stack(children = chart)),
            bottom_layer,
        ])

    # Build: bars grow left to right, then the finished chart holds
    build = (len(fc) - 1) * BAR_STAGGER + BAR_GROW + 1
    frames = [frame(t) for t in range(build)]
    final = frames[-1]
    frames += [final] * (HOLD_MS // FRAME_MS)

    return render.Root(
        delay = FRAME_MS,
        show_full_animation = True,
        child = render.Animation(children = frames),
    )

# Chart layers at animation frame t. Bar i starts growing at t = i * BAR_STAGGER
# and eases out to full height over BAR_GROW frames. The window underline
# extends as each of its bars finishes.
def chart_layers(heights, colors, first_bar, last_bar, t):
    line_y = CHART_H - (NO_GO_LINE_F - SCALE_MIN)
    layers = [
        render.Padding(pad = (x, line_y, 0, 0), child = render.Box(width = 1, height = 1, color = "#555555"))
        for x in range(0, len(heights) * BAR_STEP - 1, 2)
    ]

    done_through = -1  # highest bar index at full height
    for i, full in enumerate(heights):
        p = (t - i * BAR_STAGGER) / float(BAR_GROW)
        if p <= 0:
            continue
        if p >= 1:
            h = full
            done_through = i
        else:
            ease = 1.0 - (1.0 - p) * (1.0 - p)
            h = int(math.floor(full * ease + 0.5))
        if h < 1:
            continue  # a 0-height Box would expand to fill its parent
        layers.append(render.Padding(
            pad = (i * BAR_STEP, CHART_H - h, 0, 0),
            child = render.Box(width = BAR_W, height = h, color = colors[i]),
        ))

    end_bar = min(last_bar, done_through)
    if end_bar >= first_bar:
        layers.append(render.Padding(
            pad = (first_bar * BAR_STEP, CHART_H + 1, 0, 0),
            child = render.Box(width = (end_bar - first_bar + 1) * BAR_STEP - 1, height = 1, color = "#ffffff"),
        ))
    return layers

def render_error(msg):
    return render.Root(
        child = render.Box(
            child = render.Column(
                cross_align = "center",
                children = [
                    render.Text("WET BULB", font = "tom-thumb", color = "#888888"),
                    render.Text(msg, font = "tom-thumb", color = "#e5352b"),
                ],
            ),
        ),
    )

def main(config):
    lat = config.get("lat", DEFAULT_LAT)
    lon = config.get("lon", DEFAULT_LON)
    station = config.get("station", DEFAULT_STATION)
    tz = config.get("tz", DEFAULT_TZ)
    hide_above = int(config.get("hide_above", DEFAULT_HIDE_ABOVE))
    ua = "tidbyt-wetbulb (%s)" % config.get("contact", DEFAULT_CONTACT)

    fc = fetch_forecast(lat, lon, tz, ua)
    if fc == None:
        return render_error("NO DATA")
    obs = fetch_obs(station, lat, lon, time.now(), ua)
    m = build_model(fc, obs)

    # Off-season: nothing at or below hide_above in the next 12h -> no frame
    if hide_above > 0 and min(m["vals"]) > hide_above:
        print("hidden: min wet bulb %d > %d" % (min(m["vals"]), hide_above))
        return []

    return render_view(m)
