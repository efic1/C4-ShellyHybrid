# Shelly Hub for Control4 - Installer Guide

The Shelly Hub sets up Shelly Gen2 and newer devices through the **Shelly cloud** (device list, names,
addresses) and then controls them **locally over your LAN**. If a device cannot be reached locally, the hub
falls back to the cloud. Feedback (wall switch, app, schedule changes) is read by polling.

Nothing here is a safety or security function. Do not use it to switch loads whose failure could cause harm.

## What you install

- **Shelly Hub** (`shelly_hub.c4z`) - one per project. It is a normal driver, not an agent.
- **Shelly Light (Dimmer)** - a `light:N` channel (dimmers, RGBW channels in white mode).
- **Shelly Light (On/Off)** - a `switch:N` channel shown as an on/off light.
- **Shelly Relay** - a `switch:N` channel exposed as a Control4 relay you bind a device to.
- **Shelly Blind** - a `cover:N` channel (shutters, roller blinds, awnings).
- **Shelly Contact Sensor** - a device's input terminal (a reed or limit switch, e.g. on a garage door) or a Shelly Door/Window sensor, shown as a Control4 contact sensor. Read-only.
- **Shelly Alarm Sensor** - a `flood:N` (water leak) or `smoke:N` component, shown as a Control4 contact sensor. Read-only.

You normally only add the hub. Auto-Setup creates the rest. Of the Gen1 (original) Shelly devices only a few are supported - see *Gen1 devices* below.

## Before you start

- Give the Shelly devices **DHCP reservations** (or static addresses). The hub heals address changes, but
  reservations make it instant and remove any chance of a stale address.
- The controller must be able to reach the devices on TCP 80/443. If your devices are on a separate VLAN, allow that.
- Add the devices to the **Shelly app** with your account and update their firmware. They must be linked to the cloud.
- Note the **Server** and **Authorization Key**: Shelly app or control.shelly.cloud > User settings > Authorization cloud key.
  The server looks like `shelly-42-eu.shelly.cloud`. Only hosts ending in `.shelly.cloud` are accepted.
- Use a separate Shelly account per customer site. Never share one account between sites.

## Setup, step by step

- Composer Pro: Driver > Add or Update Driver, select all five `.c4z` files.
- Add **Shelly Hub** to the project (any room).
- Enter **Server** and **Authorization Key**. After a moment run **Test Cloud Connection**. The Lua output shows how many devices were found.
- Set **Default Room ID** to the room number children should be created in (see the room's ID in Composer).
- If you prefer relays to lights for plain switch channels, set **Switch Default Type** to Relay first.
- Run **Fetch Devices**. Every supported component is listed. Run **List Devices** to see them.
- If Fetch Devices fails or finds nothing, the device list may be unavailable for your account or server.
  Use **Add Device By ID** instead: put one or more device ids (comma separated) in **Manual Device ID**. Ids are in the
  Shelly app under Device > Settings > Device Information.
- Run **Auto-Setup Children**. One child driver is created every 0.4 s and configured automatically. Running it again never creates duplicates, and renaming a child is safe.
- Check each child: **Status** should say Connected and **Route** should say LAN.
- Run **Test LAN** and read the report: address, http/https, authentication, identity match and state for every device.

### LAN only (no cloud)

Enter **Manual Device ID** (the Shelly device id) and **Manual Device Address**, run **Add Device By ID**, then **Auto-Setup Children**.
This needs no cloud account, but you lose automatic address healing and names.

### Device password

If your devices have an authentication password set, enter it in **Device Password** (user is always `admin`).
The hub tries a wrong password **once per device** and then stops talking to that device on the LAN, so a mistake cannot lock a device out.
The stop survives reboots. Changing the password, or running **Clear Authentication Stops** / **Test LAN**, lifts it.
Commands to a stopped device go through the cloud until you fix it.

## Gen1 devices

Only these Gen1 (original) devices are supported; everything else is listed as unsupported and left alone:

- **Shelly 1 (SHSW-1)** - one relay, shown as an on/off light or a relay like any switch channel (*Switch Type Overrides* applies).
- **Shelly Flood (SHWT-1)** and **Shelly Smoke (SHSM-01)** - battery alarm sensors, read through the cloud about once a minute, exactly like
  their Gen2 equivalents (see the next section for the limits).
- **Shelly Gas (SHGS-1)** - mains-powered, read over the LAN every poll interval, so an alarm normally reaches Control4 within about
  20-40 seconds. **Alarm Level** shows `none`, `mild`, `heavy`, `test` or `unknown`; `mild` and `heavy` are alarms (one alarm, whichever level), and the
  self-test result (`test`) is not. **Sensor State** shows `normal`, `warmup`, `fault` or `unknown`: a detector that is warming up or
  faulted cannot report "no alarm", so the contact is left as it was (it never announces an all-clear) and the state variable is the way to
  notice it. Use a program on **Sensor State** to be told about a faulted detector. A silent gas detector is reported offline after 10 minutes. Gas concentration is not exposed.

How Gen1 differs, and what that means for you:

- Gen1 is **LAN only**. It uses plain HTTP and **Basic** authentication (not HTTPS or digest). The hub-wide **Device Password** is sent as the
  password for user `admin`, with the same rule as Gen2: **one** wrong attempt, then the hub stops talking to that device until the password is
  changed or *Clear Authentication Stops* is run.
- A Gen1 device is **never commanded through the cloud.** If it is unreachable on the LAN, a command fails and says so (the cloud route for
  Gen1 is not used because it is not documented). Give Gen1 devices a DHCP reservation.
- Gen1 feedback is polled like everything else; Shelly's action URLs and CoIoT are not used.
- Other Gen1 relay devices (1PM, 1L, 2.5, Uni, plugs) are **deliberately not enabled yet**: a 2.5 in roller mode also reports relays, and
  driving a roller motor as two lights would be dangerous. Tell me which ones you have and I will add them, with their own tests.

## Garage doors and gates (pulse relays)

A Shelly relay wired to an opener's dry-contact input works through the **Shelly Relay** driver: bind the Control4 garage-door or gate
driver to its Relay connection. A *TRIGGER* from Control4 becomes a pulse of **Trigger Pulse (ms)** (default 1000) done by the device
itself.

- **A pulse is never repeated automatically.** On/off commands may be retried and failed over to the cloud, but a pulse that may have reached
  the device (the reply was lost) is **not** repeated, and not sent again through the cloud: a second pulse would stop or reverse the door.
  You get a *Command Failed* that says the pulse may or may not have been delivered; check the door. The cloud is used for a pulse only when
  the LAN proved nothing was sent.
- On the Shelly, set the relay's **input mode to `detached`** if a door sensor or any other input is wired to its SW terminal. In `follow` or
  `flip` mode a change of that input operates the relay, which would trigger the opener.
- Also on the Shelly: set the power-on state to **off**, and consider an auto-off delay a little longer than your pulse, so a relay that is
  ever left on cannot hold the opener. (Setting names are in the Shelly app; confirm them there.)
- **Door position feedback:** a reed or limit switch wired to the SW input is the device's `input:0`. Opt it in with **Contact Inputs** (see
  *Contact sensors*), and Control4 gets an open/closed contact next to the relay. After every pulse, when such a contact driver exists, the
  hub re-reads the device ten times over the next minute (at 2, 4, 6, 8, 10, 15, 20, 30, 45 and 60 seconds), so a door that starts moving is
  seen within seconds instead of at the next regular poll. Bind the contact to your garage-door driver's contact connection.

## Contact sensors

Two kinds of contact are supported, both read-only, both as a **Shelly Contact Sensor** driver with a Contact connection:

- **A device's input terminal** (Gen2 `input:N` of type *switch*; Gen1 Shelly 1 inputs). Most inputs are wall switches, so inputs are **opt-in**:
  list the ones you want in **Contact Inputs** on the hub, then run *Auto-Setup Children*. An entry is a device id or its last four or more
  characters, optionally with `:channel`, separated by commas, semicolons or new lines, for example `0040` or `aa0000000040:0, 0077:1`.
  *List Devices* shows unlisted inputs as `contact:N=optional(see Contact Inputs)`. A stateless *button* input has no state and is ignored.
- **Shelly Door/Window 1 and 2** (Gen1, battery). Created automatically. Read through the cloud about once a minute like the other battery
  sensors, so the latency and safety notes in the next section apply; *Device Offline* waits 25 hours; **Battery Level** is a variable.

Behaviour: closed means the circuit is closed (a reed switch with its magnet beside it). **Invert Contact** flips it on the Control4 side
without changing the Shelly. The contact reports its state when first known and on every rebind, then only real changes; **Contact Opened** /
**Contact Closed** fire on those changes, never on the first report after a reload. If a Door/Window's self-check fails, the contact is left as
it was. Variables: **Contact State**, **Battery Level** (Door/Window), **Device Online**, **Route**.

On the Shelly, a door contact needs the input to be of type *switch* and the relay's input mode to be `detached` (see the garage-door notes).

## Water-leak and smoke sensors

The **Shelly Flood Gen4** and **Shelly Plus Smoke** are supported as read-only contact sensors. Auto-Setup creates one **Shelly Alarm Sensor**
per `flood:N` or `smoke:N` component. Bind its **Alarm** connection to a security-panel zone or to any device that takes a contact sensor.

**Read this first: this is not a safety-grade alarm path.**

- These devices are battery-powered and sleep. They are normally unreachable on the LAN, so the hub reads their *last report* from the Shelly
  cloud about once a minute (and over the LAN while the device is awake, for example for three minutes after pressing its button). Expect an
  alarm to reach Control4 roughly **one to two minutes** after the device reports it, and not at all if the cloud or the internet is down.
- Keep the sensor's own siren and the Shelly app notifications as the primary alarm. Use Control4 for convenience (lights, announcements,
  a notification), never as the only warning. The same applies to the push notifications of this driver set.
- The driver **never mutes or silences an alarm.** The mute state is shown in the *Muted* variable only.
- The Shelly Gas (SHGS-1) is Gen1 and **is** supported, and because it is mains-powered it is read over the LAN (see *Gen1 devices*).

How it behaves:

- **Alarm Contact State** (default *Closed*) decides which contact state means "alarm". Set it to *Open* if your security panel expects a
  loop that opens on alarm. Changing it republishes the state without raising an event.
- The contact reports its state when it is first known and on every rebind; later it reports only real changes, and **Alarm Started** /
  **Alarm Cleared** fire on those changes, never on the first report after a reload (an alarm that is already active when the driver loads
  still sets the contact, so a security zone sees it).
- **Device Offline** fires only after **25 hours** of silence, because a sleeping device is silent by design. Route changes (LAN <-> cloud) raise
  no Fallback events for sensors.
- Variables: **Alarm**, **Alarm Level**, **Sensor State** (gas), **Muted**, **Battery Level** (Gen1 battery sensors), **Device Online**, **Route**.
- The flood sensor's own settings (alarm mode, state hold time) only change while it is awake; use the Shelly app.
- **Battery Level** (percent) is a variable for the Gen1 Flood and Smoke sensors, which report it. The Gen2 sensors do not report it here yet.
- A Gen1 Flood sensor set to **Rain Mode** reports only when water changes and does not sound its buzzer; its contact still follows the water,
  so it can be used as a rain trigger.
- The Gen1 Smoke wakes every 12 hours (documented), which is why *Device Offline* waits 25 hours for battery sensors.

## Devices with profiles

Some Shelly devices have a *profile* that decides which outputs they present. The profile is set in the Shelly app or the device's web UI,
before Auto-Setup.

- **Plus 2PM / Pro 2PM:** profile `switch` gives two switches (two on/off lights or relays); profile `cover` gives one blind.
  Use `cover` for any motor. Calibrate the cover in the Shelly app first.
- **Plus RGBW PM:** profile `light` gives four independent dimmable lights; `rgb` and `rgbw` give a single colour output.
- **Pro RGBWW PM:** profile `light` (Lights x 5) gives five dimmable lights; `rgbx2light` gives two lights plus one colour output;
  `rgbcct` and `cctx2` give colour or tunable-white outputs only.
- **Colour and tunable-white outputs are not controllable yet.** *Fetch Devices*, *Auto-Setup Children* and *List Devices* say so
  (`NOT-CONTROLLABLE[rgb:0]`) instead of silently offering nothing. If the strips do not need colour, switch the device to its `light` profile.
- **If you change a device's profile later,** the components it no longer has are shown as `GONE(profile changed?)` in *List Devices* and are
  never offered again. Children you created for them stay until you delete them. Run *Auto-Setup Children* again to add drivers for the
  new components.

## Choosing relay or light per device

*Switch Default Type* applies to every plain switch channel. **Switch Type Overrides** changes it for specific devices or channels. Enter
entries as `device=Relay` or `device:channel=Light`, separated by commas, semicolons or new lines. The device can be its full id or its last
four or more characters:

- `0002=Relay` makes every channel of the device ending in `0002` a relay.
- `aa0000000002:1=Relay, 0002:0=Light` makes channel 1 a relay and channel 0 a light on that device.
- The most specific entry wins; anything unrecognised is ignored. It only affects children created from then on.

## Hub properties

- **Cloud Status / LAN Status / Devices / Cloud Requests Per Minute / Recent Activity** - read-only status.
- **Server, Authorization Key** - cloud access. The key is stored as a password property and never logged.
- **Device Password** - LAN authentication for all devices.
- **LAN Poll Interval (s)** - how often each device is read (default 20). Polls are spread evenly, one device at a time.
  Raise it on large or slow networks: the request rate is (devices / interval).
- **Cloud Check Interval (min)** - background cloud refresh for addresses and cloud-routed devices (default 5).
- **Cloud Fallback** - On lets the hub use the cloud when the LAN is unreachable. Off keeps everything local.
- **LAN TLS Verification** - Off by default: HTTPS is encrypted but the device certificate is not verified. Devices on firmware 2.0
  or later with Enhanced Security redirect port 80 to HTTPS and use certificates from Shelly's own authority, which a controller
  cannot verify. HTTP has no keep-alive, so every request is a new TLS handshake: use a longer poll interval on large HTTPS sites.
- **Identity Check** - Standard verifies a device's identity on every read and when its address is old. Strict probes before every command.
- **Default Room ID, Switch Default Type, Switch Type Overrides, Contact Inputs** - Auto-Setup options.
- **Manual Device ID / Address** - for Add Device By ID.
- **Log Level** - Error, Warning, Info or Debug. Secrets are redacted at every level.

## Hub actions

- **Test Cloud Connection** - checks the key and counts devices.
- **Fetch Devices** - reads the device list from the cloud. Gen1 devices this driver does not support are listed as unsupported and skipped.
- **Add Device By ID** - adds one device by id (and optional address).
- **Auto-Setup Children** - creates missing child drivers.
- **Test LAN** - probes every device and prints a report.
- **Poll Now** - forces an immediate refresh.
- **Refresh Addresses** - re-reads addresses from the cloud.
- **List Devices** - prints each device, its LAN state, address, route and children.
- **Show Recent Activity** - prints the last log entries.
- **Clear Authentication Stops** - lets the hub try the password again once per stopped device.
- **Purge Missing Devices** - forgets devices removed from the cloud account that have no child driver.

## Hub events

- Cloud Connected, Cloud Lost (after 60 s), Cloud Authentication Failed, Device Authentication Failed.

## Child drivers

Each child has a **Status**, the current **Route** (LAN or Cloud) and the **Last Command Result**.
The hub fills **Hub Device ID**, **Shelly Device ID** and **Channel** automatically. You can also set them by hand.

Actions on every child: **Re-register With Hub**, **Show Status**, **Resend State**.

Light children also have **Feedback Notification** (Brightness Changed / Both / Light Level). The default, *Brightness Changed*, is what
Control4's guide prescribes for dimmers and switches. Only if a light's tile does not follow the real state, try *Both* or *Light Level*.

Events on every child: Device Offline (only after 60 s), Device Online, Fallback Started, LAN Restored, Command Failed, Authentication Failed.
The relay child adds Relay Closed and Relay Opened.

Variables: **Device Online** and **Route** (relay: **Relay State**).

Behaviour to know:

- An **uncalibrated dimmer** channel only accepts fully on or off (the device refuses brightness); calibrate it in the Shelly app.
- A **calibrated cover that lost its position** (for example after a power cut) accepts open, close and stop; once it
  reaches an end position numeric levels work again.
- If a device has **night mode** or a brightness range configured, the level it reports can differ from the one requested;
  the reported value is what Control4 shows.

- Every command is **absolute**. "Toggle" is resolved by the child from the last known state. If the state is unknown the toggle is refused and Command Failed fires, rather than guessing.
- After a command the device is read back once. If it did not do what was asked (for example someone pressed the wall switch), the read-back wins and the UI corrects itself.
- Fast slider movements are limited to one value per component every 250 ms; the last value always wins.
- A short Wi-Fi blip shorter than 60 s never raises Device Offline.
- A cover without a calibrated position (or one that lost its position after a power cut) is presented to Control4 as a blind without
  feedback: open, close and stop only, no slider. Once it reports a position again, the slider returns.
- Set the blind's **Full Travel Time (s)** to the real end-to-end time; Control4 uses it to animate the movement.
- The relay child is a relay **provider**. Bind a relay-consuming device to its Relay connection. Bind it at any time: the child
  republishes the current state when a binding is made (or run **Resend State**).
- A relay consumer's own tile may show what Control4 last *commanded* rather than what the relay did. For conditions that depend on
  the real state, use the child's **Relay State** variable or the *Relay Closed* / *Relay Opened* events, which follow the device.

## Troubleshooting

- **Cloud Status: Auth failed** - wrong key or server. Traffic to the cloud stops until you change the key.
- **Fetch Devices finds nothing** - the account has no Gen2+ devices, or the server host is wrong.
- **Auto-Setup says nothing to set up** - run Fetch Devices first, or all components already have a child.
- **Child Status: Hub refused UNKNOWN_DEVICE** - the hub does not know that device yet. Run Fetch Devices; the child keeps retrying.
- **Child Status: Hub refused WRONG_TYPE** - the driver type does not match the component (for example a Blind on a light channel).
- **Route stays Cloud** - the LAN is not reachable. Run Test LAN. Check firewall rules, VLANs and client isolation.
- **Test LAN: identity MISMATCH** - another device now has that address. The hub will not command it. Run Refresh Addresses.
- **Test LAN: authentication rejected** - wrong Device Password. Fix it; the stop lifts automatically.
- **Commands work but the UI lags** - feedback is polled. Lower LAN Poll Interval if the network allows it.
- **Very large site** - raise LAN Poll Interval and check the Recent Activity property for warnings.

## Limits

- Feedback is polled (default 20 s), not pushed.
- No colour, colour temperature, input/button events, BLU or temperature/humidity sensors, and only a few Gen1 devices (see *Gen1 devices*). Water-leak and smoke sensors are read-only and not safety-grade (see above).
- The device password is one value for all devices.
- Inputs are read only as contacts, and only the ones listed in *Contact Inputs*; there are no input/button events and no analog or pulse-counting inputs.
- Devices that require a client certificate, or that sit behind a Shelly range extender on a custom port, are not supported.
- LAN HTTPS is encrypted but not certificate-verified by default.
