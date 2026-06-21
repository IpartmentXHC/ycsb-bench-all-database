#!/usr/bin/env python3
import csv
import subprocess
import tempfile
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

    def test_cgroup_auto_config_writes_expected_cpuset_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "doris-bench"
            server = root / "doris"
            client = root / "ycsb"
            for directory in (root, server, client):
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "cpuset.cpus").write_text("", encoding="utf-8")
                (directory / "cpuset.mems").write_text("", encoding="utf-8")
            (root / "cgroup.controllers").write_text("cpuset memory\n", encoding="utf-8")
            (root / "cgroup.subtree_control").write_text("", encoding="utf-8")

            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/cgroup.sh"
ENABLE_CGROUP=1
CGROUP_AUTO_CONFIG=1
CGROUP_WRITE_WITH_SUDO=0
CGROUP_ROOT={str(root)!r}
SERVER_CGROUP={str(server)!r}
CLIENT_CGROUP={str(client)!r}
SERVER_CPUSET_EXPECT=0-63
SERVER_MEMS_EXPECT=0-1
CLIENT_CPUSET_EXPECT=64-127
CLIENT_MEMS_EXPECT=2-3
yba_apply_defaults
yba_preflight_cgroup
printf 'server_cpus=%s\\n' "$(cat "$SERVER_CGROUP/cpuset.cpus")"
printf 'server_mems=%s\\n' "$(cat "$SERVER_CGROUP/cpuset.mems")"
printf 'client_cpus=%s\\n' "$(cat "$CLIENT_CGROUP/cpuset.cpus")"
printf 'client_mems=%s\\n' "$(cat "$CLIENT_CGROUP/cpuset.mems")"
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("server_cpus=0-63", result.stdout)
            self.assertIn("server_mems=0-1", result.stdout)
            self.assertIn("client_cpus=64-127", result.stdout)
            self.assertIn("client_mems=2-3", result.stdout)

    def test_cgroup_pid_write_failure_reports_permission_hint(self):
        with tempfile.TemporaryDirectory() as tmp:
            cgroup = Path(tmp) / "doris"
            cgroup.mkdir()
            procs = cgroup / "cgroup.procs"
            procs.write_text("", encoding="utf-8")
            procs.chmod(0o400)

            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/cgroup.sh"
CGROUP_PROCS_WRITE_WITH_SUDO=0
CGROUP_WRITE_WITH_SUDO=0
yba_apply_defaults
yba_cgroup_write_pid $$ {str(cgroup)!r}
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot move pid", result.stderr)
            self.assertIn("CGROUP_PROCS_WRITE_WITH_SUDO=1", result.stderr)

    def test_cgroup_procs_write_uses_separate_sudo_switch(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "sudo-marker.txt"
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/cgroup.sh"
CGROUP_WRITE_WITH_SUDO=0
CGROUP_PROCS_WRITE_WITH_SUDO=1
SUDO_ASKPASS=/tmp/askpass
yba_apply_defaults
declare -f sudo >/dev/null 2>&1 && unset -f sudo
sudo() {{
  printf 'sudo_args=%s\\n' "$*" > {str(marker)!r}
  cat >/dev/null
}}
yba_cgroup_write_pid 123 /tmp
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8").strip(), "sudo_args=-A tee /tmp/cgroup.procs")

    def test_cgroup_role_preflight_checks_only_requested_side(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "doris-bench"
            server = root / "doris"
            client = root / "ycsb"
            for directory in (root, server, client):
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "cpuset.cpus").write_text("", encoding="utf-8")
                (directory / "cpuset.mems").write_text("", encoding="utf-8")
            (root / "cgroup.controllers").write_text("cpuset memory\n", encoding="utf-8")
            (root / "cgroup.subtree_control").write_text("", encoding="utf-8")

            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/cgroup.sh"
ENABLE_CGROUP=1
CGROUP_AUTO_CONFIG=1
CGROUP_WRITE_WITH_SUDO=0
CGROUP_PROCS_SMOKE_TEST=0
CGROUP_ROOT={str(root)!r}
SERVER_CGROUP={str(server)!r}
CLIENT_CGROUP=/missing/client/cgroup
SERVER_CPUSET_EXPECT=0-63
SERVER_MEMS_EXPECT=0-1
CLIENT_CPUSET_EXPECT=64-127
CLIENT_MEMS_EXPECT=2-3
yba_apply_defaults
yba_preflight_cgroup_role server
printf 'server_cpus=%s\\n' "$(cat "$SERVER_CGROUP/cpuset.cpus")"
printf 'server_mems=%s\\n' "$(cat "$SERVER_CGROUP/cpuset.mems")"
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("server_cpus=0-63", result.stdout)
            self.assertIn("server_mems=0-1", result.stdout)

    def test_doris_swap_check_requires_explicit_sudo_when_swap_is_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            swaps = Path(tmp) / "swaps"
            swaps.write_text(
                "Filename\tType\tSize\tUsed\tPriority\n/swapfile\tfile\t1024\t0\t-2\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/database.sh"
DORIS_PROC_SWAPS={str(swaps)!r}
DORIS_SWAPOFF_WITH_SUDO=0
yba_apply_defaults
yba_doris_check_swap
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("swap is enabled", result.stderr)
            self.assertIn("sudo swapoff -a", result.stderr)

    def test_doris_swapoff_with_sudo_uses_askpass_when_configured(self):
        with tempfile.TemporaryDirectory() as tmp:
            swaps = Path(tmp) / "swaps"
            marker = Path(tmp) / "sudo-marker.txt"
            swaps.write_text(
                "Filename\tType\tSize\tUsed\tPriority\n/swapfile\tfile\t1024\t0\t-2\n",
                encoding="utf-8",
            )
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/database.sh"
DORIS_PROC_SWAPS={str(swaps)!r}
DORIS_SWAPOFF_WITH_SUDO=1
SUDO_ASKPASS=/tmp/askpass
yba_apply_defaults
declare -f sudo >/dev/null 2>&1 && unset -f sudo
sudo() {{
  printf 'sudo_args=%s\\n' "$*" > {str(marker)!r}
}}
yba_doris_check_swap
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8").strip(), "sudo_args=-A swapoff -a")

    def test_doris_preflight_allows_custom_setup_without_bundled_scripts(self):
        with tempfile.TemporaryDirectory() as tmp:
            swaps = Path(tmp) / "swaps"
            swaps.write_text("Filename\tType\tSize\tUsed\tPriority\n", encoding="utf-8")
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/database.sh"
DB_TYPE=doris
DORIS_HOME=/missing/doris
DORIS_PROC_SWAPS={str(swaps)!r}
SERVER_SETUP_CMD='echo custom setup'
yba_apply_defaults
yba_database_preflight_server
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_doris_defaults_include_be_and_fe_pid_discovery(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/database.sh"
yba_apply_defaults
printf '%s\\n' "$SERVER_PID_COMMAND"
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pgrep -x doris_be", result.stdout)
        self.assertIn('org[.]apache[.]doris[.]DorisFE', result.stdout)

    def test_new_doris_examples_are_sourceable_and_use_database_defaults(self):
        examples = [
            ROOT / "examples" / "doris" / "singlehost-baseline.env",
            ROOT / "examples" / "doris" / "dualhost-baseline.env",
            ROOT / "examples" / "doris" / "singlehost-cgroup2.env",
            ROOT / "examples" / "doris" / "dualhost-cgroup2.env",
            ROOT / "examples" / "doris" / "thread-cluster.env",
        ]
        for example in examples:
            with self.subTest(example=example.name):
                script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/database.sh"
source {str(example)!r}
yba_apply_defaults
test "$DB_TYPE" = doris
test -n "$DORIS_HOME"
test -n "$JDBC_URL"
test -n "$MATRIX"
"""
                result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertEqual(result.returncode, 0, f"{example}: {result.stderr}")

    def test_singlehost_baseline_config_sets_python2_library_path(self):
        script = f"""
set -euo pipefail
source {str(ROOT / "examples" / "doris" / "singlehost-baseline.env")!r}
test "$PYTHON2_LD_LIBRARY_PATH" = /usr/local/python2.7/lib
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_remote_env_prefix_exports_database_settings(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ssh.sh"
DB_TYPE=doris
DORIS_HOME=/opt/doris
DORIS_SWAPOFF_WITH_SUDO=1
yba_apply_defaults
yba_remote_env_prefix
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DB_TYPE=doris", result.stdout)
        self.assertIn("DORIS_HOME=/opt/doris", result.stdout)
        self.assertIn("DORIS_SWAPOFF_WITH_SUDO=1", result.stdout)

    def test_ycsb_preflight_uses_python2_library_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            ycsb_home = Path(tmp) / "ycsb"
            (ycsb_home / "bin").mkdir(parents=True)
            (ycsb_home / "lib").mkdir()
            ycsb_bin = ycsb_home / "bin" / "ycsb"
            ycsb_bin.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            ycsb_bin.chmod(0o755)
            jar = ycsb_home / "lib" / "mysql.jar"
            jar.write_text("", encoding="utf-8")
            marker = Path(tmp) / "python2-env.txt"
            fakebin = Path(tmp) / "bin"
            fakebin.mkdir()
            python2 = fakebin / "python2"
            python2.write_text(
                f"#!/usr/bin/env bash\nprintf '%s\\n' \"$LD_LIBRARY_PATH\" > {str(marker)!r}\n",
                encoding="utf-8",
            )
            python2.chmod(0o755)
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ssh.sh"
source "$YBA_ROOT/lib/ycsb.sh"
PATH={str(fakebin)!r}:$PATH
YCSB_HOME={str(ycsb_home)!r}
JDBC_JAR={str(jar)!r}
PYTHON2_BIN=python2
PYTHON2_LD_LIBRARY_PATH=/custom/python/lib
yba_apply_defaults
yba_preflight_host_ycsb localhost
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8").strip(), "/custom/python/lib")

    def test_start_metrics_detaches_background_sampler_stdio(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp) / "run"
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/metrics.sh"
EXPERIMENT_DIR={str(Path(tmp) / "exp")!r}
RUN_SECONDS=5
ENABLE_NODE_CPU_SAMPLER=1
ENABLE_VMSTAT=0
ENABLE_NUMASTAT=0
yba_apply_defaults
yba_start_metrics {str(run_dir)!r} >/tmp/yba-metrics-stdout.txt 2>/tmp/yba-metrics-stderr.txt
test -f {str(run_dir / "metrics" / "cpu-sampler.pid")!r}
sleep 1
yba_stop_metrics {str(run_dir)!r}
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_ready_timeout_defaults_to_120_seconds(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
yba_apply_defaults
printf '%s\\n' "$SERVER_READY_TIMEOUT"
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "120")

    def test_default_doris_ready_command_preserves_select_query_quoting(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
yba_apply_defaults
printf '%s\\n' "$SERVER_READY_CMD"
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-e "select 1"', result.stdout)

    def test_wait_server_ready_retries_until_command_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "attempts"
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ycsb.sh"
SERVER_READY_TIMEOUT=3
SERVER_READY_INTERVAL=1
READY_MARKER={str(marker)!r}
export READY_MARKER
SERVER_READY_CMD='count=0; [ -f "$READY_MARKER" ] && count=$(cat "$READY_MARKER"); count=$((count + 1)); echo "$count" > "$READY_MARKER"; [ "$count" -ge 2 ]'
yba_apply_defaults
yba_wait_server_ready
cat "$READY_MARKER"
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip().splitlines()[-1], "2")

    def test_wait_server_ready_fails_after_timeout(self):
        script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ycsb.sh"
SERVER_READY_TIMEOUT=1
SERVER_READY_INTERVAL=1
SERVER_READY_CMD='exit 1'
yba_apply_defaults
yba_wait_server_ready
"""
        result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("server ready check timed out after 1s", result.stderr)

    def test_meta_common_uses_generic_server_artifact_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp) / "run"
            script = f"""
set -euo pipefail
YBA_ROOT={str(ROOT)!r}
source "$YBA_ROOT/lib/common.sh"
source "$YBA_ROOT/lib/ycsb.sh"
EXPERIMENT_DIR={str(Path(tmp) / "exp")!r}
ENABLE_CGROUP=0
yba_apply_defaults
yba_write_meta_common {str(run_dir)!r}
test -d {str(run_dir / "server")!r}
"""
            result = subprocess.run(["bash", "-lc", script], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
