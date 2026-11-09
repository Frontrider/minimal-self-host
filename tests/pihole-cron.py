#!/usr/bin/env python3
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


if "--inside" not in sys.argv:
    root = Path(__file__).resolve().parent.parent
    subprocess.run(
        [
            "docker", "run", "--rm", "--network", "none",
            "--entrypoint", "python3", "-v", f"{root}:/source:ro",
            sys.argv[1] if len(sys.argv) > 1 else "minimal-self-host-core",
            "/source/tests/pihole-cron.py", "--inside",
        ],
        check=True,
    )
    sys.exit(0)

Path("/etc/pihole").mkdir(exist_ok=True)
Path("/etc/pihole/gravity.db").write_text("ready")
Path("/etc/pihole-cron").mkdir(exist_ok=True)
table = "* * * * * printf 'cron-output-regression\\n'\n"
Path("/etc/pihole-cron/root").write_text(table)

with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as log:
    log.bind("/dev/log")
    log.settimeout(1)
    cron = subprocess.Popen(
        ["sh", "/source/rootfs/etc/s6-overlay/s6-rc.d/pihole-cron/run"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    messages = []
    try:
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            if cron.poll() is not None:
                raise AssertionError(f"Cron exited: {cron.stdout.read()}")
            try:
                messages.append(log.recv(65536).decode())
            except socket.timeout:
                continue
            if any("CMDOUT" in line and "cron-output-regression" in line for line in messages):
                break
        else:
            raise AssertionError(f"Cron job output was not logged: {messages}")
        installed = subprocess.check_output(["crontab", "-l"], text=True)
        assert installed == table, installed
        assert not any("sendmail" in line.lower() for line in messages), messages
    finally:
        cron.terminate()
        output, _ = cron.communicate(timeout=10)
        os.unlink("/dev/log")
    assert "unrecognized option" not in output, output

print("Cronie crontab loading and job output through syslog passed")
