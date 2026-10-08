> **Implementation status (2026-09-30):** this document is the design agreed before the build. The code differs in a few
> places - see [IMPLEMENTATION-NOTES.md](IMPLEMENTATION-NOTES.md), which wins where they disagree. Passages that changed carry an
> *Implementation note*.

# C4-ShellyHybrid — Specification

A lean Control4 driver set for Shelly devices. **The Shelly Cloud provisions;
the LAN executes.** Devices are listed and addressed through the Shelly Cloud
Control API (authorization key), and from then on commands and feedback go
directly to each device over the local network. The cloud remains as inventory
source, address-refresh source, and fallback path.

> **Status: specification (pre-implementation).** Nothing described here is
> built yet. Every statement about Shelly is tagged with how well it is
> established:
>
> - **[Documented]** — stated in Shelly's own documentation.
> - **[Undocumented]** — works for community tools but is not in Shelly's
>   documentation; may change without notice.
> - **[Unverified]** — inferred, remembered, or reported inconsistently by
>   different sources; must be confirmed against real hardware in milestone M0
>   before anything depends on it.
> - **[Decision]** — a choice made by this project, not a fact about Shelly.
>
> Internal structure and reasoning: [ARCHITECTURE.md](ARCHITECTURE.md).

## 1. Purpose

Give Control4 integrators a small, understandable way to bring common Shelly
hardware — lighting circuits, dimmers, relays and shutters — into a Control4
project with **one credential and no per-device typing**, while keeping
day-to-day control **local, fast and independent of the internet**.

"Lean" is a requirement. The reference point is Chowmain's *Shelly Generic*
suite, which covers Gen1 through Gen4, BLU/BTHome, virtual components,
thermostats, sleepy devices, LAN discovery and licensing. This project does
**less** on purpose: five drivers, no licensing layer, no LAN scanning, and
behaviour that is predictable from the tables in §5 and §7.

### Why hybrid

| Path | Strength | Weakness |
| --- | --- | --- |
| Cloud only | One credential, no network work, works across networks | 1 request/second per account, internet-dependent, polled feedback |
| LAN only | Fast, no rate limit, works offline | Needs discovery, addresses, and per-device setup |
| **Hybrid (this spec)** | Cloud removes the setup work; LAN removes the runtime limits | Two transports to build, and LAN reachability/security to handle |

## 2. Goals and non-goals

### Goals

1. **Setup from one credential.** Enter the Shelly server and authorization
   key once; devices, components and **LAN addresses** come from the cloud and
   turn into Control4 drivers with one action.
2. **Local execution.** Once a device's address is known, control and
   feedback do not depend on the internet or on the cloud's rate limit.
3. **Native Control4 behaviour** for dimmable lights, on/off lights, relays
   and shutters, through Control4's own proxies.
4. **Graceful degradation.** If a device cannot be reached locally, the driver
   falls back to the cloud for that device, and says so. If the cloud is
   unreachable, local control continues.
5. **Honest state.** Unknown or stale values are shown as unknown. Nothing is
   invented to look responsive.
6. **Never harm a device.** In particular, never provoke Shelly's failed-login
   lockout, and never send a command to a device other than the intended one.
7. **Diagnosable.** The log and a few properties say which layer is
   responsible: Control4, driver, LAN, device, internet, or Shelly cloud.

### Non-goals (v1)

- LAN discovery of any kind (mDNS, subnet scan, broadcast). Addresses come
  from the cloud or from manual entry.
- Gen1 devices, BLU/BTHome, sleepy/battery devices, TRV/thermostats,
  smoke/flood/gas sensors, energy meters as first-class devices.
- Push feedback over WebSocket (planned extension, §12). v1 polls the LAN.
- Physical input / button events (require push).
- RGB / colour / colour-temperature and effects.
- Licensing, trials, auto-update or telemetry.
- Anything safety-critical (§10).

## 3. Target environment

| Item | Requirement |
| --- | --- |
| Control4 OS | 3.3.0 or later **[Decision]** (Light V2 proxy). `C4:AddDevice` needs 3.2.0 |
| Composer | Composer Pro |
| Shelly devices | Gen2 and later (Plus, Pro, Gen3, Gen4) with `switch`, `light` or `cover` components **[Decision]**. Gen1 is unsupported |
| Shelly account | One account per customer site; devices added to the cloud and online |
| Internet | Required for setup and address refresh; **not** required for steady-state control once addresses are known |
| **LAN reachability** | The controller must be able to open TCP connections to each device's IP on port 80 and/or 443. Segmented networks need a firewall rule for Controller → Shelly VLAN. Shelly's own network guidance lists Admin → Shelly on TCP 80/443 as the intended flow |
| Addressing | DHCP **reservations** for all devices are strongly recommended; the driver self-heals if they are absent (§6.2) but does so at a cost |

## 4. Deliverables

Five `.c4z` packages from one repository:

| Package | Purpose | Control4 proxy |
| --- | --- | --- |
| `shelly_hub.c4z` | Account credential, device inventory and address book, both transports, scheduling, child creation | none (protocol driver) |
| `shelly_light.c4z` | Dimmable light | `light_v2` |
| `shelly_light_onoff.c4z` | Non-dimmable light | `light_v2` (dimmer capability off) |
| `shelly_relay.c4z` | Generic relay | none: Control4 treats relays as a non-proxy device with a `RELAY` connection (Appendix A) |
| `shelly_blind.c4z` | Shutter / cover | `blind` |

**[Decision]** One hub per Shelly account. Children never touch the network;
all transport, credentials and scheduling live in the hub. The cloud's rate
limit is per account, and LAN concurrency limits are per device, so a single
scheduler that sees every request is the only way to honour both.

## 5. Device and component mapping

The unit of mapping is a **component**, not a device.

| Component (Gen2+) | Cloud control (fallback) | LAN method | Child driver |
| --- | --- | --- | --- |
| `switch:N` | `POST /v2/devices/api/set/switch` | `Switch.Set {id, on}` | Light On/Off or Relay (§8.1) |
| `light:N` | `POST /v2/devices/api/set/light` | `Light.Set {id, on, brightness}` | Light |
| `cover:N` | `POST /v2/devices/api/set/cover` | `Cover.GoToPosition {id, pos}` / `Cover.Open` / `Cover.Close` / `Cover.Stop` | Blind |

Cloud endpoints **[Documented]**. LAN method names **[Documented]** in
Shelly's Gen2+ component reference and RPC channel pages (the switch example
appears verbatim there), but parameter details for `Light.Set` and `Cover.*`
and every status field name (`output`, `brightness`, `state`, `current_pos`)
are **[Unverified]** until captured from live devices in M0.

Unsupported components (`cct`, `rgb`, `rgbw`, `input`, `em`, `pm1`,
`temperature`, …) are listed in the inventory as *unsupported* and never
become drivers. They are reported, not hidden.

## 6. Functional requirements

### 6.1 Setup (cloud-provisioned)

| ID | Requirement |
| --- | --- |
| FR-S1 | The hub accepts **Server** and **Authorization Key** (password-type, never logged) |
| FR-S2 | Server is normalised and **must match `*.shelly.cloud`**; anything else is refused, so the key cannot be sent to another host |
| FR-S3 | **Test Connection** performs one cloud read and reports: OK, bad key, wrong server, unreachable, rate limited |
| FR-S4 | **Fetch Devices** lists the account's devices and components through the undocumented listing endpoints (§7.1.3) and records, for each device, its **model, generation, name, online flag and LAN address** (Wi-Fi `sta_ip`, or the Ethernet address for wired models) **[Unverified field names]**. If the listing fails, the driver says so and points at FR-S5 |
| FR-S5 | **Add Device By ID** reads one device through the documented v2 read call, discovers components and the address from its status, and adds it. This path uses **only documented cloud endpoints**. A manual **address override** per device is also accepted (FR-S9) |
| FR-S6 | **Auto-Setup** creates one child per supported component that has none, using `C4:AddDevice`, in the **Default Room**. User-initiated only (Control4 says these APIs must not run without user interaction), idempotent, never duplicating |
| FR-S7 | Each child is configured by the hub: device ID, component, channel, name, model. **The LAN address never has to be typed** |
| FR-S8 | Auto-Setup never renames an existing driver. Names come from Shelly channel/device names, else `<model> <last 4 of ID> ch N` |
| FR-S9 | An installer may set an **Address Override** on a child or in the hub's device table for devices whose cloud-reported address is wrong or unavailable. An override always wins over the cloud value |
| FR-S10 | The inventory keeps devices that vanish from the cloud, flagged *missing*; it never deletes a Control4 driver. **Purge Missing Devices** removes only inventory entries that have no child |
| FR-S11 | After setup, a **LAN Test** action probes every device (§7.2.2) and reports for each: reachable, scheme (HTTP/HTTPS), authentication required, identity match, round-trip time |

### 6.2 Transport selection and self-healing

| ID | Requirement |
| --- | --- |
| FR-T1 | For each device the hub holds a **route**: LAN (address known and healthy), Cloud (LAN unavailable), or Unreachable. Routes are per device, not global |
| FR-T2 | A command goes over the LAN whenever the device's LAN state permits it. The cloud is used only when the LAN path has failed for that device **and** Cloud Fallback is on **and** the cloud is connected **and** the cloud reports the device online |
| FR-T3 | The last known address of every device is persisted, so after a controller reboot LAN control works **immediately, with the internet down** |
| FR-T4 | Consecutive LAN failures move a device Up → Degraded → Down. Down devices are re-probed with back-off (15 s, 30 s, 60 s, capped at 300 s) |
| FR-T5 | On entering Down, the hub refreshes that device's address from the cloud (rate-gated). If the address changed, the LAN state restarts at *probing* |
| FR-T6 | **Identity is verified.** Every LAN status read must report the expected device identity. A mismatch (an address reassigned by DHCP) marks the device Down, discards the address, and forces a cloud refresh. Commands are never assumed to have reached the right device without a recent identity match. The hub property **Identity Check** (§8.1) sets how recent: *Standard* re-probes when the last match is older than 3× the LAN poll interval; *Strict* probes before every command. The log explains the residual risk when authentication is off (§10) |
| FR-T7 | The LAN scheme (plain HTTP, HTTP→HTTPS redirect, HTTPS only) is **detected per device and remembered**, not configured (§7.2.3) |
| FR-T8 | Failing over from LAN to cloud for a command that may already have reached the device is safe because every command is an **absolute** set (FR-C2); the driver never falls back with a relative or toggle command |

### 6.3 State and feedback

| ID | Requirement |
| --- | --- |
| FR-F1 | LAN devices are read on a **staggered** cycle (**LAN Poll Interval**, default 20 s, minimum 5 s). Reads are spread evenly across the interval rather than fired together |
| FR-F2 | After a successful command, one LAN verification read follows after a short delay (~500 ms **[Unverified]**); the child is told what the device reported, not what was requested |
| FR-F3 | A polled value that disagrees with a just-issued command is ignored during a short **hold period** (ARCHITECTURE "State reconciliation") |
| FR-F4 | Cloud reads (10 devices per request) run at a slow **Cloud Check Interval** (default 300 s) for health, address freshness and `online` flags, and at a faster interval (default 60 s) **only for devices whose route is Cloud** |
| FR-F5 | Offline devices (LAN Down and cloud `online: 0`) show offline in their children; the last level is retained but marked stale |
| FR-F6 | On cold start, hub reload and after failures, state is **Unknown** until a read succeeds. It is never defaulted to off or closed |
| FR-F7 | Proxy notifications are sent only when a value changed |
| FR-F8 | A cover in motion is read at a faster, bounded LAN cadence (~1–2 s) until it reports stopped |

### 6.4 Control

| ID | Requirement |
| --- | --- |
| FR-C1 | **Light:** on, off, toggle, level (0–100). Level 0 is sent as off; > 0 as on with brightness |
| FR-C2 | **The driver never sends toggle or relative commands.** Toggle is resolved from known state into an absolute set; toggle with Unknown state is refused with a reason |
| FR-C3 | **Blind:** open, close, stop, level 0–100 (0 closed, 100 open). Numeric position is offered only for calibrated covers. The driver never triggers calibration |
| FR-C4 | **Ramp rate:** Light V2 ramp requests are executed as an immediate set unless M0 confirms a LAN transition parameter (`Light.Set` transition duration **[Unverified]**), in which case the LAN path honours it and the cloud fallback does not. The behaviour in force is logged once per load |
| FR-C5 | Rapid changes to the same target (a slider drag) are coalesced per target: only the newest waiting value is sent |
| FR-C6 | **LAN scenes run in parallel** up to the concurrency limits in FR-C9, so an N-light scene with different values is not serialised at one per second. Cloud-fallback commands are still serialised and, where identical, merged into group requests |
| FR-C7 | A command to a device known offline fails immediately with a visible reason |
| FR-C8 | A command is confirmed, failed with a reason, or `UNVERIFIED`. Never "success" on the strength of a request merely sent |
| FR-C9 | **Concurrency limits:** at most **one** in-flight LAN request per device (Shelly documents a limit of six simultaneous non-persistent RPC channels per device, shared with everything else talking to it), and at most **three** in flight across the hub **[Decision]** to bound controller CPU |

### 6.5 Errors and recovery

| ID | Requirement |
| --- | --- |
| FR-E1 | **Authentication failure never retries.** A LAN credential rejection stops LAN traffic *to that device* until the password changes or the installer runs **Test LAN**. Shelly documents exponential back-off and lockout after failed logins on newer firmware, and a retry loop would lock the device out |
| FR-E2 | A normal digest challenge (401 with a nonce) on an unauthenticated first request is **not** a failure. Only a rejection of *supplied* credentials counts |
| FR-E3 | Cloud authentication failure stops **all cloud traffic** until the key changes. LAN control continues |
| FR-E4 | Cloud 429 triggers back-off (5 s, 10 s, 20 s, cap 60 s) on the cloud queue only |
| FR-E5 | LAN timeouts and connection failures count toward FR-T4. They are retried once for absolute commands, then fall back per FR-T2 |
| FR-E6 | An RPC error from a device that *answered* (bad channel, wrong profile) is a configuration problem: reported, not retried, not failed over |
| FR-E7 | Connectivity is summarised as one hub status (LAN / Cloud) plus a per-device route; one outage produces one log line, not one per device |

### 6.6 Diagnostics

| ID | Requirement |
| --- | --- |
| FR-D1 | **Log Level** Error / Warning / Info / Debug; Debug adds request/response traces |
| FR-D2 | The cloud key **and every device password** are redacted from every log path, property and error string, including URLs and headers |
| FR-D3 | **Recent Activity**: newest five shown, twenty-five kept; **List Recent Activity** prints all |
| FR-D4 | **List Devices** prints, per device: ID, model, components, address and its source (cloud / override), route, LAN state, scheme, auth on/off, last identity check, cloud online flag, owning children |
| FR-D5 | **Last Command Result** on hub and children, including which route carried the command |
| FR-D6 | Debug level exposes queue depth, requests/minute (cloud), in-flight LAN count, and per-device consecutive-failure counts |

### 6.7 Child events and proxy conformance

Each child drives a Control4 proxy (or, for the relay, a non-proxy connection).
The proxy, not the driver, fires most programming events and owns most
variables, **but only in response to the notifications the driver sends**. A
child that sends the wrong notification, or none, produces a UI that renders
yet never triggers programming. These requirements make the notification
contract explicit. The full tables are in §8.3.

| ID | Requirement |
| --- | --- |
| FR-P1 | Every child implements **every proxy notification that feeds a proxy event or variable** listed for its type in §8.3, and no others. Nothing is sent that the driver cannot back with a confirmed value |
| FR-P2 | **A proxy event fires only for a real change.** The driver sends a state notification only when the confirmed value differs from the last one published (FR-F7). Polls, verification reads and cloud/LAN route switches that report the same value send nothing |
| FR-P3 | **Unknown is never published as a value.** While a component's value is unknown the child sends no level, position or open/closed notification. It sends the type's *offline/unknown* signal instead (§8.3) and sends the real value once, when first known |
| FR-P4 | **Startup.** When the first value becomes known after a load, the child publishes it as the proxy's initial state (light `LIGHT_BRIGHTNESS_CHANGED`, relay `STATE_CLOSED`/`STATE_OPENED`, blind `STOPPED` with level) so it is not mistaken for a change by programming |
| FR-P5 | **A command that is accepted but not yet confirmed** is announced with the type's *in-progress* notification (light `LIGHT_BRIGHTNESS_CHANGING`, blind `MOVING`) and completed with the *final* notification (`LIGHT_BRIGHTNESS_CHANGED`, `STOPPED`) when the device acknowledges or a read confirms |

> *Implementation note:* lights send only `LIGHT_BRIGHTNESS_CHANGED` (no CHANGING): Shelly commands are instantaneous. The UI is updated when the hub reports success and corrected by the read-back; a failure or 20 s timeout snaps it back. Blinds still send `MOVING` then `STOPPED`.
| FR-P6 | **Toggle is resolved by the proxy or the driver, never forwarded.** The blind driver leaves `driver_handles_toggle` false so the proxy converts toggle into level targets. The light and relay drivers resolve a received `TOGGLE` from known state into an absolute command; toggle with Unknown state is refused |
| FR-P7 | **Driver-defined events and variables use reserved ID ranges** (§8.3.5) that cannot collide with any proxy-defined event or variable ID. The IDs are fixed in the generator and pinned by a test. An ID, once released, is never reused or renumbered |
| FR-P8 | Driver-defined events fire on **transitions between known states only**. The first transition after a load out of Unknown is silent, so a controller reboot does not fire "Device Online" for every device |
| FR-P9 | *Device Offline* fires only after the device has been unreachable by every route for 60 s (**Offline Debounce**, constant) **[Decision]**. *Device Online* fires on the first confirmed read after a fired *Device Offline* |
| FR-P10 | A recording test double for each proxy asserts the exact sequence of notifications for the scenarios in §13 (start-up, command, disagreement, offline, recovery, DHCP change) |

## 7. API contracts

### 7.1 Cloud Control API (provisioning, address refresh, fallback)

#### 7.1.1 Credentials and limits

**[Documented]** Key and server host come from the Shelly app (user settings →
authorization cloud key). The key changes when the account password changes;
the host can change. Requests are limited to **1 per second**; community
clients report 429s on bursts and pad to ~1.2 s.

**[Decision]** One cloud request in flight, ≥ 1.2 s between starts, hub-wide.
Because the cloud is no longer the main control path this limit affects
setup, refresh and fallback — not normal operation.

#### 7.1.2 Endpoints

| Purpose | Request | Status |
| --- | --- | --- |
| Read state (≤ 10 devices) | `POST /v2/devices/api/get` `{ids, select:["status"], pick:{…}}` | Documented |
| Switch / Light / Cover | `POST /v2/devices/api/set/{switch,light,cover}` | Documented |
| Groups | `POST /v2/devices/api/set/groups` | Documented |
| List devices | `POST /interface/device/list` | Undocumented; shape Unverified |
| All statuses | `POST /device/all_status` | Undocumented; shape Unverified |

Legacy v1 endpoints are deprecated and **not used**.

#### 7.1.3 Where the LAN address comes from

The cloud status sample for a Gen2 device includes a Wi-Fi block with
`sta_ip` **[Documented in sample response]**. Wired (Ethernet) models are
expected to report their address in an Ethernet block **[Unverified]**. Whether
`pick` can select these blocks without pulling the whole status is
**[Unverified]**. If the cloud does not report an address for a device, the
device stays on the cloud route until an **Address Override** is set (FR-S9).

#### 7.1.4 Not available

There is no push channel with an authorization key; the real-time WebSocket
needs OAuth tokens. This is why **LAN** polling, not cloud, provides feedback.

#### 7.1.5 Error handling

| Response | Driver action |
| --- | --- |
| 200 | Success (control calls); check `failedCommands` for groups |
| 400 `DEVICE_OFFLINE` | Mark cloud-offline; no retry |
| 400 `DEVICE_FAILED_COMMAND` / `INVALID_MODE` / `INVALID_CHANNEL` | Report; configuration or device fault |
| 400 `BAD_REQUEST` | Driver bug; log at Error with redacted request |
| 404 `DEVICE_NOT_FOUND` | Mark missing |
| 404 `INSTANCE_NOT_FOUND` | Cloud degraded; suggest re-checking Server |
| 500 `UNEXPECTED_SUBSERVICE_ERROR` | One retry for absolute commands |
| 429 | Back-off (FR-E4) |
| 401 / 403 | Stop all cloud traffic (FR-E3) |

Exact shape of an invalid-key response is **[Unverified]**.

### 7.2 Device LAN API (execution and feedback)

#### 7.2.1 Channel and methods

**[Documented]** Gen2+ devices accept JSON-RPC over HTTP: `POST /rpc` with a
full request frame, or `POST /rpc/<Method>` with the parameters as the body.
A WebSocket at `/rpc` also exists (used by Home Assistant and other clients)
and is the basis of the §12 extension.

Methods used: `Switch.Set`, `Light.Set`, `Cover.GoToPosition`, `Cover.Open`,
`Cover.Close`, `Cover.Stop`, and `Shelly.GetStatus` for feedback. Component
`*.GetStatus` methods are an option if `Shelly.GetStatus` proves too heavy
for the controller **[Decision pending M0 measurement]**.

**[Decision]** Requests are `POST /rpc/<Method>` with a JSON body, never
query-string forms, so parameters are never embedded in URLs or logs.

#### 7.2.2 Probe

Before a device is used, and on every re-probe, the hub requests the
unauthenticated device-info endpoint (`/shelly`, or `Shelly.GetDeviceInfo`;
both are documented as exempt from authentication). The response is used to
confirm **identity** (device ID / MAC matches the expectation), generation,
firmware and whether authentication is enabled. The exact fields returned are
**[Unverified]** until captured.

A probe is safe: it carries no credentials, so it cannot trip a failed-login
counter.

#### 7.2.3 Scheme: HTTP, HTTPS, redirect

Sources **disagree** and the behaviour is version-dependent, so it is
detected, not assumed:

- Shelly's network guide describes firmware 1.8 as enforcing HTTPS on port
  443, redirecting port 80 to it, requiring `wss://`, and issuing each device
  a certificate from a private Shelly CA.
- Shelly's HTTPS page and Home Assistant's documentation place this under
  **firmware 2.0.0**, and state that devices *shipped* with 2.0.0 or later
  have HTTPS enabled with factory certificates, while devices merely
  *updated* to 2.0.0 keep serving plain HTTP by default.

**[Decision]** The hub tries the remembered scheme, then plain HTTP, then
follows a redirect to HTTPS, and stores the working scheme per device.
Supporting all three states is a requirement, not an option.

**TLS verification on the LAN:** the controller will not trust Shelly's
private CA by default. **[Decision]** A hub property **LAN TLS Verification**
defaults to *Off* (encrypted, but the device is not authenticated by
certificate) and can be set to *On* by an installer who has arranged trust.
Whether `C4:url` can load a custom CA is **[Unverified]**. The cloud
connection is always verified.

#### 7.2.4 Authentication

**[Documented]** When enabled on a device, HTTP and WebSocket access is
protected by digest authentication using **SHA-256** (RFC 7616); the user is
`admin`; the realm is the device identifier; `Shelly.GetDeviceInfo` and
`/shelly` are exempt. Firmware before 2.0.0 uses a documented "legacy" variant
of the challenge/response; the differences are **[Unverified]** and must be
captured on both.

Control4's `C4:url` does not necessarily implement SHA-256 digest
**[Unverified]**, so the driver implements it directly on top of `C4:Hash`
(SHA-256 is a supported digest). The first request to a protected device
receives a 401 with a challenge; that is normal (FR-E2).

Credentials: one hub-level **Device Password** (username fixed `admin`) with
an optional per-child override. Passwords are stored encrypted and redacted
everywhere (FR-D2).

**Lockout:** Shelly's network guide lists exponential back-off on failed logins
(10 s → 30 s → 60 s → 5 min) and account lockout in newer firmware. FR-E1 is
therefore a hard requirement.

#### 7.2.5 Limits

Six simultaneous non-persistent RPC channels per device, shared with the
Shelly app, scripts and any other integration on the network **[Documented in
Shelly's network guide, citing the RPC channels specification]**. FR-C9 keeps
this driver to one.

#### 7.2.6 Errors

| Condition | Meaning | Action |
| --- | --- | --- |
| Connect refused / timeout / reset | Unreachable or wrong address | Count toward Degraded/Down; retry once (absolute); fall back |
| HTTP 401 with challenge, no credentials sent | Authentication required | Retry once **with** credentials |
| HTTP 401/403 after credentials sent | Wrong password (or locked out) | Auth stop for this device (FR-E1) |
| JSON-RPC `error` object | Device answered but refused | Report; do not retry or fall back (FR-E6) |
| Identity mismatch | Wrong device at this address | Down; discard address; cloud refresh (FR-T6) |
| TLS failure | Certificate or protocol problem | With verification off, treat as Down and log the reason |

### 7.3 Routing summary

| Situation | Control | Feedback |
| --- | --- | --- |
| Device LAN Up | LAN | LAN poll |
| LAN Degraded | LAN (one retry) → cloud fallback | LAN poll continues |
| LAN Down, cloud online | Cloud (rate-gated) | Cloud poll (60 s) + re-probe LAN with back-off |
| LAN Down, cloud offline/unreachable | Fails with reason | Unknown/Offline |
| LAN Auth-stopped | Cloud fallback if allowed; message says why | Cloud poll |
| Internet down | LAN (unaffected) | LAN poll (unaffected) |

## 8. Properties, actions and events

The property grid redraws on every write and renders long values badly
(learned in the C4-PimaForce driver), so nothing large lives in a property.

### 8.1 Hub — `Shelly Hub`

| Property | Type | Notes |
| --- | --- | --- |
| Driver Version | read-only | |
| Cloud Status | read-only | Connected / Degraded / Offline / Auth failed / Not configured |
| LAN Status | read-only | `18 up, 1 degraded, 1 down, 0 auth-stopped` |
| Server | string | Validated per FR-S2 |
| Authorization Key | password | Never logged |
| Device Password | password | Optional; `admin` user; used only when a device requires authentication |
| LAN Poll Interval (s) | integer | 20 default, 5–300 |
| Cloud Check Interval (s) | integer | 300 default, 60–3600 |
| Cloud Fallback | list | On (default) / Off |
| LAN TLS Verification | list | Off (default) / On |
| Identity Check | list | `Standard` (default): re-probe when the last identity match is older than 3× LAN poll interval. `Strict`: probe before every command that is not preceded by a match in the last 2 s (one extra round trip, no credentials, safe to repeat) |
| Default Room | list | Where Auto-Setup places drivers **[Unverified]** |

> *Implementation note:* Default Room ID is an integer property (the room's ID in Composer).
| Switch Default Type | list | `Light On/Off` (default) / `Relay` |
| Devices | read-only | `12 devices, 17 components, 15 assigned` |
| Log Level | list | |
| Last Command Result | read-only | |
| Recent Activity | read-only | Newest 5 |

| Action | Effect |
| --- | --- |
| Test Connection | FR-S3 |
| Fetch Devices | FR-S4 |
| Add Device By ID | FR-S5 (uses *Manual Device ID* / *Manual Address* properties) |
| Auto-Setup | FR-S6 |
| Test LAN | FR-S11; also clears auth stops |
| Refresh Addresses | Forces a cloud address refresh for all devices |
| Poll Now | Immediate LAN + cloud read |
| List Devices / List Recent Activity | Print to Lua Output |
| Purge Missing Devices | FR-S10 |

| Event | Fires when |
| --- | --- |
| Cloud Connected / Cloud Lost | Cloud status change |
| Authentication Failed (Cloud) | Key rejected |
| Device Authentication Failed | A device rejected the LAN password |

### 8.2 Children (all four)

| Property | Notes |
| --- | --- |
| Shelly Device ID / Component / Channel / Model | Set by the hub; read-only |
| Address | Effective address and source (`192.168.1.40 (cloud)`); read-only |
| Address Override | Optional string; wins over cloud value (FR-S9) |
| Device Password Override | Optional password for this device |

> *Implementation note:* not implemented; there is one hub-wide Device Password.
| Route | LAN / Cloud / Unreachable |
| Connection Status | Online / Offline / Unknown / Hub missing |
| Hub Device ID | read-only |
| Last Command Result | Includes route used |
| Log Level | |

Type-specific: **Relay** *Invert* (default off; Control4 "closed" = Shelly on
**[Decision]**). **Blind** *Control Type*, *Movement Time (s)*. **Light**
*Minimum Brightness*.

Driver-defined events and variables: §8.3.4. Everything else that appears in
Composer programming for a child (brightness, level, moving, open/closed) is
owned by its proxy and driven by the notifications in §8.3.1–8.3.3.

### 8.3 Proxy events, variables and the notifications that drive them

Sources: Control4's DriverWorks Proxy and Protocol Guide (Light V2, Blind,
Relay). Notification and event names are **[Documented]**; how each behaves on
the target OS is **[Unverified]** until exercised on a controller in M2/M3.

#### 8.3.1 Light and Light On/Off (`light_v2`)

Proxy-owned events (fired by the proxy in response to our notifications):

| Event | ID | Fires when we send |
| --- | --- | --- |
| Light On | 5100 | `LIGHT_BRIGHTNESS_CHANGED` moving from 0 to > 0 |
| Light Off | 5101 | `LIGHT_BRIGHTNESS_CHANGED` moving to 0 |
| Light Brightness Changing | 4000 | `LIGHT_BRIGHTNESS_CHANGING` |
| Light Brightness Changed | 4001 | `LIGHT_BRIGHTNESS_CHANGED` |
| Old Light Level Changed | 5000 | legacy path; not used by this driver |
| Colour and keypad-button events | 4002, 4003, 5001+ | not applicable (no colour, no buttons). `hide_proxy_events` is left off so the brightness events are available to programmers |

Proxy-owned variables: Light State 1000, Brightness Percent 1001, and the
target/ramp variables 1120–1121 (enabled by `supports_target`).

Notifications this driver sends:

| Situation | Notification |
| --- | --- |
| Value first known / confirmed by a read | `LIGHT_BRIGHTNESS_CHANGED { LIGHT_BRIGHTNESS_CURRENT }` (0–100; on/off lights send 0 or 100) |
| Command accepted, awaiting acknowledgement | `LIGHT_BRIGHTNESS_CHANGING { CURRENT, TARGET, RATE }` (RATE is 0 unless a LAN transition is honoured, FR-C4) |
| Device acknowledged by LAN reply, or a read confirms | `LIGHT_BRIGHTNESS_CHANGED` |
| Verification disagrees | `LIGHT_BRIGHTNESS_CHANGED` with the device's value (a corrective change is a real change) |
| Unknown or offline | `ONLINE_CHANGED { STATE=false }` (the proxy starts online, so this is sent at load, then `true` with the first value) |
| **Never sent** | `LIGHT_LEVEL` (documented as avoided from OS 3.3.0); incremental level updates during a ramp |

Commands received: `SET_BRIGHTNESS_TARGET` (`LIGHT_BRIGHTNESS_TARGET`, `RATE`
with `supports_target` on), `TOGGLE`, `ON`/`OFF` as the proxy sends them.
Capabilities: `dimmer` true (Light) or false (On/Off), `set_level` true,
`on_off` true, `supports_target` true.

#### 8.3.2 Blind (`blind`)

Proxy-owned events: Open (1), Fully Closed (2), Stopped (3), Fully Opened (4),
Moving (5), Level_Changed (6), Level_Target_Changed (7), Opening (8),
Closing (9). Proxy-owned variables: Open 1000, Fully Closed 1001, Stopped
1002, Fully Open 1003, Level 1004, Target Level 1005, Type 1006, Movement
1007, Opening 1008, Closing 1009.

| Situation | Notification |
| --- | --- |
| Load | `SET_CAN_STOP { true }`, `SET_HAS_LEVEL { HAS_LEVEL=true, LEVEL_OPEN=100, LEVEL_CLOSED=0, LEVEL_DISCRETE_CONTROL=<calibrated> }` |
| Position first known / confirmed while stopped | `STOPPED { LEVEL }` |
| Movement commanded | `MOVING { LEVEL_TARGET, RAMP_RATE, LEVEL }` where `RAMP_RATE` is the estimated travel time in ms and `LEVEL` is the position it started from (mandatory when reversing; the driver reads the device first so the value is real, as the Control4 guide requires) |
| Read shows the cover stopped | `STOPPED { LEVEL }` with the device's reported position |
| Position unknown or offline | `STOPPED { LEVEL=<level_unknown> }`; **never** a fabricated 0 (§ARCHITECTURE Blinds) |

The proxy requires `Stopped` to be false while moving and true when done, so
the driver never sends `STOPPED` mid-travel. `MOVING` and `STOPPED` are what
fire the Moving, Stopped, Opening, Closing, Fully Opened, Fully Closed and
Level events; the driver sends no separate event notifications.

Commands received: `SET_LEVEL_TARGET { LEVEL_TARGET }` (open = 100, closed =
0) and `STOP`. Capabilities: `can_stop` true, `has_level` true,
`level_open` 100, `level_closed` 0, `level_unknown` declared explicitly,
`driver_handles_toggle` **false**. Type and Movement are left selectable by
the dealer unless the installer sets *Blind Type*/*Movement* properties
(`SET_TYPE`/`SET_MOVEMENT` are then sent).

#### 8.3.3 Relay (non-proxy device, `RELAY` connection)

Commands received on the relay connection: `OPEN`, `CLOSE`, `TOGGLE`,
`TRIGGER { TIME }`. `TRIGGER` maps to an absolute *on* with the device-side
auto-off timer (`toggle_after`, seconds), so the pulse ends even if the
controller or network fails mid-pulse **[Unverified: granularity of
`toggle_after` below one second]**.

| Situation | Notification |
| --- | --- |
| Value first known (load, reconnect) | `STATE_CLOSED` or `STATE_OPENED` (documented as not indicating a change, so no event fires) |
| Confirmed change | `CLOSED` or `OPENED` |
| Unknown or offline | nothing; the driver-defined *Device Offline* event and *Connection Status* carry it |

Closed = Shelly on unless *Invert*. The driver defines its own relay events
and variable (§8.3.4) because there is no proxy to do it.

#### 8.3.4 Driver-defined events and variables (all children)

| Event | ID | Fires |
| --- | --- | --- |
| Device Offline | 100 | Unreachable by every route for 60 s (FR-P9) |
| Device Online | 101 | First confirmed read after a fired Device Offline |
| Fallback Started | 102 | Route changes LAN → Cloud |
| LAN Restored | 103 | Route changes Cloud → LAN |
| Command Failed | 104 | A command ends in failure; reason in *Last Command Result* |
| Authentication Failed | 105 | This device rejected the LAN password (FR-E1) |
| Relay Closed / Relay Opened (Relay only) | 110 / 111 | Confirmed change (never at load) |

Address changes are logged, not exposed as events.

| Variable | ID | Type | Meaning |
| --- | --- | --- | --- |
| Device Online | 2001 | bool | Positive online state (false while Unknown) |
| Route | 2002 | string | `LAN` / `Cloud` / `Unreachable` |
| Relay State (Relay only) | 2010 | bool | Closed = true |

These add one `AddVariable` per variable per child at load. Hub init has a
40-call budget (§11); child init is budgeted separately at 10 blocking calls.

#### 8.3.5 Reserved ID ranges

Proxy-defined IDs the driver must not reuse: Blind events 1–9, Blind variables
1000–1009; Light V2 events 4000–4003, 5000, 5001+ (keypad), 5100–5101, Light V2
variables 1000–1010, 1120–1121, 1300–1301, 6661. Driver-defined events use
**100–199** and variables **2000–2099**. Chowmain's change log records a major
defect where a variable ID and an event ID collided and Control4's rule that
event IDs cannot change after creation forced installers to remove and re-add
the driver; pinning the ranges avoids that outright.

## 9. Setup flow (installer's view)

1. In the Shelly app, add every device to the cloud; give each a DHCP
   reservation; optionally set a device password.
2. Copy the **Authorization cloud key** and **server** from the app.
3. In Composer add **Shelly Hub**; paste Server and Key; **Test Connection**.
4. If devices have passwords, enter **Device Password**.
5. **Fetch Devices** (or **Add Device By ID**), then choose **Default Room**
   and **Switch Default Type**, then **Auto-Setup**.
6. Run **Test LAN**. Fix any device reporting unreachable (firewall, VLAN,
   wrong address) or authentication failures. Devices that stay unreachable
   keep working through the cloud.
7. Rename children and move them to rooms as usual.

Adding a device later: **Fetch Devices**, **Auto-Setup**, **Test LAN**.

### Risk isolation

Only FR-S4 depends on undocumented cloud endpoints, so if they change,
control and feedback are unaffected and only bulk discovery degrades to manual
entry (FR-S5). Only fallback and refresh depend on the cloud at runtime, so a
Shelly cloud outage affects no device that is reachable locally.

## 10. Security, privacy and safety

- **Two secrets.** The cloud key controls every device on the account
  (including devices shared into it); a device password controls one device
  (or all, if shared). Both are stored with encrypted persistence, held in
  password-type properties, and redacted everywhere.
- **Recommend a dedicated Shelly account per site.**
- **Cloud TLS** is always verified; only `*.shelly.cloud` is contacted.
- **LAN TLS** is unverified by default (§7.2.3): traffic is encrypted but the
  device is not authenticated by certificate. This trade is stated in the
  README.
- **Wrong-device risk.** If a device's address is reassigned and authentication
  is *off*, a command could reach a different Shelly before the next identity
  check. Mitigations: DHCP reservations (recommended in the README), identity
  verification on every read, and the digest realm (the device ID) which makes
  authenticated devices reject credentials meant for another. The README
  recommends enabling device passwords for anything where a mistaken switch
  would matter.
- **Lockout safety** (FR-E1) protects devices from being locked out by the
  driver.
- **Network exposure.** Enabling LAN control means the controller connects to
  devices on ports 80/443; on segmented networks this requires a firewall rule
  the customer must approve.
- No telemetry; no host other than the configured Shelly server and the
  devices themselves is contacted.

**Availability.** With hybrid routing an internet outage no longer stops
control of reachable devices, but the suite still depends on a working LAN,
correct addresses and (for setup and fallback) the Shelly cloud. **Do not use
it for anything safety- or security-relevant** (garage doors, gate release,
heating that must not fail, water shut-off), and keep wall switches working.

## 11. Non-functional requirements

Numbers are **targets to be measured in M0/M1, not promises**; no LAN or cloud
round-trip measurements have been taken.

| Area | Requirement |
| --- | --- |
| LAN command latency | One LAN round trip plus proxy overhead; no artificial delay |
| Scene of *N* lights | Executes with LAN parallelism (≤ 3 in flight); expected well under a second for typical N, to be measured |
| Cloud fallback latency | Bounded by cloud queue depth × 1.2 s; visible in diagnostics |
| Feedback staleness | ≤ LAN Poll Interval for external changes on LAN-Up devices; one verification read after Control4-initiated changes |
| Controller load | LAN reads staggered; ≤ 3 in flight; a 40-device site at 20 s averages 2 requests/s. JSON decode cost per read to be profiled (M1) |
| Scale | Designed and tested for 40 devices / 100 components per hub |
| Cloud usage in steady state | 40 devices → 4 requests per 300 s health cycle, plus rare refresh and fallback |
| Init | Hub `OnDriverLateInit` within a 40-blocking-call budget and each child within 10 (both enforced by test). No init work deferred to timers except the first network reads |
| Memory | Queues bounded (cloud 50 entries; LAN 1 waiting per target); activity buffer 25 |
| Persistence | Blob-with-checksum scheme and delayed read-back verification from C4-PimaForce |

## 12. Extension points (not in v1)

1. **LAN WebSocket push.** Gen2+ devices offer a WebSocket at `/rpc` that
   delivers status-change notifications, so feedback could be immediate with
   no polling. Control4 publishes a pure-DriverWorks WebSocket client library
   in its public common-libraries repository, and the SDK ships a WebSocket
   sample. Open questions: per-device connection limits, `wss://` on newer
   firmware, authentication over the socket, controller load. The `Feed`
   interface in ARCHITECTURE.md exists so this is a swap for LAN polling.
2. Colour temperature and RGB(W) lights.
3. Sensors (temperature, power) as read-only children.
4. Input / button events (needs push).
5. Bindings instead of `SendToDevice` (§ARCHITECTURE).

## 13. Acceptance criteria

On a real account with mixed hardware (one switch, one dimmer, one cover; at
least one device with a password; ideally one on newer HTTPS-enabled firmware):

1. **Setup:** from an empty hub, Test Connection → Fetch Devices → Auto-Setup →
   Test LAN yields working children with no addresses typed.
2. **Fallback setup:** achievable with Fetch Devices unavailable, via Add Device
   By ID.
3. **Local control:** on/off/level/open/close/stop from Navigator, programming
   and a scene all work, and confirm via LAN read.
4. **Internet down:** with the internet disconnected and the controller
   rebooted, LAN control and feedback work from persisted addresses.
5. **Cloud down / fallback:** with a device made LAN-unreachable (firewall),
   commands succeed via the cloud, the route shows Cloud, and LAN control
   resumes automatically when the block is removed.
6. **Address change:** changing a device's IP results in self-healing via
   cloud refresh, with no wrong-device command.
7. **Wrong password:** produces exactly one clear message and no further
   authenticated attempts to that device (verified by request count).
8. **No guessing:** after a reboot with no connectivity, children show
   Unknown/Offline, never off/closed.
9. **Scenes:** a 10-light scene with different levels completes in parallel
   without cloud traffic.
10. **Redaction:** with Debug on for a full session, neither the cloud key nor
    any device password appears in Lua Output, Director log or any property.
11. **Regression suite** passes offline, one test per defect class.
12. **Documented limits** (§2, §10, §11) appear in the README and Composer
    documentation.
13. **Proxy events:** with the recording proxy doubles and on a real
    controller, a light command produces `CHANGING` then `CHANGED` and fires
    Light On/Off exactly once; a blind move produces `MOVING` then `STOPPED`
    and fires Moving, Stopped and the Opening/Closing variables correctly; a
    relay change fires Relay Closed/Opened once and a reload fires neither.
14. **No spurious events:** a controller reboot, a route change LAN↔cloud, and
    ten identical polls fire no proxy or driver event.
15. **Offline signalling:** unplugging a device produces *Device Offline* after
    about 60 s, the proxy's offline/unknown signal, and *Device Online* on
    return; none of them fire at controller start-up.
16. **DHCP change:** changing a device's address produces Fallback Started
    (if commands are issued meanwhile), then LAN Restored after self-heal, and
    never a wrong-device command (verified by request log).

## 14. Milestones

| # | Milestone | Exit criteria |
| --- | --- | --- |
| M0 | **Spike** — plain Lua/curl against real hardware and a real account | Committed fixtures for: cloud get-state per component type (including the address fields), each cloud control call, a group call, a 429, a bad-key response, the listing endpoints; **LAN**: `/shelly` probe, `Shelly.GetStatus`, each control method, digest challenge and response (SHA-256) on **old and new firmware**, HTTP vs redirect vs HTTPS-only devices, wrong-password behaviour (carefully, on a sacrificial device), identity fields. Measured: LAN and cloud round-trip time, JSON decode cost on a real controller, whether `C4:url` supports the required TLS/digest behaviour, whether `require` of bundled files works |
| M1 | Hub, both transports, router, per-device state machine, cloud queue | Unit-tested rate gate, coalescing, lockout safety, identity guard, fallback, redaction; Test Connection, Fetch, Test LAN working on a controller |
| M2 | Light On/Off + Light | Hub↔child protocol proven; Auto-Setup creates them |
| M3 | Relay + Blind | Blind level tracking with bounded fast-poll |
| M4 | Setup polish | Add By ID, overrides, Purge, List Devices, documentation tab |
| M5 | Hardening; **optional WebSocket push** | Field soak; push only if M0/M1 findings support it |

Nothing after M0 should be started before its findings are written into the
**[Unverified]** items above.

## 15. Open questions

1. Which fields does a cloud device status carry for LAN address (Wi-Fi and
   Ethernet), and does `pick` select them cheaply (M0)?
2. Exactly what do the listing endpoints return, and with which request shape?
3. Firmware/HTTPS: is the boundary 1.8 or 2.0.0, and do *updated* devices
   redirect or stay plain HTTP? Capture behaviour on devices at several
   firmware levels.
4. What are the precise digest fields and hashing details on old vs new
   firmware, and does authentication change what the unauthenticated probe
   returns?
5. Can `C4:url` do SHA-256 digest, self-signed/private-CA TLS, and a custom CA?
   If not, is the Lua implementation over `C4:Hash` sufficient?
6. Does `Light.Set` accept a transition duration on the target firmware?
7. Real limits for concurrent connections per device when the Shelly app,
   scripts, or another integration are also connected.
8. Can `C4:Bind` create hub↔child bindings, or is `SendToDevice` plus
   configuration push the long-term design?
9. Behaviour on the target OS of the documented notifications: Light V2
   `ONLINE_CHANGED` and `supports_target`, Blind `level_unknown` and how the
   proxy renders it, whether Blind `STOP` arrives as a command name or a
   `SET_LEVEL_TARGET` variant, and the relay `STATE_*` versus `CLOSED`/`OPENED`
   semantics on a real controller.
10. Can Default Room be populated from the project, and does driver-initiated
    `C4:AddDevice` honour it across target OS versions?
11. Repository licence (suggested MIT), and DriverWorks SDK licence terms for
    publishing driver source.

## Appendix A — Control4 interface summary

Authoritative behaviour is in §8.3; this is the one-page view.

| Driver | Control4 interface | Commands received | Notifications sent | Proxy/driver events |
| --- | --- | --- | --- | --- |
| Light | `light_v2` (dimmer, `supports_target`) | `SET_BRIGHTNESS_TARGET`, `TOGGLE` | `LIGHT_BRIGHTNESS_CHANGING`, `LIGHT_BRIGHTNESS_CHANGED`, `ONLINE_CHANGED` | Light On/Off, Brightness Changing/Changed (proxy); IDs 100–105 (driver) |
| Light On/Off | `light_v2` (dimmer false) | `SET_BRIGHTNESS_TARGET`, `TOGGLE` | as above | as above |
| Relay | non-proxy `RELAY` connection | `OPEN`, `CLOSE`, `TOGGLE`, `TRIGGER {TIME}` | `OPENED`, `CLOSED`, `STATE_OPENED`, `STATE_CLOSED` | Relay Opened/Closed and IDs 100–105 (all driver-defined) |
| Blind | `blind` | `SET_LEVEL_TARGET {LEVEL_TARGET}`, `STOP` | `SET_CAN_STOP`, `SET_HAS_LEVEL`, `MOVING`, `STOPPED` | Open, Fully Closed, Stopped, Fully Opened, Moving, Level changed, Target changed, Opening, Closing (proxy); IDs 100–105 (driver) |

Blind level: 0 = closed, 100 = open. Blind proxy variables 1000–1009 and
Light V2 variables 1000–1010, 1120–1121 are proxy-owned (§8.3.5).

## Appendix B — Provenance

Based on Shelly's public Cloud Control API and Gen2+ device API documentation,
Shelly's published network guidance, and Control4's public DriverWorks
documentation. Independent of, and sharing no text or code with, any
commercial Shelly driver; Chowmain's *Shelly Suite Installation and Usage
Guide* was used only as a feature reference to decide what to leave out.
