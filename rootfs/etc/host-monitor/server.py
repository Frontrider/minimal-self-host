#!/usr/bin/env python3
import http.client
import json
import logging
from pathlib import Path
import signal
import socket
import threading


THRESHOLD = 90
INTERVAL = 60
STOP_TIMEOUT = 30
PROC = Path("/host/proc")
DOCKER_SOCKET = "/var/run/docker.sock"


class DockerError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(f"Docker API returned {status}: {message}")
        self.status = status


class DockerConnection(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost", timeout=STOP_TIMEOUT + 10)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(DOCKER_SOCKET)


class Docker:
    def request(self, method, path):
        connection = DockerConnection()
        try:
            connection.request(method, path)
            response = connection.getresponse()
            body = response.read()
            if not 200 <= response.status < 300:
                raise DockerError(response.status, body.decode(errors="replace"))
            return json.loads(body) if body else None
        finally:
            connection.close()


def host_usage(proc=PROC):
    # Guest time is already counted in user/nice; iowait is not CPU execution.
    fields = (proc / "stat").read_text().splitlines()[0].split()
    if fields[0] != "cpu" or len(fields) < 9:
        raise ValueError("Host /proc/stat has no aggregate CPU counters")
    ticks = [int(value) for value in fields[1:9]]
    memory = {}
    for line in (proc / "meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        memory[key] = int(value.split()[0])
    total = memory["MemTotal"] * 1024
    available = memory["MemAvailable"] * 1024
    if total <= 0 or not 0 <= available <= total:
        raise ValueError("Invalid host memory counters")
    return sum(ticks), ticks[3] + ticks[4], total, 100 * (1 - available / total)


def cpu_usage(previous, current):
    total = current[0] - previous[0]
    idle = current[1] - previous[1]
    if total <= 0 or not 0 <= idle <= total:
        raise ValueError("Invalid host CPU sample interval")
    return 100 * (total - idle) / total


def container_usage(stats, host_memory, cpu_overloaded):
    memory = stats["memory_stats"]
    cache = memory.get("stats", {})
    # Match Docker's working-set accounting on cgroup v1 and v2.
    used = max(0, memory["usage"] - cache.get("total_inactive_file", cache.get("inactive_file", 0)))
    memory_percent = 100 * used / host_memory
    if not cpu_overloaded:
        return 0, memory_percent
    current, previous = stats["cpu_stats"], stats["precpu_stats"]
    elapsed = current["system_cpu_usage"] - previous["system_cpu_usage"]
    consumed = current["cpu_usage"]["total_usage"] - previous["cpu_usage"]["total_usage"]
    if elapsed <= 0 or consumed < 0:
        raise ValueError("Invalid container CPU sample interval")
    # A share of all host CPUs, rather than Docker's per-core percentage.
    return 100 * consumed / elapsed, memory_percent


def relieve_pressure(docker, cpu, memory, host_memory, stopping):
    if cpu <= THRESHOLD and memory <= THRESHOLD:
        return
    candidates = []
    for container in docker.request("GET", "/containers/json"):
        if (container.get("Labels") or {}).get("protected") == "true":
            continue
        container_id = container["Id"]
        try:
            stats = docker.request("GET", f"/containers/{container_id}/stats?stream=false")
            cpu_percent, memory_percent = container_usage(stats, host_memory, cpu > THRESHOLD)
        except DockerError as error:
            if error.status not in (404, 409):
                raise
            logging.warning("Container %s disappeared while sampling: %s", container_id, error)
            continue
        score = max(cpu_percent if cpu > THRESHOLD else 0,
                    memory_percent if memory > THRESHOLD else 0)
        candidates.append((score, container_id))
    for _, container_id in sorted(candidates, reverse=True):
        if stopping.is_set():
            return
        try:
            # Recheck labels and state immediately before the destructive operation.
            container = docker.request("GET", f"/containers/{container_id}/json")
            if ((container["Config"].get("Labels") or {}).get("protected") == "true"
                    or not container["State"]["Running"]):
                continue
            logging.warning("Host CPU %.1f%%, memory %.1f%%: stopping %s (%s)",
                            cpu, memory, container["Name"], container_id)
            docker.request("POST", f"/containers/{container_id}/stop?t={STOP_TIMEOUT}")
            logging.info("Stopped %s; waiting for a fresh host sample", container["Name"])
            return
        except DockerError as error:
            if error.status not in (404, 409):
                raise
            logging.warning("Container %s disappeared before stopping: %s", container_id, error)
    logging.warning("Host CPU %.1f%%, memory %.1f%%: no unprotected running containers",
                    cpu, memory)


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    stopping = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: stopping.set())
    docker = Docker()
    logging.info("Monitoring host every %ss; stopping containers only above %s%% CPU or memory; "
                 'protected="true" containers are excluded', INTERVAL, THRESHOLD)
    previous = None
    while not stopping.is_set():
        try:
            current = host_usage()
            if previous is not None:
                relieve_pressure(docker, cpu_usage(previous, current),
                                 current[3], current[2], stopping)
            # A stop can take 30 seconds; discard that interval before rechecking.
            previous = host_usage()
        except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException, DockerError):
            logging.exception("Host monitor failed; no further containers will be stopped this cycle")
            previous = None
        stopping.wait(INTERVAL)


if __name__ == "__main__":
    main()
