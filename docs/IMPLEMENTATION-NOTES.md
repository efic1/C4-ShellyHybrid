# Implementation notes

`SPEC.md` and `ARCHITECTURE.md` describe the design agreed before the build. This file records where the code
differs, what was measured, and what has not been proven. Where they disagree, **this file and the code win**;
the two documents carry a banner pointing here and short notes at the affected passages.

## Deviations from SPEC / ARCHITECTURE

- **Bundling.** Each driver is ONE generated `driver.lua` with all modules embedded and resolved by a private
  `require` (no `package.path`, no `package.preload`, no shared `src/common` copy inside the package).
  `tools/build.py` replaces `build.sh`'s copy step and `tools/gen_driver_xml.py`. Single source of truth is
  `tools/spec.py`.
- **Events and variables.** Events are static in `driver.xml` with pinned IDs (child 100-105, relay 110/111,
  hub 200-203), so loading a driver makes zero `AddEvent` calls. Variables are created at runtime; their IDs are
  assigned by Director, so the **names** are the contract.
- **Default Room ID** is an integer property, not a list.
- **Relay child** is a RELAY provider (connection id 1). The installer binds a relay-consuming device to it.
  How commands reach a non-proxy connection is unverified.
- **Fetch Devices** uses the `/device/all_status` listing, which has no device names. Names are
  generated as `model + last 4 of id + kind + channel`.
- **No HELLO message.** After `C4:AddDevice` the hub sends CONFIG (retried at +3 s and +10 s). The child
  registers with back-off 10/20/40/60 s until acknowledged and keeps retrying after an UNKNOWN_DEVICE refusal.
- **No `LIGHT_BRIGHTNESS_CHANGING`.** Shelly commands are instantaneous, so light children send only
  `LIGHT_BRIGHTNESS_CHANGED`, on command success (optimistic) and on confirmation. A failed or timed-out command
  snaps the UI back. This deliberately drops the tests `light_command_sends_changing_then_changed`,
  `light_zero_crossing_fires_on_off_exactly_once` and `blind_reversal_carries_real_start_level`.
- **One device password** for the whole hub. There is no per-device override property.
- **LAN Restored** fires only after a real Fallback Started. A cloud-first route while the LAN is still being
  confirmed at start-up is not a fallback.
- **Cover motion watching** lives in the router (`watchMotion`): after a command or a poll that sees a moving
  cover, the cover is re-read every 1.5 s (LAN) / 3 s (cloud), up to 80 times, slower when many covers move.
- **Cloud goes Offline after 2 consecutive network failures** (1 is Degraded); only Connected/Degraded route.
- **Identity by MAC tag.** A record's tag is its MAC, or the trailing 12 hex digits of its id. This assumes the
  cloud id equals the device MAC (unverified).
- **Slider rate limit.** Level and position commands are limited to one per component per 250 ms, latest wins.
- **Persistence is compact** (short keys, `s0,s1` component strings, children by device index): 9 KB / 17 parts
  for 40 devices.
- **Test layout.** `tests/director.lua` (a mock Director that loads the REAL bundled drivers, validates every
  property, event and variable name against the generated XML, routes `SendToDevice` between instances and counts
  every Director-bound call) replaces `mock_c4.lua` and `proxy_doubles/`. Fixtures from real hardware do not exist
  yet (M0).
- **Auto-Setup file mapping.** light to `shelly_light`, switch to `shelly_light_onoff` or `shelly_relay`
  (Switch Default Type), cover to `shelly_blind`.

## Verification against Shelly documentation and Home Assistant (2026-09-30)

The LAN and cloud assumptions were checked against Shelly's published API docs and Home Assistant's client library
(see `API-NOTES.md` for sources, what was verified, and what could not be read). Behaviour changes that came out of it:

- Lights: the state read during a transition is the transition **target**; uncalibrated dimmers are on/off only.
- Covers: calibration is `pos_control`; a calibrated cover with an unknown position accepts open/close/stop only.
- LAN client: `null` results are success, any other non-JSON 200 is not; 429 is transient; the digest realm is checked
  before answering a challenge; `enhanced_security` selects HTTPS.
- Add Device By ID accepts several ids and uses only the v2 `get`. Fetch Devices uses `/device/all_status`, which is
  documented on the Real Time Events page (with OAuth Bearer auth; this driver sends `auth_key`, unconfirmed), and points
  at Add Device By ID when it fails.
- The LAN simulator now returns `null` for Light.Set / Cover.*, models light transitions, 429 throttling and Enhanced
  Security redirects, so tests can catch these classes of bug (three tests were mutation-checked against their fixes).

## Verification against a live-tested driver (efic1/C4-UnifiProtect) and Snap One docs (2026-09-30)

- `C4:AddDevice` now uses the documented call forms (see `API-NOTES.md`); the mock Director rejects any other form and a room of 0.
- Children replay their proxy state shortly after first registration, because a device created by `AddDevice` may not have a
  listening proxy yet and every notification here is de-duplicated.
- The documentation file is `www/documentation.html`.
- `tools/check_forward_refs.py` (from that repo's notes: a call to a `local` defined later in the file compiles, then fails at
  runtime) runs in `build.sh` and the generator tests, and is itself mutation-tested.

## Verification against a second live-tested driver (efic1/C4-SwitchBotUltra) (2026-09-30)

- **Bug found and fixed:** the child drivers never handled `LUA_ACTION`, so *Re-register With Hub* and *Show Status* could not run
  (the hub could). Both drivers now resolve an action from its name or its command; a new *Resend State* action was added.
- The relay child follows the contact/relay notification rule (state on the first report, transition only on a change) and
  republishes when a consumer binds after setup. The mock Director exercises actions and bindings the way Composer does.
- The relay provider connection and command names (`CLOSE`, `OPEN`, `TOGGLE`, `TRIGGER` at the connection id) match that driver.
- Packaging rules (no directory entries, no XML declaration, stable names) are now tests.

## Verification against Control4's proxy guide and official light sample (2026-09-30)

- Light children: the proxy binding is declared as a `LIGHT_V2` connection; capabilities follow `light_sample.c4i` (adds `on_off`,
  `ramp_level`, scene flags); category `Lighting`; they answer `GET_CONNECTED_STATE`, accept `SET_LEVEL`, `RAMP_TO_LEVEL` and
  `BUTTON_ACTION`, and send feedback per the *Feedback Notification* property (originally *Both*: `LIGHT_BRIGHTNESS_CHANGED` plus the
  sample's `LIGHT_LEVEL`) because one parameter name could not be verified. Cost: one extra `SendToProxy` per change in the default mode.
  **Superseded** by the guide text the author supplied: the command parameters are `LIGHT_BRIGHTNESS_TARGET_PERCENT` / `_LEVEL` /
  `_PRESET_ID` (presets 1-4 are handled) and the default feedback is `LIGHT_BRIGHTNESS_CHANGED` only (`LIGHT_BRIGHTNESS_CURRENT` verified).
- Blind: dropped the dynamic `SET_CAN_STOP` (static `can_stop` suffices; a malformed one could switch stopping off) and the
  `level_unknown` capability; the proxy binding is declared as a connection.
- Those are the only two proxy items whose parameter names remain unverified; both fail visibly (a tile that does not update, a blind
  slider that misreports) on the first hardware test.

## Blind notifications rewritten against the guide (2026-09-30)

The blind glue sent `MOVING` on every progress poll with the *current* position as `LEVEL` and no `RAMP_RATE`, and reported an unknown
position as no level at all. It now follows the guide: one `MOVING` per movement (`LEVEL_TARGET`, `RAMP_RATE`, start `LEVEL`), `STOPPED`
with the final level, and the no-feedback scheme (open 0 / closed 2 / unknown 1) for uncalibrated or position-less covers. New property
*Full Travel Time (s)* (default 20) feeds `RAMP_RATE`. Side effect: a moving cover no longer costs the child a Director call per poll.

## Light V2 capabilities corrected against the guide's list (2026-09-30)

`advanced_scene_support` (full ALS commands) and `reduced_als_support` are alternatives: lights now declare advanced False / reduced True
(my earlier change had set both True, which claimed scene commands this driver does not handle). `ramp_level` is True for dimmers so ALS can
dim them, made honest by mapping the proxy's `RATE` to the device's `transition_duration` on the LAN (cloud: ignored). The on/off light
declares neither `set_level` nor `ramp_level`.

## Verification against two working Home Assistant bridge drivers (2026-09-30)

- Blind children handle `UP` and `DOWN` (the proxy sends them for its open/close buttons and instead of a level when `HAS_LEVEL` is false -
  without this an uncalibrated cover could not be opened from a Navigator) and send `SET_CAN_STOP {CAN_STOP = true}` (name now confirmed).
- Light children also accept `GROUP_SET_LEVEL` / `GROUP_RAMP_TO_LEVEL`. The `BLIND` and `LIGHT_V2` connection classes, `LIGHT_BRIGHTNESS_CHANGED`,
  `ONLINE_CHANGED`, `SYNCHRONIZE`, `BUTTON_ACTION` and the blind notification spellings are confirmed.
- Not adopted: full ALS (`PUSH_SCENE` / `ACTIVATE_SCENE`), load groups, button links, dynamic capabilities, the undocumented capability tags.

## Device profiles and per-device switch types (2026-09-30)

- `Switch Type Overrides` (hub property, `id[:channel]=Relay|Light`; id may be a 4+ character suffix; most specific wins).
- The probe records the device `profile`; *List Devices* shows it. Colour-only components (`rgb`, `rgbw`, `cct`, `rgbcct`) are reported as not
  controllable by *Fetch Devices*, *Add Device By ID* and *Auto-Setup Children*.
- Registry: a read that lists components marks the ones it no longer reports as `gone` (excluded from Auto-Setup); LAN reads now upsert the
  component set (a few table lookups per poll; Director cost unchanged).
- Not done: brightness-only control of `rgb` / `rgbw` / `cct` components (see API-NOTES for the verified `RGB.Set` shape).

## Alarm sensors (2026-09-30)

New child driver `shelly_sensor` for `flood:N` / `smoke:N`: a `CONTACT_SENSOR` provider (connection 1) with the relay's STATE-on-first /
transition-on-change rule, events Alarm Started (112) / Alarm Cleared (113), variables Alarm / Muted, properties *Sensor Component* and
*Alarm Contact State*, and no commands (a remote mute could leave residents unaware). Hub side: parse + registry value + compact-persistence
letters for both kinds, and `Proto.compatible("sensor", flood|smoke)`. Child core: the component can be chosen per child (property named by
the glue), and a glue may set a longer offline debounce (25 h) and suppress route events. Polling: no new code - the existing 60-second cloud
cycle already covers devices the LAN cannot reach, which is every sleeping sensor.
Design limit: latency is that cycle plus the device's own report time (roughly 1-2 minutes). Push (webhook / outbound WebSocket receiver)
is the way to seconds; it needs a listener on the controller and device-side configuration while awake, and is not built.

## Gen1 support (2026-09-30)

Scope: Shelly 1 (SHSW-1) relay, Flood SHWT-1, Smoke SHSM-01, Gas SHGS-1. New module `hub/transport/lan_gen1.lua` (Basic auth with the same
one-wrong-password lockout; `GET /status`; `GET /relay/N?turn=`), Gen1 detection in the probe (`/shelly` with `type` and no `gen`), Gen1
status parsing (`relays[]`, `flood`, `smoke`, `gas_sensor`, `wifi_sta`, top-level `mac`), the generation and model persisted in the address
book, a `gas` component with an *Alarm Level* variable, and a per-component offline debounce for the sensor glue (gas 10 min, battery sensors
25 h). Safety decisions: Gen1 is never commanded through the cloud (undocumented), and relays are only read from allow-listed models so a
2.5-in-roller-mode motor can never be offered as two lights. Not done: other Gen1 relay models, rollers, dimmers, RGBW2, plugs, TRV, H&T.

## Pulse safety (2026-10-01)

Found while checking a garage-door setup: the router retried an unreachable LAN request once and then fell back to the cloud, which is correct
for absolute on/off commands but fires extra pulses for a `toggle_after` pulse whose reply was lost. A pulse is now repeated only when the
failure proves nothing was sent (connection refused, failed TLS handshake, no address); any other failure returns an `ambiguous` failure
with no retry and no cloud fallback.

## Contact sensors and garage-door feedback (2026-10-01)

New child `shelly_contact` and a normalised `contact` component (`closed`, optional `battery`) fed by Gen2 `input:N` (boolean state), Gen1
Shelly 1 `inputs[]` and the Gen1 Door/Window. Inputs are **opt-in** through the hub property *Contact Inputs* (a Plus 2PM has two wall-switch
inputs; creating a driver for every input would flood a project), Door/Window sensors are automatic. Component order out of the parser is now
sorted (it used to depend on Lua's hash order). After a successful pulse, when a contact driver is bound on that device, the router re-reads it
ten times over a minute (`Router:followUp`) so a moving door is seen in seconds; this is skipped when no contact driver exists and after an
ambiguous failure. Mixed offline policy: a contact whose value carries a battery level waits 25 h, otherwise 60 s.

## Measured Director load (`lua5.1 tests/profile.lua`, asserted in `tests/test_regressions.lua`)

Counts are Director-bound API calls made by the driver, from the mock Director.

- Init, empty hub: 8 (1 persist read, 1 timer, 6 property writes). Restored 40-device hub: 25 (17 persist reads).
- Init, child: 4 (light), 5 (blind, relay). Budget is 10.
- Steady state, 40 devices / 53 children, nothing changing for 10 minutes:
  - all children combined: **0**;
  - hub: 44 `SetTimer`, 4 `UpdateProperty`, 0 `SendToProxy`, 0 `PersistSetValue`, 0 `FireEvent`;
  - network: 1208 requests (2.0 per second), never more than 3 LAN requests in flight;
  - timers held by the hub: 3 (one native repeating poll tick, one native sweeper, one scheduler timer).
- One dimmer command: child 4 calls (1 `SendToDevice`, 1 `SendToProxy`, 1 `SetTimer`, 1 `UpdateProperty`);
  hub 12 (2 `SendToDevice`, 2 `SetTimer`, 8 network requests including background polls).

How it is kept low:

- One scheduler owning at most one Control4 timer; the LAN poll tick and the request sweeper are single native
  repeating timers (a re-arm per fire would cost thousands of `SetTimer` calls).
- Synchronous LAN dispatch (no timer per submit) and one shared watchdog sweeper instead of a timer per request.
- Writes to properties, variables and the proxy only when the value changed (`SetProp`, `Child:once`).
- Debounced persistence (30 s) and status refresh (2 s); nothing is persisted from a poll.
- Auto-Setup creates one child every 400 ms. Feeds start in `OnDriverLateInit`. An empty hub holds no poll timer.
- Per-child state pushes are de-duplicated on `(online, route, value)`.

Found and fixed by profiling: 4840 `SetTimer` calls per 10 minutes in the first build, then 164, now 44.

## Regression list status

Every name in `ARCHITECTURE.md` "Testing" is covered by a test with the same or a descriptive name (several are merged into one test), except:

- the three tests listed under "No `LIGHT_BRIGHTNESS_CHANGING`" above (design change);
- `changing_is_always_followed_by_changed_or_offline`, adapted to "a command is always followed by a confirmation or
  a failure snap-back";
- tests that need captured payloads (fixtures) rather than simulator output.

## What has NOT been verified

Nothing has run against real Shelly hardware, the real Shelly cloud, or a Control4 controller. All verification is
offline against simulators and a mock Director written from the documented behaviour. See `API-NOTES.md` for the full list;
the ones most likely to need changes are:

- cloud `status` bodies beyond `sys` and whether `all_status` accepts `auth_key` (cloud id equals MAC is now documented);
- digest behaviour on real old and new firmware (the algorithm now matches the docs);
- `follow_redirects`, `C4:RenameDevice`, and `AddVariable` timing (`C4:url`, `C4:Hash`, `C4:AddDevice` and `LUA_ACTION` are now documented);
- `light_v2` and `blind` proxy capabilities and notification parameter names; relay provider command delivery;
- real latency, controller CPU and memory at scale (the simulators cannot show these).

## Review: edge cases and controller load (2026-10-08)

Method: `lua5.1 tests/soak.lua [hours] [devices]` runs a mixed, misbehaving fleet (Gen2 lights/switches/covers, Gen1 relay with a
contact input, a sleeping flood sensor, a gas detector, a flapping Wi-Fi device, cloud outages every 30 min, commands and alarm
flips) and reports per-hour Director calls, HTTP requests, persist writes, log lines and memory.

Measured (30 devices, 12 simulated hours): memory flat (-140 KB after GC), 0 persist writes after provisioning, ~0 log lines,
hub ~6,100 Director calls/h (about 90% are `C4:url` for LAN polls, ~1.5 requests/s at the 20 s default), children ~200 calls/h
combined, 3 Control4 timers held by the hub, max 2 LAN requests in flight. 40 devices steady state: 2.0 requests/s.
Bad neighbours: a dead device falls to ~24 requests/h, a wrong-password device stops after one request, cloud calls rise from 12/h
to ~85/h while any device is unreachable (cloud fallback reads).

Fixed:
- A LAN request that never completed was released by the dispatcher watchdog, but the poll feed's `inflight` flag stayed set,
  so that device was never polled again until a reload. The flag is now timestamped and expires after 2x the watchdog.
  (`a_request_that_never_completes_does_not_stop_polling_that_device_for_good`)
- `Contact Inputs` matching is now case-insensitive for both the entry and the stored device id.

Left as-is (judgement calls, see the review message): polling is the dominant controller cost; cloud reads rise while a device is down;
follow-up reads after a pulse log up to 10 "could not verify" warnings if the device is offline.
