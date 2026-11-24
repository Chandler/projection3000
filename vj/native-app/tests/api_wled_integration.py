"""Exercise a real native app's HTTP, WebSockets and WLED UDP output on loopback.

Requires Python websockets. Uses a temporary state root; never contacts devices.
--seed must be an isolated native-state.json fixture, not a live state directory.
"""
import argparse
import asyncio
import base64
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import websockets


async def run(args):
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    results = []

    def passed(name, **detail):
        results.append(dict(check=name, passed=True, **detail))
        print(name, detail or "pass", flush=True)
        (evidence / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("127.0.0.1", 0))
    udp.setblocking(False)
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    base = f"http://127.0.0.1:{port}"
    wsbase = f"ws://127.0.0.1:{port}"

    def request(method, path, body=None, expected=200):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            response = urllib.request.urlopen(req, timeout=3)
        except urllib.error.HTTPError as error:
            response = error
        content = response.read()
        assert response.status == expected, (path, response.status, content)
        return json.loads(content)

    async def message(ws, predicate, timeout=4):
        async def receive():
            while True:
                value = json.loads(await ws.recv())
                if predicate(value):
                    return value
        return await asyncio.wait_for(receive(), timeout)

    def drain():
        while True:
            try:
                udp.recv(65535)
            except BlockingIOError:
                return

    async def pixels(expected, timeout=4):
        """Require the expected uniform RGB for each physical segment."""
        seen = set()
        async def receive():
            while seen != set(expected):
                packet = await asyncio.get_running_loop().sock_recv(udp, 65535)
                assert packet[:2] == bytes((4, 2)), packet[:4]
                assert len(packet) == 754, len(packet)
                start = int.from_bytes(packet[2:4], "big")
                assert start in (0, 250, 500), start
                if start in expected and packet[4:] == bytes(expected[start]) * 250:
                    seen.add(start)
        await asyncio.wait_for(receive(), timeout)

    with tempfile.TemporaryDirectory(prefix="vj-api-wled-") as root:
        state = json.loads(Path(args.seed).read_text())
        state["outputCount"] = 2
        state["outputRouting"] = dict(displayAssignments={}, ndiProjectors={})
        controls = state["controls"]
        controls["linked"] = False
        controls["fixtures"] = [dict(id=f"strip-{i + 1}", label=f"Strip {i + 1}",
            kind="wled", count=250, start=i * 250, enabled=True, brightness=1.,
            power_limit=1., route=dict(out="out1" if i < 2 else "out7",
                start=0., end=1., offset=0., reverse=False)) for i in range(3)]
        controls["fixtureOutput"] = dict(host="127.0.0.1", port=udp.getsockname()[1],
                                         requested=False, activationToken="")
        controls["dmx"]["transport"]["requested"] = False
        controls["midi"]["requested"] = None
        controls["link"]["enabled"] = False
        Path(root, "native-state.json").write_text(json.dumps(state))
        with (evidence / "app.log").open("w") as log:
            process = subprocess.Popen([str(Path(args.binary).resolve()), "--state-root", root,
                                        "--port", str(port)], stdout=log, stderr=log)
            try:
                for _ in range(80):
                    assert process.poll() is None, "App exited during startup"
                    try:
                        snapshot = request("GET", "/api/v1/state")
                        break
                    except (OSError, urllib.error.URLError):
                        await asyncio.sleep(.1)
                else:
                    raise AssertionError("API failed to start")
                top = {"apiVersion", "device", "capabilities", "outputs", "mappings", "state", "revision"}
                state_keys = {"grid", "mix", "fixtures", "fixtureOutput", "dmx", "midi",
                              "display_assignments", "output_status", "renderer"}
                assert top <= snapshot.keys()
                for _ in range(40):
                    if state_keys <= snapshot["state"].keys():
                        break
                    await asyncio.sleep(.1)
                    snapshot = request("GET", "/api/v1/state")
                assert state_keys <= snapshot["state"].keys(), state_keys - snapshot["state"].keys()
                passed("HTTP full state contract", top_keys=sorted(snapshot), state_keys=sorted(snapshot["state"]))
                for path in ("/api/v1/grid", "/api/v1/effects", "/api/v1/stats",
                             "/api/v1/leds", "/api/v1/fixture-output", "/api/v1/mappings/1"):
                    request("GET", path)
                passed("Live query routes")
                async with websockets.connect(wsbase + "/api/v1/events", max_size=8 * 1024 * 1024) as events:
                    first = await message(events, lambda v: top <= v.keys())
                    assert state_keys <= first["state"].keys()
                    await events.send(json.dumps(dict(type="grid", action="add_column")))
                    after = await message(events, lambda v: True)
                    assert after["revision"] == first["revision"]
                    passed("Events are full snapshots and read-only")
                    async with websockets.connect(wsbase + "/ws/ui", max_size=8 * 1024 * 1024) as ui:
                        hello = await message(ui, lambda v: v.get("type") == "hello")
                        assert "grid" in hello and "library" in hello
                        await ui.send(json.dumps(dict(type="grid", action="rename_show", name="API integration")))
                        await message(events, lambda v: any(s["name"] == "API integration" for s in v["state"]["grid"]["shows"]))
                    passed("Legacy UI WebSocket commands reach live-state events")
                    grid = request("GET", "/api/v1/grid")["grid"]
                    row, column = grid["rows"][0]["id"], grid["columns"][0]["id"]
                    command = lambda **kw: request("POST", "/api/v1/grid", kw)
                    command(action="put_clip", row=row, column=column, effect="trace_solid", params=dict(tint="#ff0000", breathe=0))
                    command(action="launch_clip", row=row, column=column, bus="out1", bank="A")
                    command(action="set_crossfade", bus="out1", value=0)
                    command(action="start_out", bus="out1")
                    started = time.monotonic()
                    request("POST", "/api/v1/mix", dict(led_master=.75, led_mute=False, blackout=False, invert=False))
                    await message(events, lambda v: v["state"]["mix"]["led_master"] == .75)
                    passed("HTTP edits broadcast through live events", latency_ms=round((time.monotonic() - started) * 1000, 1))
                    request("POST", "/api/v1/mix", dict(led_master=1.))
                    assert not request("GET", "/api/v1/fixture-output")["active"]
                    drain()
                    await asyncio.sleep(.15)
                    try:
                        udp.recv(65535)
                        raise AssertionError("WLED sent without explicit start")
                    except BlockingIOError:
                        pass
                    passed("WLED remains off until explicitly started")
                    request("POST", "/api/v1/fixture-output", dict(action="start"))
                    await pixels({0: (255, 0, 0), 250: (255, 0, 0), 500: (0, 0, 0)})
                    passed("Real DNRGB UDP: 3 x 250 pixels, correct offsets, inactive Out black")
                    live = await message(events, lambda v: v["state"]["fixtureOutput"].get("packets", 0) > 0)
                    later = await message(events, lambda v: v["state"]["fixtureOutput"].get("packets", 0) > live["state"]["fixtureOutput"]["packets"])
                    assert later["revision"] == live["revision"]
                    assert not later["state"]["fixtureOutput"]["stale"]
                    passed("Runtime counters stream without document edits", packets=later["state"]["fixtureOutput"]["packets"])
                    command(action="set_clip", row=row, column=column, params=dict(tint="#00ff00"))
                    drain()
                    await pixels({0: (0, 255, 0), 250: (0, 255, 0)})
                    async with websockets.connect(wsbase + "/ws/leds") as leds:
                        frame = await message(leds, lambda v: v.get("type") == "led_frames" and base64.b64decode(v["frames"]["strip-1"]) == bytes((0, 255, 0)) * 250)
                        assert base64.b64decode(frame["frames"]["strip-3"]) == bytes(750)
                    passed("Clip edits drive UDP and matching live LED previews")
                    other = grid["columns"][1]["id"]
                    command(action="put_clip", row=row, column=other, effect="trace_solid", params=dict(tint="#0000ff", breathe=0))
                    command(action="launch_clip", row=row, column=other, bus="out1", bank="B")
                    command(action="set_crossfade", bus="out1", value=.5)
                    drain()
                    await pixels({0: (0, 128, 128), 250: (0, 128, 128)})
                    passed("A/B crossfade reaches physical strips")
                    command(action="set_crossfade", bus="out1", value=0)
                    request("PATCH", "/api/v1/leds/strip-2", dict(power_limit=.25))
                    drain()
                    await pixels({0: (0, 255, 0), 250: (0, 64, 0)})
                    passed("Per-strip power limit reaches physical packets")
                    request("PATCH", "/api/v1/leds/strip-2", dict(power_limit=1.))
                    request("PATCH", "/api/v1/leds/strip-1", dict(brightness=.5))
                    drain()
                    await pixels({0: (0, 128, 0), 250: (0, 255, 0)})
                    passed("Per-strip brightness preserves other strips")
                    request("POST", "/api/v1/mix", dict(led_master=0))
                    drain()
                    await pixels({0: (0, 0, 0), 250: (0, 0, 0)})
                    request("POST", "/api/v1/mix", dict(led_master=1, led_mute=True))
                    await pixels({0: (0, 0, 0), 250: (0, 0, 0)})
                    passed("LED master and mute blackout physical packets")
                    request("POST", "/api/v1/mix", dict(led_mute=False))
                    request("PATCH", "/api/v1/leds/strip-1", dict(enabled=False))
                    drain()
                    await pixels({0: (0, 0, 0), 250: (0, 255, 0)})
                    passed("Disabling a strip clears its previous physical segment")
                    request("POST", "/api/v1/fixture-output", dict(action="set", host="localhost"), expected=400)
                    passed("Active destination edits reject atomically")
                    drain()
                    request("POST", "/api/v1/fixture-output", dict(action="stop"))
                    await pixels({250: (0, 0, 0), 500: (0, 0, 0)})
                    await message(events, lambda v: v["state"]["fixtureOutput"].get("status") == "off")
                    drain()
                    await asyncio.sleep(.25)
                    try:
                        udp.recv(65535)
                        raise AssertionError("WLED kept sending after stop")
                    except BlockingIOError:
                        pass
                    passed("Stop sends blackout and releases output")
                    request("POST", "/api/v1/fixture-output", dict(action="start", host="localhost"))
                    await pixels({250: (0, 255, 0)})
                    passed("Hostname resolution and restart")
            finally:
                try:
                    request("POST", "/api/v1/fixture-output", dict(action="stop"))
                    await asyncio.sleep(.1)
                finally:
                    process.terminate()
                    process.wait(timeout=5)
                    udp.close()
    passed("Owned test process cleaned up; live app untouched")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--seed", required=True)
    parser.add_argument("--evidence", required=True)
    asyncio.run(run(parser.parse_args()))
