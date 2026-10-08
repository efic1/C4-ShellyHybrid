"""Single source of truth for the driver set: events, properties, actions, connections.

`build.py` generates every driver.xml and src/common/ids.lua from this file, so the XML and the
Lua can never drift apart (tests/test_generator.lua also cross-checks the Lua sources).
Static events (with pinned IDs) are used instead of runtime C4:AddEvent so drivers add ZERO
Director round trips for events at load time.
"""

VERSION = "20260930"
CREATOR = "C4-ShellyHybrid"
MANUFACTURER = "Shelly (cloud-provisioned, LAN-executed)"

LOG_LEVELS = ["Error", "Warning", "Info", "Debug"]

# ---- child events (IDs are permanent: never renumber) ----------------------------------------------
CHILD_EVENTS = [
    (100, "Device Offline", "When NAME cannot be reached by LAN or cloud for 60 seconds"),
    (101, "Device Online", "When NAME is reachable again after being offline"),
    (102, "Fallback Started", "When NAME starts being controlled through the Shelly cloud"),
    (103, "LAN Restored", "When NAME is controlled over the LAN again"),
    (104, "Command Failed", "When a command to NAME failed"),
    (105, "Authentication Failed", "When NAME rejected the device password"),
]
RELAY_EVENTS = [
    (110, "Relay Closed", "When the relay of NAME closes (output on)"),
    (111, "Relay Opened", "When the relay of NAME opens (output off)"),
]
SENSOR_EVENTS = [
    (112, "Alarm Started", "When the sensor of NAME reports an alarm (water detected / smoke detected)"),
    (113, "Alarm Cleared", "When the sensor of NAME reports that the alarm has cleared"),
]
CONTACT_EVENTS = [
    (114, "Contact Opened", "When the contact of NAME opens"),
    (115, "Contact Closed", "When the contact of NAME closes"),
]
HUB_EVENTS = [
    (200, "Cloud Connected", "When the Shelly cloud connection is established"),
    (201, "Cloud Lost", "When the Shelly cloud connection is lost"),
    (202, "Cloud Authentication Failed", "When the cloud rejects the authorization key"),
    (203, "Device Authentication Failed", "When a device rejects the device password"),
]

# variables are created at runtime (C4:AddVariable); names are the contract, IDs are Director-assigned
CHILD_VARIABLES = [("Device Online", "BOOL"), ("Route", "STRING")]
RELAY_VARIABLES = [("Relay State", "STRING")]
CONTACT_VARIABLES = [("Contact State", "STRING"), ("Battery Level", "NUMBER")]
SENSOR_VARIABLES = [("Alarm", "BOOL"), ("Muted", "BOOL"), ("Alarm Level", "STRING"), ("Battery Level", "NUMBER"), ("Sensor State", "STRING")]

# ---- protocol between hub and children --------------------------------------------------------------
PROTOCOL = {
    "CHILD_REGISTER": "SHELLY_REGISTER", "CHILD_SET": "SHELLY_SET", "CHILD_UNREGISTER": "SHELLY_UNREGISTER",
    "HUB_CONFIG": "SHELLY_CONFIG", "HUB_ACK": "SHELLY_ACK", "HUB_STATE": "SHELLY_STATE", "HUB_RESULT": "SHELLY_RESULT",
}


def prop(name, ptype="STRING", default="", readonly=False, items=None, minimum=None, maximum=None):
    return dict(name=name, type=ptype, default=default, readonly=readonly, items=items, min=minimum, max=maximum)


def ro(name, default=""):
    return prop(name, "STRING", default, readonly=True)


COMMON_CHILD_PROPS = [
    ro("Driver Version", VERSION),
    ro("Status", "Not configured"),
    ro("Route", ""),
    ro("Last Command Result", ""),
    prop("Hub Device ID", "INTEGER", "0"),
    prop("Shelly Device ID", "STRING", ""),
    prop("Channel", "RANGED_INTEGER", "0", minimum=0, maximum=15),
    prop("Log Level", "LIST", "Warning", items=LOG_LEVELS),
]
LIGHT_PROPS = COMMON_CHILD_PROPS + [prop("Feedback Notification", "LIST", "Brightness Changed", items=["Brightness Changed", "Both", "Light Level"])]
CONTACT_PROPS = COMMON_CHILD_PROPS + [prop("Invert Contact", "LIST", "No", items=["No", "Yes"])]
SENSOR_PROPS = COMMON_CHILD_PROPS + [
    prop("Sensor Component", "LIST", "flood", items=["flood", "smoke", "gas"]),
    prop("Alarm Contact State", "LIST", "Closed", items=["Closed", "Open"]),
]
BLIND_PROPS = COMMON_CHILD_PROPS + [prop("Full Travel Time (s)", "RANGED_INTEGER", "20", minimum=5, maximum=180)]
CHILD_ACTIONS = [("Re-register With Hub", "ReRegister"), ("Show Status", "ShowStatus"), ("Resend State", "ResendState")]

HUB_PROPS = [
    ro("Driver Version", VERSION),
    ro("Cloud Status", "Not configured"),
    ro("LAN Status", ""),
    ro("Devices", "0"),
    ro("Cloud Requests Per Minute", "0"),
    ro("Recent Activity", ""),
    prop("Server", "STRING", ""),
    prop("Authorization Key", "PASSWORD", ""),
    prop("Device Password", "PASSWORD", ""),
    prop("LAN Poll Interval (s)", "RANGED_INTEGER", "20", minimum=5, maximum=300),
    prop("Cloud Check Interval (min)", "RANGED_INTEGER", "5", minimum=1, maximum=60),
    prop("Cloud Fallback", "LIST", "On", items=["On", "Off"]),
    prop("LAN TLS Verification", "LIST", "Off", items=["Off", "On"]),
    prop("Identity Check", "LIST", "Standard", items=["Standard", "Strict"]),
    prop("Default Room ID", "INTEGER", "0"),
    prop("Switch Default Type", "LIST", "Light", items=["Light", "Relay"]),
    prop("Switch Type Overrides", "STRING", ""),
    prop("Contact Inputs", "STRING", ""),
    prop("Manual Device ID", "STRING", ""),
    prop("Manual Device Address", "STRING", ""),
    prop("Log Level", "LIST", "Info", items=LOG_LEVELS),
]
HUB_ACTIONS = [
    ("Test Cloud Connection", "TestCloud"), ("Fetch Devices", "FetchDevices"), ("Add Device By ID", "AddManual"),
    ("Auto-Setup Children", "AutoSetup"), ("Test LAN", "TestLan"), ("Poll Now", "PollNow"),
    ("Refresh Addresses", "RefreshAddresses"), ("List Devices", "ListDevices"),
    ("Show Recent Activity", "ShowActivity"), ("Clear Authentication Stops", "ClearAuthStops"),
    ("Purge Missing Devices", "PurgeMissing"),
]

# Capabilities are the part of driver.xml that MUST be confirmed in Composer (milestone M0/M2).
# Capability semantics are from the guide's Light V2 Capabilities list. advanced_scene_support = the driver implements the FULL Advanced
# Lighting Scenes commands; reduced_als_support is the alternative for drivers that do not (the light may join a scene, cannot take part
# in scene ramping, and may have 0 or 1 elements in it) - so advanced is False here. ramp_level is what lets ALS dim a light, hence True
# for dimmers (RATE is honoured as transition_duration). reduced_als_support: per the proxy guide, this makes Advanced Lighting Scenes send individual SET_BRIGHTNESS_TARGET commands when a
# scene is activated. Without it a light must parse the PUSH_SCENE XML itself, which this driver does not do - so scenes would not move it.
# Names and the overall set follow Control4's official light_sample.c4i (light_v2 proxy). supports_target selects the newer
# SET_BRIGHTNESS_TARGET command; ramp_level is False because Shelly commands here carry no ramp rate.
LIGHT_CAPS = {"dimmer": "True", "set_level": "True", "ramp_level": "True", "on_off": "True", "supports_target": "True",
              "min_max": "False", "click_rates": "False", "hold_rates": "False", "cold_start": "False", "has_leds": "False",
              "supports_color": "False", "supports_broadcast_scenes": "False", "supports_multichannel_scenes": "False",
              "hide_proxy_events": "False", "reduced_als_support": "True", "advanced_scene_support": "False",
              "load_group_support": "False", "buttons_are_virtual": "True"}
# An on/off load cannot set a discrete brightness or ramp to one.
ONOFF_CAPS = dict(LIGHT_CAPS, dimmer="False", set_level="False", ramp_level="False")
# level_unknown is deliberately absent: the capability list places it beside level_closed / level_open, which are values, so it is
# probably a numeric sentinel (a live Director reports -255 for an unknown position) and "True" could mean level 1.
BLIND_CAPS = {"can_stop": "True", "has_level": "True", "driver_handles_toggle": "False"}

DRIVERS = {
    "hub": dict(file="shelly_hub", name="Shelly Hub", model="Shelly Hub (Cloud + LAN)", dir="hub",
                props=HUB_PROPS, actions=HUB_ACTIONS, events=HUB_EVENTS, proxy=None, caps=None, connections=[],
                desc="Provisions Shelly Gen2+ devices through the Shelly cloud and controls them over the LAN."),
    "light": dict(file="shelly_light", name="Shelly Light (Dimmer)", model="Shelly Light", dir="light",
                  props=LIGHT_PROPS, actions=CHILD_ACTIONS, events=CHILD_EVENTS, category="Lighting",
                  proxy=("light_v2", "Shelly Light"), caps=LIGHT_CAPS,
                  connections=[dict(id=5001, name="LIGHT", cls="LIGHT_V2", type=2, provider=True)],
                  desc="A dimmable Shelly light channel (light:N)."),
    "light_onoff": dict(file="shelly_light_onoff", name="Shelly Light (On/Off)", model="Shelly Light On/Off", dir="light_onoff",
                        props=LIGHT_PROPS, actions=CHILD_ACTIONS, events=CHILD_EVENTS, category="Lighting",
                        proxy=("light_v2", "Shelly Light"), caps=ONOFF_CAPS,
                        connections=[dict(id=5001, name="LIGHT", cls="LIGHT_V2", type=2, provider=True)],
                        desc="A Shelly relay channel (switch:N) presented as an on/off light."),
    "relay": dict(file="shelly_relay", name="Shelly Relay", model="Shelly Relay",  dir="relay",
                  props=COMMON_CHILD_PROPS + [prop("Trigger Pulse (ms)", "RANGED_INTEGER", "1000", minimum=100, maximum=60000)],
                  actions=CHILD_ACTIONS, events=CHILD_EVENTS + RELAY_EVENTS, proxy=None, caps=None,
                  connections=[dict(id=1, name="Relay", cls="RELAY", provider=True)],
                  desc="A Shelly relay channel (switch:N) exposed as a Control4 relay output (bind a relay-consuming device to it)."),
    "contact": dict(file="shelly_contact", name="Shelly Contact Sensor", model="Shelly Contact Sensor", dir="contact",
                    props=CONTACT_PROPS, actions=CHILD_ACTIONS, events=CHILD_EVENTS + CONTACT_EVENTS, proxy=None, caps=None,
                    connections=[dict(id=1, name="Contact", cls="CONTACT_SENSOR", provider=True)],
                    desc="A Shelly input terminal (reed or limit switch) or a Shelly Door/Window sensor, exposed as a read-only Control4 contact sensor."),
    "sensor": dict(file="shelly_sensor", name="Shelly Alarm Sensor", model="Shelly Alarm Sensor", dir="sensor",
                   props=SENSOR_PROPS, actions=CHILD_ACTIONS, events=CHILD_EVENTS + SENSOR_EVENTS, proxy=None, caps=None,
                   connections=[dict(id=1, name="Alarm", cls="CONTACT_SENSOR", provider=True)],
                   desc="A Shelly water-leak (flood) or smoke sensor, exposed as a Control4 contact sensor. Read-only."),
    "blind": dict(file="shelly_blind", name="Shelly Blind", model="Shelly Blind", dir="blind",
                  props=BLIND_PROPS, actions=CHILD_ACTIONS, events=CHILD_EVENTS,
                  proxy=("blind", "Shelly Blind"), caps=BLIND_CAPS,
                  connections=[dict(id=5001, name="BLIND", cls="BLIND", type=2, provider=True)],   # [Unverified] class name (pattern: proxy name upper-cased)
                  desc="A Shelly cover/shutter channel (cover:N)."),
}

BINDING = 5001
