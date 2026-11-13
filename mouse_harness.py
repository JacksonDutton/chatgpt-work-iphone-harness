#!/usr/bin/env python3
"""One bounded gesture request to the locally authorised Precision Mouse app."""
import argparse
import fcntl
import json
import os
import pathlib
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", help="JSON request, or cancel")
    parser.add_argument("--bridge-dir", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parent / "mouse-bridge")
    args = parser.parse_args()
    root = args.bridge_dir
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.request == "cancel":
        (root / "cancel").touch(mode=0o600)
        print("Cancellation requested")
        return
    try:
        request = json.loads(args.request)
    except json.JSONDecodeError as error:
        parser.error(str(error))
    if not isinstance(request, dict) or request.get("action") not in ("status", "click", "drag"):
        parser.error("Expected a JSON object with action status, click or drag")
    # One client at a time: do not overwrite an in-flight request.
    with (root / "client.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another request is running; wait or send cancel")
        request.update(id=str(uuid.uuid4()), created=time.time())
        (root / "cancel").unlink(missing_ok=True)
        temporary = root / "request.tmp"
        temporary.write_text(json.dumps(request, allow_nan=False))
        temporary.chmod(0o600)
        os.replace(temporary, root / "request.json")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                response = json.loads((root / "response.json").read_text())
                if response.get("id") == request["id"] and response.get("state") != "running":
                    print(json.dumps(response))
                    raise SystemExit(0 if response.get("state") == "done" else 1)
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        (root / "cancel").touch(mode=0o600)
        raise SystemExit("Timed out; cancellation requested. Check the native helper is open.")


if __name__ == "__main__":
    main()
