#!/usr/bin/env python3
import csv
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class YbaTests(unittest.TestCase):
    def test_summarizer_aggregates_ycsb_and_cpu(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            exp = Path(tmp) / "exp"
            raw = exp / "t300" / "r1" / "metrics" / "ycsb-raw"
            raw.mkdir(parents=True)
            (exp / "t300" / "r1" / "metrics").mkdir(parents=True, exist_ok=True)
            for src in (ROOT / "tests" / "fixtures" / "ycsb").glob("client-*.log"):
                (raw / src.name).write_text(src.read_text(), encoding="utf-8")
            (exp / "t300" / "r1" / "metrics" / "cpu-node-samples.csv").write_text(
                (ROOT / "tests" / "fixtures" / "cpu-node-samples.csv").read_text(),
                encoding="utf-8",
            )
            (exp / "t300" / "r1" / "meta").mkdir(parents=True)
            (exp / "t300" / "r1" / "meta" / "workload.env").write_text(
                "label=t300\nclients=2\nthreads_per_client=150\ntotal_threads=300\nops_per_client=100\n",
                encoding="utf-8",
            )

            subprocess.run(
                ["python3", str(ROOT / "tools" / "summarize-ycsb.py"), "--experiment-dir", str(exp)],
                check=True,
            )

            with (exp / "summary.csv").open(newline="", encoding="utf-8") as fh:
                rows = list(csv.DictReader(fh))
            self.assertEqual(len(rows), 1)
            row = rows[0]
            self.assertEqual(row["label"], "t300")
            self.assertEqual(float(row["throughput"]), 300.0)
            self.assertEqual(float(row["read_ops"]), 300.0)
            self.assertEqual(float(row["avg_latency"]), 1666.666667)
            self.assertEqual(float(row["p95_latency"]), 4000.0)
            self.assertEqual(float(row["p99_latency"]), 6000.0)
            self.assertEqual(float(row["p999_latency"]), 8000.0)
            self.assertEqual(row["error_count"], "0")

            with (exp / "cpu-node-summary.csv").open(newline="", encoding="utf-8") as fh:
                cpu_rows = list(csv.DictReader(fh))
            self.assertEqual(float(cpu_rows[0]["nodes012_busy_avg"]), 30.0)

    def test_cli_help_runs(self):
        result = subprocess.run(
            [str(ROOT / "bin" / "yba"), "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)

    def test_ssh_layer_uses_role_specific_options(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ssh.sh"
SERVER_HOST=kunpen183
CLIENT_HOST=ubuntu197
SSH_OPTS='-o Global=yes'
SERVER_SSH_OPTS='-F /tmp/server_config -p 22183'
CLIENT_SSH_OPTS='-F /tmp/client_config -p 22197'
SERVER_RSYNC_RSH=''
CLIENT_RSYNC_RSH=''
yba_apply_defaults
printf 'server=%s\\n' "$(yba_ssh_cmd_for_host "$SERVER_HOST")"
printf 'client=%s\\n' "$(yba_ssh_cmd_for_host "$CLIENT_HOST")"
printf 'server_rsync=%s\\n' "$(yba_rsync_rsh_for_host "$SERVER_HOST")"
printf 'client_rsync=%s\\n' "$(yba_rsync_rsh_for_host "$CLIENT_HOST")"
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("server=ssh -o Global=yes -F /tmp/server_config -p 22183", result.stdout)
        self.assertIn("client=ssh -o Global=yes -F /tmp/client_config -p 22197", result.stdout)
        self.assertIn("server_rsync=ssh -o Global=yes -F /tmp/server_config -p 22183", result.stdout)
        self.assertIn("client_rsync=ssh -o Global=yes -F /tmp/client_config -p 22197", result.stdout)


if __name__ == "__main__":
    unittest.main()
