# C4-ShellyHybrid

Control4 drivers for **Shelly Gen2+** devices. The Shelly cloud is used to **provision** (device list, addresses),
commands and feedback run over the **LAN**, and the cloud is the **fallback** when the LAN is unreachable.

> **Status: built and tested offline only.** Nothing has been run against real Shelly hardware, the real Shelly
> cloud or a Control4 controller. The Shelly API assumptions were checked against Shelly's published docs and Home
> Assistant's client library on 2026-09-30 ([docs/API-NOTES.md](docs/API-NOTES.md) lists what is verified and what is not).
> See [docs/IMPLEMENTATION-NOTES.md](docs/IMPLEMENTATION-NOTES.md) and
> [docs/API-NOTES.md](docs/API-NOTES.md) for the unverified list, and do the M0 spike before deploying.

## Drivers

- `shelly_hub.c4z` - cloud + LAN transport, inventory, setup, child protocol.
- `shelly_light.c4z` - dimmable light (`light:N`), Light V2 proxy.
- `shelly_light_onoff.c4z` - relay channel (`switch:N`) as an on/off light.
- `shelly_relay.c4z` - relay channel as a Control4 relay provider.
- `shelly_blind.c4z` - cover/shutter (`cover:N`), Blind proxy.
- `shelly_contact.c4z` - a device input terminal (reed/limit switch, e.g. a garage door) or a Gen1 Door/Window sensor as a read-only contact sensor.
- `shelly_sensor.c4z` - water-leak (`flood:N`) or smoke (`smoke:N`) sensor as a read-only contact sensor.

## Design in one paragraph

Commands are **absolute** (never toggle on the wire). LAN first with one retry, then the cloud only for
unreachable/auth failures (a device error is never retried elsewhere). One request in flight per device, three
overall. Digest authentication tries a wrong password once per device and then stops (persisted). Device identity
is checked so a re-used address is never commanded. After a command the device is read back once; the read-back
wins. Everything the Director sees is de-duplicated and debounced.

## Layout

- `src/common` - shared: util, log, scheduler, persistence, runtime adapter (the only module that calls Control4), child core.
- `src/hub` - transports (`transport/`), address book, registry, router, feeds (`feed/`), core.
- `src/light`, `src/light_onoff`, `src/relay`, `src/blind`, `src/sensor`, `src/contact` - proxy glue + entry points.
- `tools/spec.py` - single source of truth (properties, events, actions, connections). `tools/build.py` - generator/bundler/packager.
- `tests` - simulators (`lan_sim`, `cloud_sim`), mock Director, and 16 test files.
- `docs` - installer guide, API notes, implementation notes, and the original SPEC / ARCHITECTURE.

## Build and test

Requires Python 3 and Lua 5.1 (`lua5.1`, `luac5.1`).

```
./build.sh                  # generate XML + ids, bundle, package, then run all tests
python3 tools/build.py      # build only (writes build/*.c4z)
lua5.1 tests/run_all.lua    # tests only (needs a prior build)
lua5.1 tests/profile.lua    # Director-call profile
```

`ids.lua` is generated: never edit it. Bump `VERSION` in `tools/spec.py`; Composer only offers an update when the version increases.

## Performance

Measured with the mock Director (see IMPLEMENTATION-NOTES.md): 40 devices and 53 children with nothing changing
cost the children **zero** Director calls in 10 minutes and the hub about 4 property writes and 44 timer calls, at
2 network requests per second. A restored 40-device hub starts with 25 Director calls. These are
mock-Director counts, not controller CPU measurements.

## Installing

See [docs/COMPOSER-GUIDE.md](docs/COMPOSER-GUIDE.md).

## Known limitations

- Feedback is polled (default 20 s), not pushed.
- One device password for all devices.
- No CHANGING notification for lights; no colour, input events, BLU or temperature/humidity sensors. Gen1 support is limited to the Shelly 1, Flood SHWT-1, Smoke SHSM-01 and Gas SHGS-1 (LAN only, never via the cloud).
- Water-leak and smoke sensors are battery devices read through the cloud about once a minute: minutes of latency, read-only, not a safety path.
- LAN TLS is encrypted but not certificate-verified by default.
- Fetch Devices depends on an endpoint documented with OAuth authentication; the driver's `auth_key` use there is unconfirmed. Add Device By ID is the fallback.
- Not for safety- or security-relevant loads.
