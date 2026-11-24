"""Print incoming MIDI messages from all inputs, or one selected input."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from datetime import datetime
from queue import Empty, Queue
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List input ports and exit")
    parser.add_argument("--port", help="Input port name (default: all connected inputs)")
    parser.add_argument("--hide-clock", action="store_true", help="Hide MIDI clock messages")
    args = parser.parse_args()

    try:
        import mido

        backend = mido.Backend("mido.backends.rtmidi")
        names = backend.get_input_names()
        if args.list:
            for name in names:
                print(name)
            if not names:
                print("No MIDI inputs found.")
            return 0
        if args.port:
            if args.port not in names:
                print(f"MIDI input not found: {args.port!r}. Use --list.", file=sys.stderr)
                return 1
            names = [args.port]
        if not names:
            print("No MIDI inputs found. Connect a controller and run again.", file=sys.stderr)
            return 1

        messages = Queue()

        def receive(name, message):
            if args.hide_clock and message.type == "clock":
                return
            messages.put((datetime.now(), name, message))

        with ExitStack() as stack:
            for name in names:
                stack.enter_context(backend.open_input(
                    name, callback=lambda message, name=name: receive(name, message)
                ))
                print(f"Listening: {name}", flush=True)
            print("Channels: 0–15 (MIDI channels 1–16). Ctrl-C to stop.", flush=True)
            while True:
                try:
                    timestamp, name, message = messages.get(timeout=0.2)
                except Empty:
                    continue
                stamp = timestamp.strftime("%H:%M:%S.%f")[:-3]
                print(f"{stamp} [{name}] {message} | hex={message.hex()}", flush=True)
    except KeyboardInterrupt:
        print("\nStopped.")
        return 0
    except ImportError:
        print("Missing MIDI dependencies. Run: .venv/bin/python -m pip install mido python-rtmidi", file=sys.stderr)
        return 1
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"MIDI error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
