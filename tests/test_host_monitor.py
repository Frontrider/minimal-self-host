import importlib.util
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import socketserver
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("host_monitor", ROOT / "rootfs/etc/host-monitor/server.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


def stats(cpu, memory):
    return {
        "memory_stats": {"usage": memory, "stats": {}},
        "cpu_stats": {"system_cpu_usage": 2000, "cpu_usage": {"total_usage": 100 + cpu}},
        "precpu_stats": {"system_cpu_usage": 1000, "cpu_usage": {"total_usage": 100}},
    }


class HostMonitorTest(unittest.TestCase):
    def setUp(self):
        self.stopping = threading.Event()
        self.docker = Mock()
        self.containers = [
            {"Id": "protected", "Labels": {"protected": "true"}},
            {"Id": "cpu", "Labels": {}},
            {"Id": "memory", "Labels": {"protected": "false"}},
        ]
        self.protected = set()
        self.running = True
        self.samples = {"cpu": stats(800, 100), "memory": stats(100, 800)}
        self.docker.request.side_effect = self.request

    def request(self, method, path):
        if path == "/containers/json":
            return self.containers
        container_id = path.split("/")[2]
        if "/stats?" in path:
            return self.samples[container_id]
        if path.endswith("/json"):
            return {
                "Name": container_id,
                "Config": {"Labels": {"protected": "true"} if container_id in self.protected else {}},
                "State": {"Running": self.running},
            }
        return None

    def stops(self):
        return [call.args[1] for call in self.docker.request.call_args_list if call.args[0] == "POST"]

    def relieve(self, cpu, memory):
        monitor.relieve_pressure(self.docker, cpu, memory, 1000, self.stopping)

    def test_exact_threshold_does_not_stop(self):
        self.relieve(90, 90)
        self.docker.request.assert_not_called()

    def test_cpu_overload_stops_only_highest_cpu(self):
        self.relieve(90.01, 50)
        self.assertEqual(self.stops(), ["/containers/cpu/stop?t=30"])
        self.assertFalse(any("protected/" in call.args[1] for call in self.docker.request.call_args_list))

    def test_memory_overload_stops_only_highest_memory(self):
        self.relieve(50, 90.01)
        self.assertEqual(self.stops(), ["/containers/memory/stop?t=30"])

    def test_both_overloaded_rank_by_largest_host_share(self):
        self.samples["cpu"] = stats(900, 100)
        self.relieve(95, 95)
        self.assertEqual(self.stops(), ["/containers/cpu/stop?t=30"])

    def test_rechecks_pressure_before_another_stop(self):
        self.relieve(95, 20)
        self.relieve(40, 40)
        self.assertEqual(len(self.stops()), 1)

    def test_protection_is_rechecked_before_stop(self):
        self.protected.add("cpu")
        self.relieve(95, 20)
        self.assertEqual(self.stops(), ["/containers/memory/stop?t=30"])

    def test_stopped_containers_are_not_stopped_again(self):
        self.running = False
        self.relieve(95, 95)
        self.assertEqual(self.stops(), [])

    def test_shutdown_cancels_stops(self):
        self.stopping.set()
        self.relieve(95, 95)
        self.assertEqual(self.stops(), [])

    def test_all_protected_logs_without_stopping(self):
        self.containers = self.containers[:1]
        with self.assertLogs(level="WARNING") as logs:
            self.relieve(95, 95)
        self.assertIn("no unprotected", logs.output[0])
        self.assertEqual(self.stops(), [])

    def test_failed_stats_does_not_stop_arbitrary_container(self):
        self.samples["memory"] = {}
        with self.assertRaises(KeyError):
            self.relieve(95, 95)
        self.assertEqual(self.stops(), [])

    def test_disappearing_container_is_logged_and_skipped(self):
        original = self.request

        def request(method, path):
            if path == "/containers/cpu/json":
                raise monitor.DockerError(404, "gone")
            return original(method, path)

        self.docker.request.side_effect = request
        with self.assertLogs(level="WARNING"):
            self.relieve(95, 20)
        self.assertEqual(self.stops(), ["/containers/memory/stop?t=30"])

    def test_stop_failure_is_not_hidden(self):
        original = self.request

        def request(method, path):
            if method == "POST":
                raise monitor.DockerError(500, "stop failed")
            return original(method, path)

        self.docker.request.side_effect = request
        with self.assertRaises(monitor.DockerError):
            self.relieve(95, 95)
        self.assertEqual(len(self.stops()), 1)

    def test_host_metrics_use_available_memory_and_ignore_guest_ticks(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / "stat").write_text("cpu  90 0 0 10 0 0 0 0 50 0\ncpu0 90 0 0 10\n")
            (proc / "meminfo").write_text("MemTotal: 1000 kB\nMemAvailable: 100 kB\n")
            usage = monitor.host_usage(proc)
        self.assertEqual(usage[:3], (100, 10, 1024000))
        self.assertEqual(usage[3], 90)
        self.assertEqual(monitor.cpu_usage((100, 10), (200, 15)), 95)

    def test_invalid_host_samples_fail_explicitly(self):
        for current in ((100, 10), (90, 10), (200, 200)):
            with self.assertRaises(ValueError):
                monitor.cpu_usage((100, 10), current)

    def test_memory_working_set_handles_both_cgroup_versions(self):
        for key in ("inactive_file", "total_inactive_file"):
            sample = stats(500, 800)
            sample["memory_stats"]["stats"][key] = 300
            self.assertEqual(monitor.container_usage(sample, 1000, True), (50, 50))

    def test_api_checks_status_and_closes_connection(self):
        with patch.object(monitor, "DockerConnection") as factory:
            connection = factory.return_value
            response = connection.getresponse.return_value
            response.status = 200
            response.read.return_value = json.dumps(self.containers).encode()
            self.assertEqual(monitor.Docker().request("GET", "/containers/json"), self.containers)
            connection.request.assert_called_once_with("GET", "/containers/json")
            connection.close.assert_called_once()
            response.status = 403
            response.read.return_value = b"denied"
            with self.assertRaises(monitor.DockerError):
                monitor.Docker().request("POST", "/containers/cpu/stop?t=30")
            self.assertEqual(connection.close.call_count, 2)

    def test_api_over_unix_socket_without_access_to_host_docker(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(("GET", self.path))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"[]")

            def do_POST(self):
                requests.append(("POST", self.path))
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_):
                pass

        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "docker.sock")
            with socketserver.UnixStreamServer(path, Handler) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                try:
                    with patch.object(monitor, "DOCKER_SOCKET", path):
                        docker = monitor.Docker()
                        self.assertEqual(docker.request("GET", "/containers/json"), [])
                        self.assertIsNone(docker.request("POST", "/containers/test/stop?t=30"))
                finally:
                    server.shutdown()
                    worker.join()
        self.assertEqual(requests, [
            ("GET", "/containers/json"), ("POST", "/containers/test/stop?t=30"),
        ])

    def test_main_samples_again_after_action_and_waits_before_rechecking(self):
        stopping = Mock()
        stopping.is_set.side_effect = [False, False, True]
        first = (100, 0, 1000, 95)
        baseline = (200, 0, 1000, 95)
        overloaded = (300, 0, 1000, 95)
        after_stop = (400, 0, 1000, 40)
        with patch.object(monitor.threading, "Event", return_value=stopping), \
                patch.object(monitor.signal, "signal"), \
                patch.object(monitor, "Docker", return_value=self.docker), \
                patch.object(monitor, "host_usage", side_effect=[
                    first, baseline, overloaded, after_stop,
                ]) as sample, \
                patch.object(monitor, "relieve_pressure") as relieve:
            monitor.main()
        relieve.assert_called_once_with(self.docker, 100, 95, 1000, stopping)
        self.assertEqual(sample.call_count, 4)
        self.assertEqual(stopping.wait.call_args_list, [
            unittest.mock.call(60), unittest.mock.call(60),
        ])

    def test_main_logs_missing_host_metrics_without_stopping_containers(self):
        stopping = Mock()
        stopping.is_set.side_effect = [False, True]
        with patch.object(monitor.threading, "Event", return_value=stopping), \
                patch.object(monitor.signal, "signal"), \
                patch.object(monitor, "Docker", return_value=self.docker), \
                patch.object(monitor, "host_usage", side_effect=FileNotFoundError("host proc")), \
                self.assertLogs(level="ERROR") as logs:
            monitor.main()
        self.assertIn("Host monitor failed", logs.output[0])
        self.docker.request.assert_not_called()

    def test_s6_service_and_log_pipeline_are_enabled(self):
        services = ROOT / "rootfs/etc/s6-overlay/s6-rc.d"
        self.assertIn("python3 /etc/host-monitor/server.py", (services / "host-monitor/run").read_text())
        self.assertEqual((services / "host-monitor/type").read_text().strip(), "longrun")
        self.assertEqual((services / "host-monitor/producer-for").read_text().strip(), "host-monitor-log")
        self.assertEqual((services / "host-monitor-log/consumer-for").read_text().strip(), "host-monitor")
        pipeline = (services / "host-monitor-log/pipeline-name").read_text().strip()
        self.assertTrue((ROOT / "rootfs/etc/s6-overlay/user-bundles.d/user/contents.d" / pipeline).is_file())


if __name__ == "__main__":
    unittest.main()
