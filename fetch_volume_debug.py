"""Capture live [AMProjExport] log lines while testing the volume slider.

Usage:
  1. Plug the iPhone into this PC via USB (unlock it, trust this computer).
  2. python fetch_volume_debug.py
  3. When prompted, drag the volume slider in the app for ~15 seconds.

Output: device_logs/volume_debug_<timestamp>.log
"""
import subprocess
import sys
import time

P = r"C:\Users\XOS\AppData\Local\Programs\Python\Python312\Scripts\pymobiledevice3.exe"
UDID = "00008110-001C25D63644801E"
OUT = sys.argv[1] if len(sys.argv) > 1 else "device_logs/volume_debug_%d.log" % time.time()


def run(args, timeout=120):
    return subprocess.run([P] + args, capture_output=True, text=True,
                          timeout=timeout, errors="replace")


def main():
    for attempt in range(6):
        r = run(["usbmux", "list"])
        if UDID in r.stdout:
            break
        print(f"[{attempt}] device not on usbmux yet; plug in the iPhone")
        time.sleep(5)
    else:
        sys.exit("device never appeared")

    print("capturing syslog for 30s - DRAG THE VOLUME SLIDER NOW")
    proc = subprocess.Popen(
        [P, "syslog", "live", UDID],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace")
    kept = []
    deadline = time.time() + 30
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        if "AMProjExport" in line or "AlightMotion" in line and (
                "olume" in line or "slider" in line.lower()):
            kept.append(line.rstrip())
            print(" *", line.rstrip()[-160:])
    proc.terminate()
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(kept))
    print(f"saved {len(kept)} lines to {OUT}")


if __name__ == "__main__":
    main()
