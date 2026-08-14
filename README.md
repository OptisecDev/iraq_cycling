# iraq_cycling

An Arabic-first GPS ride-tracking app for cyclists in Iraq (Baghdad-focused),
built with Flutter. Fully offline-capable: rides, maps, and the rider profile
all work with no backend and no network connection once tiles are cached.

## Features

- **Live ride tracking** — distance, duration, average/current speed, and
  elevation gain, recorded via GPS and saved locally.
- **Waze-style live navigation map** — the map follows the rider, rotates to
  match their heading, tilts into a 3D perspective, and zooms dynamically
  with speed while a ride is active; a recenter button reappears if the
  rider manually pans away.
- **BLE heart-rate support** — connects to any standard Bluetooth Heart Rate
  Service device (chest straps, or watches like the Fitbit Charge 6 in HR
  broadcast mode). Entirely optional: rides track and save fine with no
  sensor connected.
- **Live heart-rate/calorie HUD** — a floating overlay on the map shows the
  current BPM (with a heart icon that pulses in time with it) and the
  ride's running calorie total, estimated live from heart rate using the
  Keytel et al. (2005) formula and the rider's saved weight/age/gender.
- **Rider profile** — name, weight, age, gender, and preferred unit, used to
  personalize calorie estimates.
- **Offline maps** — Baghdad-area map tiles can be pre-downloaded for
  offline use, with opportunistic caching as tiles are viewed and a banner
  if tiles can't be fetched and nothing is cached.
- **Traffic hazard voice alerts** — riders mark their own known dangerous
  locations (e.g. a bad intersection); approaching one during a ride
  triggers a spoken Arabic warning via on-device text-to-speech. There's no
  bundled hazard data — only what the rider adds themselves.
- **Ride history** — past rides list with full recorded route and stats.

## Getting started

Standard Flutter workflow:

```
flutter pub get
flutter run
```

See `PROJECT_STATE.md` for implementation notes, known limitations, and
decisions behind specific tradeoffs (e.g. the map tile provider, hazard
data policy, and calorie estimation fallback).
