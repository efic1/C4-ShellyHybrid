# API notes and verification status

Last verified: 2026-09-30, against the sources listed below. Nothing here was run against real hardware, the
real cloud or a Control4 controller. **Verified** means "matches the vendor's published documentation or
Home Assistant's client code", not "observed on a device".

## Sources used

Control4 side (added 2026-09-30): Snap One's DriverWorks API reference (snap-one.github.io/docs-driverworks-api), the
development notes and README of `efic1/C4-UnifiProtect` (a driver whose setup driver creates children with `C4:AddDevice`,
live-tested on OS 3.4.3), and working `C4:url` code posted on the C4 forums. **Not read:** that repo's source files
(only the README and `docs/DEVELOPMENT_NOTES.md` were reachable), so its exact `AddDevice` call was not seen.
Also the Control4 Proxy & Protocol guide (control4.github.io/docs-driverworks-proxyprotocol): only its table of contents and the first
~amplifier sections could be read, because the document is one very large page that can only be fetched from the top; a few fragments
of the blind section came through search. Control4's own `sample_drivers/light_sample.c4i` (docs-driverworks repo) was read in full.
Third-party notes (C4Bridge, DirectorLink) are cited below as corroboration only, not as authority.

Also two published Home Assistant bridge drivers by `bphillips09` - `Control4-HA-Blinds` (blind proxy) and `Control4-HA-Light` (light_v2 proxy) -
whose `driver.xml` and `commands.lua` were read in full. They are working, public drivers (the light one has 30 commits); whether each was
hardware-tested is not stated, so they count as strong corroboration, not as a spec.

Also `efic1/C4-SwitchBotUltra` (README, `driver.xml`, `CONTRIBUTING.md` and the first ~1000 of `driver.lua`'s 1176 lines): a cloud lock
driver that exposes a RELAY provider connection bound to Control4's generic Door Lock driver. Whether it has been observed working on a
controller is not stated in what I read.

- Shelly Gen2+ API docs: General/Authentication, General/RPCChannels, General/CustomHTTPSCertificates,
  ComponentsAndServices/Shelly, /Switch, /Light, /Cover (shelly-api-docs.shelly.cloud).
- Shelly Cloud Control API docs: Getting Started, Communication v2.0-beta, Communication (deprecated).
- Home Assistant Shelly integration documentation (home-assistant.io/integrations/shelly).
- `aioshelly` `rpc_device/wsrpc.py` - the client library Home Assistant uses.
- **Not read:** Home Assistant core's `homeassistant/components/shelly` source (GitHub blocks automated access to that
  tree). Home Assistant talks to devices over WebSocket, not HTTP POST, so it confirms the authentication maths and
  identifiers but not HTTP-specific details such as redirect headers.

## Verified

LAN (Gen2+ RPC):

- `GET /shelly` is unauthenticated even when a password is set, and equals `Shelly.GetDeviceInfo`:
  `id` ("shellypro4pm-f008d1d8b8b8"), `mac` (12 upper-case hex, no separators), `gen`, `auth_en`, `auth_domain`
  (= the id), and `enhanced_security`. Home Assistant derives the device id from `src.split("-")[1].upper()`.
- `POST /rpc/<Method>` with only the parameters as the JSON body is a documented form; the reply is the bare `result`.
  An empty parameter set is `{}`. `GET /rpc/<Method>?...` also works. HTTP has no keep-alive; a device allows 6 concurrent
  non-persistent RPC channels (we use at most 1 per device, 3 overall).
- Digest: SHA-256, user `admin`, `ha1 = SHA256(admin:realm:password)`, `ha2 = SHA256(METHOD:URI)` with the real HTTP
  method and URI, `response = SHA256(ha1:nonce:nc:cnonce:auth:ha2)`, `nc` as 8 hex digits. This is exactly what
  `lan_auth.lua` does. `realm` is the device id. Nonces are base64 (firmware 2.0+) or numeric (older).
- Firmware 2.0+: a nonce is valid for 1 hour or 30,000 requests with a strictly increasing `nc`; an expired nonce gives
  401 with `stale=true`. Brute-force protection: 1-10 failed logins in 10 minutes have no delay, 11-20 wait 10 s,
  then 30 s, 60 s, 5 min; a throttled device answers **429**. Our "one wrong attempt, then stop" is far below that.
  The device also answers 429 when its 32-entry nonce table is full.
- Home Assistant's client answers a 401 exactly once and then raises an authentication error, like ours.
- `Switch.Set {id, on, toggle_after}` (returns `{was_on}`), `Light.Set {id, on, brightness, transition_duration}`
  (returns `null`), `Cover.Open/Close/Stop {id}` and `Cover.GoToPosition {id, pos}` (return `null`).
- Status fields: `switch:N.output`; `light:N.output`, `.brightness`, `.transition.target`, `.flags` ("uncalibrated");
  `cover:N.state` (open, closed, opening, closing, stopped, calibrating), `.current_pos`, `.pos_control`;
  `sys.mac`; `wifi.sta_ip`; `eth.ip`.
- Enhanced Security (firmware 2.0+): factory devices serve HTTPS on 443 with certificates from Shelly's own PKI; port 80
  keeps working but **redirects every request to HTTPS**. Home Assistant likewise auto-detects it, uses HTTPS on 443
  and defaults to not verifying the certificate. Devices upgraded to 2.0 without factory certificates serve plain HTTP.

Cloud (Control API v2.0-beta, and the Real Time Events page for the listing):

- `POST https://<HOST>/v2/devices/api/get?auth_key=...` with `{ids (1-10), select, pick}` returns
  `[{id, type, code, gen ("G2"), online (0|1), status, settings}]`.
- **The cloud device id equals the device MAC** (documented example: id `b48a0a1cd978`, `sys.mac` `B48A0A1CD978`).
- `/v2/devices/api/set/switch|cover|light` bodies (`id`, `channel`, `on`, `toggle_after`, `position`
  open/close/stop/0-100, `brightness`) and `/set/groups` with per-target `failedCommands` keyed `<ID>_<CHANNEL>`.
  Success is HTTP 200 only; the error table (DEVICE_OFFLINE, DEVICE_FAILED_COMMAND, INSTANCE_NOT_FOUND, ...) matches
  `cloud.lua`. All requests are limited to **1 per second**.
- The key is a query parameter, the server host "is subject to change", and the key changes when the password changes.

## Verified - Control4 side

- Actions arrive as `ExecuteCommand("LUA_ACTION", {ACTION = "<command>"})` (Snap One example; same in the UnifiProtect notes).
- `C4:Hash(digest, data, {return_encoding = "HEX", data_encoding = "NONE"})`; the documented example returns lowercase hex.
- `C4:url()`: `:OnDone(function(transfer, responses, errCode, errMsg))` (`errCode == 0` success, `-1` aborted, otherwise a curl
  code such as 60 for a certificate problem), `:SetOptions({fail_on_error, timeout, connect_timeout, ssl_verify_host,
  ssl_verify_peer, response_headers_duplicates})` chained before `:Post(url, body, headers)`; the last entry of `responses` is
  the final response. Snap One's own text says drivers may implement basic or digest authentication over `C4:url`.
- `C4:AddDevice` (OS 3.2+): `(file, callback)`, `(file, roomId, callback)` or `(file, roomId, name, callback)`; the file is the
  `.c4z` name, the room is optional (default: the caller's room) and the callback receives the new device id. **Fixed:** the
  hub used to pass a room of 0 when none was configured; it now uses the room-less form and names the child afterwards.
- `C4:GetTime()` returns milliseconds since the epoch (3.2.3+). `C4:UpdateProperty` does not call `OnPropertyChanged`.
- `driver.xml`: properties, actions, script and documentation must be inside `<config>`, documentation must be a file, every
  event needs a description, `<version>` must be an integer. The generator follows this; the documentation file is now
  `www/documentation.html`, the layout verified in that repo.
- **Relay provider** (the SwitchBot Ultra driver): the connection is declared `<type>1</type>`, `<consumer>False</consumer>`,
  class `RELAY` (the shape this generator emits). Commands arrive at `ReceivedFromProxy(idBinding, strCommand, tParams)` with
  `idBinding` = the relay connection's id and `strCommand` one of `CLOSE`, `OPEN`, `TOGGLE`, `TRIGGER`. State goes back as
  `SendToProxy(idBinding, "STATE_CLOSED"|"STATE_OPENED"|"CLOSED"|"OPENED", {}, "NOTIFY")`. Rule from its contributing notes:
  `STATE_*` reports state without signalling a change (first report only), `CLOSED`/`OPENED` signal a real change (changes only);
  sending both on every report re-announced a transition each poll. The relay child now follows this.
- A consumer bound after the provider published hears nothing until the next change (unchanged state is not re-sent). The relay
  child republishes when a binding is made (`OnBindingChanged`) and on the **Resend State** action.
- `LUA_ACTION`: the Ultra driver's notes say `tParams.ACTION` is the action's `<name>` ("Refresh Status" -> `REFRESH_STATUS`),
  the UniFi Protect notes say `<command>`, and Snap One's example compares against a name-like string. The Ultra driver's
  names and commands normalise to the same key, so its code cannot tell them apart. This driver resolves either form
  (`Proto.resolveAction`), and the **child drivers' actions were broken before this change** (they never handled `LUA_ACTION`).
- `C4:url` `timeout` is **in seconds** (Snap One: "In seconds. Defaults to 300 ... how many seconds, total, the entire transfer
  is allowed to take"), `connect_timeout` likewise. This adapter passes seconds. (The Ultra driver passes `10000`, i.e. about
  2.8 hours - see the note in the delivery message.)
- Packaging (Ultra `CONTRIBUTING.md`): Control4's packager writes an archive with **no directory entries**, and `driver.xml` must
  have **no XML declaration**, or Composer's "Update Driver" fails silently. Keep `<name>`, `<model>`, `<manufacturer>`,
  `<creator>` and the `.c4z` file name stable across releases. Both packaging rules are tested here.
- **Light V2 proxy** (official `light_sample.c4i`): the proxy binding is also declared as a connection - `<id>5001</id>`, `<type>2</type>`,
  class `LIGHT_V2` - in addition to `<proxies>`; capabilities include `dimmer`, `set_level`, `ramp_level`, `on_off`, `min_max`,
  `click_rates`, `hold_rates`, `cold_start`, `has_leds`, `supports_broadcast_scenes`, `supports_multichannel_scenes`,
  `hide_proxy_events`, `reduced_als_support`, `advanced_scene_support`, `load_group_support`, `buttons_are_virtual`; Composer category
  `Lighting`. The proxy sends `SET_LEVEL` / `RAMP_TO_LEVEL {LEVEL}`, `ON` / `OFF` / `TOGGLE`, `BUTTON_ACTION {BUTTON_ID 0 top/on, 1
  bottom/off, 2 toggle; ACTION 0 long release, 1 press, 2 release}` and `GET_CONNECTED_STATE` (answer: `ONLINE_CHANGED {STATE}`); the
  sample's feedback is `LIGHT_LEVEL` with the bare level as the parameter. With `supports_target` the newer command is
  `SET_BRIGHTNESS_TARGET {LIGHT_BRIGHTNESS_TARGET, RATE}` (third-party drivers report that pair against a live system).
  The light children now handle all of these and declare the connection and capabilities.
- **SET_BRIGHTNESS_TARGET and LIGHT_BRIGHTNESS_CHANGED** (the guide's own text, supplied by the author): the command carries
  `LIGHT_BRIGHTNESS_TARGET_LEVEL` (float, min..max as the device reports), `LIGHT_BRIGHTNESS_TARGET_PRESET_ID` and
  `LIGHT_BRIGHTNESS_TARGET_PERCENT` (0-100), plus an optional `RATE` in ms (-1 = unspecified). Every light has static presets:
  1 On (a top click), 2 Off (a bottom click), 3 Slow On (a top hold), 4 Slow Off (a bottom hold); more can be added. `SET_LEVEL` and
  `RAMP_TO_LEVEL` are deprecated in favour of it (RATE 0 / RATE ms). The notification is `LIGHT_BRIGHTNESS_CHANGED` with
  `LIGHT_BRIGHTNESS_CURRENT` (a double, the raw value where the light stopped); no `CHANGING` is required, it must be sent when the
  driver starts or the hardware comes online, and **dimmers and switches should use only `CHANGED`/`CHANGING`, no longer the level
  notify**. This corrected two assumptions here: the command parameters were read as `LIGHT_BRIGHTNESS_TARGET` (from third-party notes)
  and would have been refused as "missing brightness target", and the feedback default was *Both*. The light children now read the
  documented names (then the old spellings), map presets 1-4 to on/off, and default to `LIGHT_BRIGHTNESS_CHANGED` only;
  *Feedback Notification* keeps `LIGHT_LEVEL` available (the one report that it drove the UI on a live Director predates this text).
- **Light V2 capabilities** (the guide's full list, supplied by the author) - three corrections to what this generator emitted:
  `advanced_scene_support` means the driver implements the FULL ALS commands and `reduced_als_support` is the alternative for drivers
  that do not (the light may join a scene, cannot take part in scene ramping, 0 or 1 elements per scene) - they are now advanced False,
  reduced True (both were True); `ramp_level` is what lets ALS dim a light, so it is True for dimmers (RATE is honoured on the LAN as
  `Light.Set transition_duration`; the cloud path ignores it); the on/off light no longer claims `set_level`/`ramp_level`. Unchanged and
  confirmed: `dimmer`, `set_level`, `supports_target` (new ramping API; switches use it too), `on_off` (Composer on/off commands),
  `min_max`/`click_rates`/`hold_rates`/`cold_start`/`has_leds`/`supports_default_on`/`load_group_support` false, `buttons_are_virtual` true
  (no physical keypad), `num_buttons` 0, `supports_color` false, `hide_proxy_properties` left at its default (false; it is meant for
  extremely limited hardware). Every capability in the list is now accounted for.
- **Advanced Lighting Scenes** (proxy guide text): a driver either parses the XML in the `PUSH_SCENE` command sent when the device comes
  online, or declares `reduced_als_support`, which makes ALS send individual `SET_BRIGHTNESS_TARGET` / `SET_COLOR_TARGET` commands when a
  scene activates ("most drivers will find this sufficient... less than 1% of systems have multi-element scenes"). Control4's own
  sample sets it False only because it does not handle scenes; the light children now declare it True. Third-party captures show the
  parameter appearing as `LIGHT_BRIGHTNESS_TARGET` (+`RATE`) in the sample driver and as `PERCENT` on other paths, so the light glue
  accepts `LIGHT_BRIGHTNESS_TARGET`, `PERCENT` or `LEVEL`. Navigators and remotes: the on/off tile arrives as `SET_BRIGHTNESS_TARGET 0`
  or `TOGGLE`; remotes and keypads send `BUTTON_ACTION` (0 on / 1 off / 2 toggle, on release).
- **Undocumented light-proxy traffic** (control4/docs-driverworks issue #4, a developer testing against a live Director): besides the
  documented commands the proxy also sends `GET_LIGHT_LEVEL`, `GET_CONNECTED_STATE`, `SYNCHRONIZE`, `ON`, `OFF`, `TOGGLE_PRESET`,
  `PUSH_TOGGLE_BUTTON`, `RELEASE_TOGGLE_BUTTON`, and the Advanced Lighting Scene commands (`CLEAR_ALL_SCENES`, `PUSH_SCENE`,
  `REMOVE_SCENE`, `ALL_SCENES_PUSHED`, `ACTIVATE_SCENE`, `RAMP_SCENE_UP`, `RAMP_SCENE_DOWN`, `STOP_RAMP_SCENE`). Navigators send
  `BUTTON_ACTION` rather than `ON`/`OFF`/`TOGGLE`. The same report says `SendToProxy(5001, "LIGHT_LEVEL", 100)` **changes the UI
  state** while `LIGHT_LEVEL_CHANGED` does not - the evidence for defaulting feedback to *Both*. Control4's docs staff acknowledged
  the gaps (broken links, undocumented commands, on/off lights' 0/100 convention) and did not resolve them in that thread. Also
  reported there: `DYNAMIC_CAPABILITIES_CHANGED` does not change the UI (not used here). The light children republish on
  `GET_LIGHT_LEVEL` / `SYNCHRONIZE` and ignore the rest quietly.
- **Blind notifications** (the guide's own text, supplied by the author): `MOVING` carries `LEVEL_TARGET` (int), `RAMP_RATE` (ms to reach
  it) and an optional `LEVEL` = where the blind STARTED moving from (default: the last `STOPPED` level; it must be sent when a blind is
  interrupted or reverses, or toggle and the movement display are wrong). `STOPPED` carries `LEVEL` (where it stopped; also sets the
  general level). `SET_HAS_LEVEL` (all parameters optional) carries `HAS_LEVEL`, `LEVEL_OPEN`, `LEVEL_CLOSED`,
  `HAS_LEVEL_CLOSED_SECONDARY`, `LEVEL_CLOSED_SECONDARY`, `LEVEL_DISCRETE_CONTROL`. For blinds **without feedback** the convention is
  open = 0, closed = 2 when the blind can stop (1 when it cannot; and level 1 means "unknown state"), with `LEVEL_DISCRETE_CONTROL`
  false so a UI only ever sends the open/closed values. The blind children now follow this: level mode (open 100, closed 0) when the
  position is known, the no-feedback scheme when the cover is uncalibrated or has lost its position (`STOPPED` with LEVEL 1 = unknown),
  one `MOVING` per movement (target from the device's `target_pos`, `RAMP_RATE` from the *Full Travel Time* property scaled by the
  distance), a fresh `MOVING` starting at the current level on a reversal, nothing on progress polls, and no optimistic `MOVING` (the
  verification read reports the real movement). Parameter names written with spaces in the guide are used with underscores
  (inferred; `LEVEL_TARGET` is confirmed by the command).
- **Blind configuration notifications** (the guide's full text, supplied by the author): `SET_CAN_STOP` takes one boolean (its parameter
  name is not given); `SET_MOVEMENT` takes an int (0 open/close, 1 up-to-down, 2 down-to-up, 3 out-to-in, 4 left-to-right,
  5 right-to-left, -1 = let the dealer choose); `SET_TYPE` takes an int (0 shade, 1 group, 2 blind, 3 louver, 4 curtain, 5 shutter,
  6 blackout, 7 opaque glass, 8 awning, 9 door, 10 screen, -1 = let the dealer choose). Sending `SET_MOVEMENT` or `SET_TYPE` **disables the
  dealer's pull-down**, and a Shelly cover can be any of those things, so the blind children deliberately send neither (the dealer picks
  the type in the proxy's properties). They also send no `SET_CAN_STOP`: `<can_stop>` is declared statically, the parameter is unnamed, and
  stopping is supported. A test enforces all three. One sentence under `STOPPED` ("a Stop notification that uses the optional LEVEL
  parameter should be used if a blind is moving and changes direction") appears to be a copy of the `MOVING` note; the driver follows the
  explicit remedy under `MOVING` (a new `MOVING` whose `LEVEL` is the current position) and does not add a `STOPPED` (which would
  fire a Stopped event mid-reversal).
- **Confirmed by working blind and light drivers** (bphillips09): the blind proxy binding is connection `5001`, `facing 6`, `type 2`,
  `consumer False`, class **`BLIND`** (and the light one `LIGHT_V2`) - as generated here. The blind proxy sends `SET_LEVEL_TARGET
  {LEVEL_TARGET}`, **`UP`**, **`DOWN`**, `STOP`, `BUTTON_ACTION {BUTTON_ID, ACTION}` and, from its button-link connections, `DO_CLICK`; UP and
  DOWN are what a blind without level support receives **instead of** a level, so the blind children now handle them (they did not).
  Notification parameters, underscore spelling confirmed: `SET_HAS_LEVEL {HAS_LEVEL, LEVEL_OPEN, LEVEL_CLOSED, LEVEL_SECONDARY_CLOSED,
  HAS_LEVEL_SECONDARY_CLOSED, LEVEL_UNKNOWN, LEVEL_DISCRETE_CONTROL}` (note the secondary-level names do not follow the guide's word order;
  unused here), `SET_CAN_STOP {CAN_STOP}` (now sent), `STOPPED {LEVEL}`. `LEVEL_UNKNOWN` is a **value** (-1 there), confirming it is not a
  boolean capability. The blind XML there also declares an `always_send_level` capability (undocumented; not used here). That driver's
  no-position scheme is open 2 / closed 0 (stop supported), the guide's is open 0 / closed 2; the UI only needs `SET_HAS_LEVEL` and
  `STOPPED` to agree with each other, so both work - this driver follows the guide. Neither driver sends `MOVING`, so its `RAMP_RATE` /
  start-`LEVEL` spelling remains inferred from the guide.
- **Confirmed by the working light driver**: `SET_BRIGHTNESS_TARGET` arrives with **`LIGHT_BRIGHTNESS_TARGET`** (not only the documented
  `_LEVEL` / `_PERCENT` / `_PRESET_ID` names - this driver reads all of them); `SYNCHRONIZE` is answered with `LIGHT_BRIGHTNESS_CHANGED
  {LIGHT_BRIGHTNESS_CURRENT}`; `ONLINE_CHANGED {STATE}` is a boolean; `BUTTON_ACTION` (ACTION "2" = release; BUTTON_ID 0 on / 1 off / else
  toggle), `ON`, `OFF`, `SET_LEVEL`, `GROUP_SET_LEVEL` and `GROUP_RAMP_TO_LEVEL {LEVEL}` are all sent by the proxy (the last two need
  `load_group_support`); `DO_PUSH` / `DO_RELEASE` / `DO_CLICK` come from `BUTTON_LINK` connections (ids 200-202 there; not declared here).
  Full ALS is implemented there by storing the `ELEMENTS` XML of `PUSH_SCENE` (by `SCENE_ID`) and applying its `level` / `brightness`
  node on `ACTIVATE_SCENE` - an alternative to the reduced ALS mode chosen here. It also uses `DYNAMIC_CAPABILITIES_CHANGED`, declares the
  undocumented capability tags `has_load` and `brightness_rate_min` / `brightness_rate_max` (0 / 100000), uses `<script jit="1">`, and passes
  `true` as a fifth argument to `SendToProxy` (allow empty values); none of those are used here.
- **Blind proxy** (guide fragments + third-party live-Director notes): the proxy sends `SET_LEVEL_TARGET {LEVEL_TARGET}` (0 closed to
  100 open) and `STOP`; the driver notifies `SET_CAN_STOP`, `SET_HAS_LEVEL`, `STOPPED` (with the level it stopped at) and `MOVING` (its
  starting level defaults to the last `STOPPED` level); the proxy handles toggle itself and, while moving, sends the opposite
  `SET_LEVEL_TARGET` - so `driver_handles_toggle` stays False. Events Stopped (3) and Moving (5). The table of contents also lists
  the `can_stop`, `has_level`, `level_open`, `level_closed`, `level_unknown` capabilities.
- Relay and contact notifications and commands (`CLOSE`/`OPEN`/`TOGGLE`/`TRIGGER`, `CLOSED`/`OPENED`/`STATE_CLOSED`/`STATE_OPENED`) are
  listed in the guide as documented sections.
- A device created by `C4:AddDevice` may have no listening proxy during `OnDriverLateInit` (found on real hardware there).
  Children now replay their proxy state 4 s and 12 s after first registration (once per driver load, no events).

## Verified - device profiles (Shelly docs)

- Multi-profile devices report `profile` in `/shelly`, `Shelly.GetDeviceInfo` and `Sys.GetConfig` (`device.profile`), and have
  `Shelly.ListProfiles` / `Shelly.SetProfile` (changelog). Plus 2PM and Pro 2PM: `switch` | `cover`. Plus RGBW PM: `light` (4 x `light`),
  `rgb` (`rgb:0`), `rgbw` (`rgbw:0`). Pro RGBWW PM: `rgbcct` (`rgb:0` + `cct:0`), `cctx2` (2 x `cct`), `rgbx2light` (`rgb:0` + 2 x `light`),
  `light` (5 x `light`). Plus 1 / 1PM expose a single `switch:0`; their input mode is configuration, not a profile.
- `RGB.Set {id, on, brightness (1-100), rgb [r,g,b], transition_duration, toggle_after, offset, tag}` (at least one of `on` / `brightness`;
  returns `null`); `RGB.GetStatus` has `output`, `brightness`, `rgb`, `transition.target`. This is the same shape as `Light.Set`, so
  brightness-only control of an RGB output is a small extension. `RGBW` and `CCT` pages were not read; an `RGBCCT` component also exists.
- The driver now: records the profile at the probe; reports `rgb`, `rgbw`, `cct` and `rgbcct` components as not controllable (other
  unsupported kinds - inputs, sensors, meters - stay silent); marks components a full read no longer lists as GONE; and keeps the component
  set current from LAN reads, so a profile change is noticed without the cloud.

## Verified - alarm sensors (Shelly docs and third-party integrations)

- Gen2+ `flood:<id>` and `smoke:<id>` components: status `{id, alarm: bool, mute: bool}`. Webhook events `flood.alarm`, `flood.alarm_off`,
  `flood.cable_unplugged`; `smoke.alarm`, `smoke.alarm_off`. `Smoke.Mute {id}` exists; **a flood alarm cannot be muted through the API**
  (physical button only; third-party reports). Flood config has an alarm mode and a report hold-off that only change while the device is awake.
- Both devices are battery-powered and sleep: the Flood Gen4's button wakes it for 3 minutes and it checks the sensor about every 5 s while
  awake; the Plus Smoke wakes at `sys.wakeup_period` and publishes a full status. Neither is reachable on the LAN while asleep.
- There is **no gas component** in the Gen2+ component list; the Shelly Gas is Gen1.
- Unverified: whether the cloud `get` reports a sleeping device's last `flood:0` / `smoke:0` status and how quickly after a wake; the
  `devicepower:0` battery fields (battery level is therefore not exposed); a push path (webhook receiver or outbound WebSocket to the
  controller) that would cut latency from minutes to seconds is documented in principle but not built.

## Gen1 (Shelly 1, Flood SHWT-1, Smoke SHSM-01, Gas SHGS-1)

Verified (official Gen1 documentation snippets and consistent third-party implementations):

- `GET /shelly` is unauthenticated and returns `{type, mac, auth, fw, num_outputs}` - **no `gen` field**, which is how the probe recognises Gen1.
  Every other resource needs HTTP **Basic** authentication when login is enabled via `/settings/login`. Gen1 is plain HTTP.
- `GET /status`: `relays[] {ison, has_timer, source, timer_remaining}`, `wifi_sta {connected, ssid, ip, rssi}`, top-level `mac`. Flood:
  `flood` (bool), `bat {value, voltage}`, `is_valid`. Smoke: `smoke` (bool), `tmp`, `bat`, `act_reasons`. Gas: `gas_sensor.alarm_state`
  (`none` | `mild` | `heavy` | `test`; mild >= 1800 ppm, heavy >= 3000 ppm per a third-party template), `concentration {ppm, is_valid}`.
- Relay control: `GET /relay/<n>?turn=on|off|toggle[&timer=<seconds>]` (POST with `turn=` also works); the reply is the relay object.
- The cloud reports Gen1 devices with `gen: "G1"` and a 12-hex id (the MAC), e.g. `dc4f2276846a` with code `SHSW-1`.
- The Shelly Gas is mains-powered; the Flood and Smoke are battery devices with sleep.

Also confirmed from the Gen1 documentation's common section: `/shelly` is the only unauthenticated resource and `login` uses
`Authorization: Basic ...`; the HTTP **method is intentionally ignored** and parameters may be a query string or a form body (so
`GET /relay/0?turn=on` is the documented form); error responses are 4xx with a `text/plain` body; Shelly 1 `/relay/0` takes `turn`
(on | off | toggle) and `timer` (flip-back seconds) and answers `ison`, `has_timer`, `timer_started`, `timer_duration`, `timer_remaining`,
`overpower` (1PM), `source`. **Since firmware 1.12.1 battery sensors (H&T, Flood, Door/Window, Button1) report `null` values on a fault; a
status packet is valid only with `is_valid: true` and `sensor_error: 0`.** The parser now keeps the sensor's component but treats an
invalid read as unknown (it never sets or clears an alarm), by model: SHWT-1 flood, SHSM-01 smoke, SHGS-1 gas. The Shelly **Smoke** and **Flood** `/status` tables were then supplied as text and match the parser exactly: `is_valid` (sensor
self-check), `smoke` / `flood`, `sensor_error` (only present on error), `bat.value` (estimated remaining capacity, 0-100 %), `bat.voltage`,
`act_reasons` (battery, button, periodic, poweron, sensor, alarm), `tmp.*` (with its own `tmp.is_valid`, which is deliberately ignored), and
Flood's `rain_sensor` (Rain Mode: no buzzer, reports only when water changes). The Smoke's `sleep_mode.period` is "always 12 h", which is
why a battery sensor is reported offline only after 25 hours. The Shelly **Gas** `/status` table was supplied too: `gas_sensor.sensor_state` (unknown | warmup | normal | fault),
`gas_sensor.self_test_state` (not_completed | completed | running | pending), `gas_sensor.alarm_state` (unknown | none | mild | heavy | test -
"test" is issued after a successful self-test), `concentration {ppm 0..65535, is_valid}`, `valves[].state` (the optional valve add-on).
The parser trusts mild / heavy always, but only a NORMAL sensor may assert none / test; alarm_state "unknown" and a warming-up, faulted
or unknown sensor are "unknown" (never an all-clear), and the sensor state is exposed as a variable. The 1800 / 3000 ppm thresholds for
mild / heavy are from a third-party template, not from this table.

Unverified / not done: the exact shape of the cloud's `status` for Gen1 flood / smoke / gas devices (assumed identical to `/status`); the Gen1
cloud *control* path (so Gen1 is never commanded through the cloud); `is_valid` handling; Basic-auth edge cases on old Gen1 firmware;
CoIoT / action URLs (not used); other Gen1 relay models (the relay API is the same across the family, but only `SHSW-1` is enabled, because
a Gen1 2.5 in roller mode also reports `relays[]`).

## Verified - inputs and garage-door wiring (Shelly docs)

- `input:<id>` is the Input component: `Input.GetStatus {id, state}` where `state` is a boolean for `type: switch` and `null` for `type: button`;
  config `type` (switch | button | analog | count) and `invert`. The Plus 1's SW terminal is `input:0`; the relay is `switch:0`.
- `Switch.in_mode`: momentary | follow | flip | detached (+ cycle, activate where applicable). `detached`: the state of the input does not
  affect the switch; `follow` / `flip` make the input operate the relay. A door contact on a garage-door Shelly therefore needs `detached`.
- A pulse is `Switch.Set {on: true, toggle_after: s}` (device-side flip back); the Gen1 equivalent is `GET /relay/N?turn=on&timer=s`.
- Done: `input:N` with a boolean `state` (type switch) and Gen1 `inputs[].input` (0 | 1) are read as OPTIONAL contacts; `button` inputs
  (state null) are ignored.
- Shelly **Door/Window 1/2** (Gen1; documentation page and a published device dump): `/status` has `is_valid` (top level) and
  `sensor {state: "open" | "close", is_valid}`, `lux {value, illumination, is_valid}`, `accel {tilt 0..180, vibration}`, `bat {value, voltage}`,
  `act_reasons`; `/settings` has `sleep_mode_period` (hours, 1..24), `reverse_open_close` and tilt/vibration switches. Used: `sensor.state`,
  both validity flags, `bat.value`. Models SHDW-1 / SHDW-2. (The BLU Door/Window is BLE/BTHome and is not supported.)
- Unverified: whether the cloud's Gen1 `status` for these devices equals `/status`; reed polarity on a real device (the "Invert Contact" property
  exists for that); the Gen2 `input` status on a Shelly 1 Gen4/Plus 1 on real firmware.

## Found wrong and fixed (2026-09-30)

- A `Light.Set` starts a transition, and the status shows the moving level with the final one in `transition.target`.
  We now read the target, so the post-command verification no longer reports a false disagreement.
- Calibration for covers is `pos_control`, not "has a position": a calibrated cover can report `current_pos: null`
  after a power cut. Numeric levels are refused with an accurate message; open/close/stop still work (they re-reference it).
- Uncalibrated dimmers (`flags: ["uncalibrated"]`) reject brightness with error -109. Only on/off is offered.
- A 200 response that is not JSON is no longer treated as success (only `null` or empty is).
- HTTP 429 from a device is a transient "unreachable", not a device error.
- The digest realm is checked against the expected device **before** answering a challenge, so a different device at a
  re-used address never receives (or counts) a login attempt.
- `enhanced_security: true` in the probe switches the device to HTTPS straight away.
- Add Device By ID accepts several ids, and Fetch Devices now fails with a pointer to it.

## Still unverified - and newly found risks

- **Device listing.** `/device/all_status?show_info=true&no_shared=true` is documented - on the **Real Time Events** page,
  which specifies `data.devices_status` keyed by device with a `_dev_info {id, gen, code, online}` object (`gen` is "G1",
  "G2", "V1" for virtual devices, "GBLE" for BLE; ids are hex, zero-padded to 6 or 12 characters, compare case-insensitively;
  ignore the map keys). That matches `parse.lua`. What is **not** confirmed is authentication: the page documents an OAuth
  `Authorization: Bearer` token, whereas this driver sends the account's authorization key as the `auth_key` query
  parameter (as the v2 control API documents). Whether `all_status` accepts `auth_key` is unverified from the docs.
  The page also says Shelly deliberately leaves most HTTP endpoints undocumented and may change them. Add Device By ID
  (documented v2 `get`) is the fallback and needs no listing.
- The v2 control API is labelled **beta**.
- Real Time Events also offers a push WebSocket (`Shelly:StatusOnChange`, `Shelly:Online`), but only via an OAuth browser
  login, which a dealer-installed driver cannot do; the Integrator API needs a licensed integrator account ("licenses for
  personal use are not provided"). Neither is used.
- Cloud response bodies for `status` beyond `sys` (light/cover/`wifi.sta_ip`) and the 429 format of the cloud.
  The deprecated API's status example does include `wifi.sta_ip`.
- The redirect `Location` value of an Enhanced-Security device (we accept only `https://<same address>...`).
- Devices that require a client certificate (mutual TLS) cannot be controlled; devices behind a Shelly range extender use
  a custom TCP port, which we do not support (Home Assistant has a Port option for this).
- Whether `toggle_after` is honoured on every model; real lockout behaviour on old firmware.
- Proxy material: the spelling `RAMP_RATE` and the start `LEVEL` of `MOVING` (neither reference driver sends `MOVING`). Everything else about
  the light and blind proxies is now documented or confirmed by a working driver.
- Control4 side, still unverified: the `follow_redirects` option name (the adapter takes the last response, so it works either
  way, but a cross-host redirect would then be followed silently); the items above; the `OnBindingChanged` parameter order; `C4:RenameDevice(deviceId, name)` argument order; whether a Door-Lock-style consumer shows
  the relay's commanded or its confirmed state (the Ultra notes say the tile reflects what was commanded); whether `AddVariable`
  is allowed in `OnDriverInit` (Snap One says `AddEvent`/`FireEvent` are not; this driver uses static events and fires none there).
- Real latency, HTTPS handshake cost per request on the device and on the controller (HTTP has no keep-alive), and
  controller CPU at scale.

## M0 checklist (do first on real hardware)

- Capture and commit fixtures: `/shelly` (http and https), `Shelly.GetStatus` per component type incl. a light mid-transition
  and an uncalibrated cover, each control result (`null`), a digest challenge/response on old and new firmware, a 429, a
  cloud `get`, a cloud error, and whatever the listing endpoint returns today.
- Confirm the redirect `Location` from an Enhanced-Security device.
- Confirm the remaining Control4 items above on a real controller, and proxy behaviour in the Navigator.
- Measure round trips, HTTPS cost and CPU at 40 devices.
