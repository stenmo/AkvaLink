#!/usr/bin/env python3
"""AkvaLink MQTT monitor — subscribe to akvalink/# and display live readings.

Useful for verifying MQTT autodiscovery without a full Home Assistant install.
Requires a running MQTT broker (e.g. Mosquitto) reachable from this machine.

Quick start (Windows):
    # 1. Install Mosquitto broker (once):
    winget install mosquitto
    # or:  choco install mosquitto

    # 2. Start the broker (in a separate terminal):
    mosquitto -v

    # 3. Install paho-mqtt and run this script:
    pip install paho-mqtt
    py -3 scripts/mqtt_monitor.py

Usage:
    py -3 scripts/mqtt_monitor.py                      # localhost:1883
    py -3 scripts/mqtt_monitor.py --broker 192.168.1.x # custom broker IP
    py -3 scripts/mqtt_monitor.py --broker localhost --port 1883

The --station firmware defaults to mqtt://homeassistant.local:1883.
Point both to the same broker (e.g. run mosquitto on your PC and set
CONFIG_AKVALINK_MQTT_BROKER_URL to mqtt://<your-pc-ip>:1883 in sdkconfig
or via idf.py menuconfig → AkvaLink → MQTT broker URL).
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime


def main(argv: list[str] | None = None) -> int:
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        print("paho-mqtt not installed. Run:  pip install paho-mqtt")
        return 1

    p = argparse.ArgumentParser(description="AkvaLink MQTT monitor")
    p.add_argument("--broker", default="localhost", help="MQTT broker host (default: localhost)")
    p.add_argument("--port", type=int, default=1883, help="MQTT broker port (default: 1883)")
    args = p.parse_args(argv)

    print(f"Connecting to MQTT broker at {args.broker}:{args.port} …")
    print("Waiting for AkvaLink device (topic: akvalink/#)\n")

    def on_connect(client, userdata, flags, rc, properties=None):
        if rc == 0:
            print(f"[broker] Connected — subscribing to akvalink/# and homeassistant/sensor/akvalink_#/+/config\n")
            client.subscribe("akvalink/#")
            client.subscribe("homeassistant/sensor/+/temperature/config")
        else:
            print(f"[broker] Connection failed (rc={rc}). Is mosquitto running?")

    def on_disconnect(client, userdata, rc, properties=None):
        print(f"\n[broker] Disconnected (rc={rc})")

    def on_message(client, userdata, msg):
        topic: str = msg.topic
        payload = msg.payload.decode("utf-8", errors="replace")
        ts = datetime.now().strftime("%H:%M:%S")

        if "/temperature" in topic and not topic.endswith("/config"):
            # Live temperature reading
            try:
                d = json.loads(payload)
                celsius = d.get("celsius")
                if celsius is None:
                    print(f"[{ts}] {topic}  →  (no reading)")
                else:
                    bar = "█" * max(0, min(30, int((float(celsius) - 10) / 40 * 30)))
                    print(f"[{ts}] 🌡  {celsius:>6.1f} °C  {bar}")
            except (ValueError, KeyError):
                print(f"[{ts}] {topic}  →  {payload}")

        elif "/status" in topic:
            # Availability
            icon = "🟢" if payload.strip() == "online" else "🔴"
            mac = topic.split("/")[1] if "/" in topic else "?"
            print(f"[{ts}] {icon} Device {mac}: {payload}")

        elif "/config" in topic:
            # HA autodiscovery config
            try:
                d = json.loads(payload)
                print(f"[{ts}] 📋 HA discovery received:")
                print(f"       name:       {d.get('name')}")
                print(f"       unique_id:  {d.get('unique_id')}")
                print(f"       state:      {d.get('state_topic')}")
                print(f"       avail:      {d.get('availability_topic')}")
                dev = d.get("device", {})
                print(f"       device:     {dev.get('name')} / {dev.get('model')} / {dev.get('manufacturer')}")
                print()
            except ValueError:
                print(f"[{ts}] HA config: {payload[:120]}")
        else:
            print(f"[{ts}] {topic}  →  {payload[:80]}")

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    try:
        client.connect(args.broker, args.port, keepalive=60)
        client.loop_forever()
    except ConnectionRefusedError:
        print(f"\nConnection refused — is mosquitto running on {args.broker}:{args.port}?")
        print("Start it with:  mosquitto -v")
        return 1
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
