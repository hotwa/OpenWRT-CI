#!/usr/bin/env python3
"""Local read-only fixtures; no router, credentials or cloud access."""
import importlib.util
from pathlib import Path
import subprocess
import shlex
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cpe5g", Path(__file__).with_name("cpe5g.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class StatusFixtures(unittest.TestCase):
    def test_cellular_ledger_and_vendor_total_are_distinct(self):
        raw = "schema\tcpe5g-read-only-v1\nquota_used\t1748484\nquota_vendor_used\t8003632777\nquota_source\temmc-cellular-counters\nquota_blocked\tfalse\n"
        q = m.status_projection(raw)["sim"]["quota"]
        self.assertEqual(q["used_bytes"], 1748484)
        self.assertEqual(q["vendor_used_bytes"], 8003632777)
        self.assertEqual(q["source"], "emmc-cellular-counters")
        self.assertFalse(q["blocked"])

    def test_unknown_accounting_source_and_non_numeric_vendor_field_are_not_exposed(self):
        raw = "schema\tcpe5g-read-only-v1\nquota_source\tDO_NOT_DISPLAY\nquota_vendor_used\tDO_NOT_DISPLAY\n"
        q = m.status_projection(raw)["sim"]["quota"]
        self.assertIsNone(q["source"])
        self.assertIsNone(q["vendor_used_bytes"])
        self.assertNotIn("DO_NOT_DISPLAY", str(q))

    def test_missing_runtime_is_unknown_not_ready(self):
        result = m.status_projection("schema\tcpe5g-read-only-v1\napi_nerdctl_present\tfalse\napi_containerd_socket\tfalse\n", include_api=True)
        self.assertFalse(result["api"]["runtime"]["binary_present"])
        self.assertIsNone(result["api"]["container"]["running"])
        self.assertIsNone(result["api"]["origin"]["ready"])
        self.assertFalse(result["api"]["public_inference_verified"])

    def test_api_ready_does_not_imply_public_or_udx_ready(self):
        raw = "schema\tcpe5g-read-only-v1\norigin_ready\tfalse\napi_ready\ttrue\napi_shared_gate\tudx\napi_approved_host\tai.lucky.jmsu.top\napi_container_running\ttrue\napi_memory_limit\t201326592\napi_cpu_quota\t50000\napi_cpu_period\t100000\napi_pids\t8\ncredentials\tDO_NOT_DISPLAY\napi_memory_percent\t12.34%\n"
        result = m.status_projection(raw, include_api=True)
        self.assertTrue(result["api"]["origin"]["ready"])
        self.assertFalse(result["udx_origin"]["ready"])
        self.assertEqual(result["api"]["limits"]["memory_bytes"], 192 * 1024 * 1024)
        self.assertEqual(result["api"]["resources"]["pids"], 8)
        self.assertNotIn("DO_NOT_DISPLAY", str(result))
        self.assertTrue(result["api_publication"]["not_verified"])
        self.assertFalse(result["api"]["public_inference_verified"])

    def test_default_status_keeps_existing_projection(self):
        self.assertNotIn("api", m.status_projection("schema\tcpe5g-read-only-v1\napi_ready\ttrue\n"))

    def test_actual_nerdctl_partial_native_output_keeps_limits_aligned(self):
        row = "running|true|201326592|running|true|201326592|50000|100000|128"
        raw = "schema\tcpe5g-read-only-v1\napi_container_fields\t" + row + "\napi_resource_source\tcgroup-v2\napi_memory_current\t45248512\napi_memory_max\t201326592\napi_pids\t8\napi_cpu_usage_usec\t1715659\n"
        result = m.status_projection(raw, include_api=True)["api"]
        self.assertEqual(result["limits"], {"memory_bytes": 201326592, "cpu_quota": 50000, "cpu_period": 100000, "pids": 128})
        self.assertEqual(result["resources"], {"source": "cgroup-v2", "cpu_usage_usec": 1715659, "memory_current_bytes": 45248512, "memory_max_bytes": 201326592, "pids": 8})
        self.assertTrue(result["container"]["running"])
        self.assertEqual(m.container_projection(row), m.container_projection("running|true|201326592|50000|100000|128"))
        self.assertEqual(m.container_projection("running|true|201326592"), {})
        self.assertEqual(m.container_projection("exited|false|201326592|running|true|201326592|50000|100000|128"), {})

    def test_image_alias_requires_actual_manifest_and_arm64(self):
        pin = "docker.io/eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d"
        rows = [
            ("linux/arm64|" + pin + "|", True),
            ("linux/arm64|" + pin.removeprefix("docker.io/") + "|", True),
            ("linux/amd64|" + pin + "|", False),
            ("linux/arm64|docker.io/eceasy/cli-proxy-api:v8.0.13|", False),
            ("linux/arm64|" + pin[:-1] + "0|", False),
            ("", None),
        ]
        for row, expected in rows:
            with self.subTest(row=row):
                script = "kv() { printf '%s\\t%s\\n' \"$1\" \"$2\"; }\n" + m.REMOTE_IMAGE_PROJECTION + "\napi_image_projection " + shlex.quote(row)
                output = subprocess.run(["sh", "-s"], input=script, text=True, capture_output=True, check=True).stdout
                result = m.status_projection("schema\tcpe5g-read-only-v1\n" + output, include_api=True)
                self.assertIs(result["api"]["image"]["manifest_verified"], expected)
                self.assertNotIn(pin, str(result))

    def test_remote_script_shell_syntax(self):
        result = subprocess.run(["sh", "-n"], input=m.REMOTE_API_STATUS, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_api_status_uses_fixed_script_and_rejects_failure_output(self):
        with patch.object(m, "ssh_argv", return_value=["ssh", "fixture"]), patch.object(m.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "schema\tcpe5g-read-only-v1\napi_ready\tfalse\n", "SECRET")
            result = m.read_status({}, include_api=True)
            self.assertEqual(run.call_args.kwargs["input"], m.REMOTE_API_STATUS)
            self.assertFalse(result["api"]["origin"]["ready"])
            run.return_value = subprocess.CompletedProcess([], 1, "SECRET", "SECRET")
            with self.assertRaises(m.Invalid) as caught:
                m.read_status({}, include_api=True)
            self.assertNotIn("SECRET", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
