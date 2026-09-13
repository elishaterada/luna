#!/usr/bin/env python3
"""Run release Luna with isolated notes; no user data is read or written."""
import json, os, pathlib, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parents[1]
reports = []
for _ in range(3):
    with tempfile.TemporaryDirectory(prefix="luna-benchmark-") as temp:
        report = pathlib.Path(temp) / "metrics.json"
        env = dict(os.environ, LUNA_RECOVERY_DIR=temp + "/Recovery", LUNA_BENCHMARK_REPORT=str(report))
        started = time.monotonic()
        process = subprocess.run([str(root / "dist/Luna.app/Contents/MacOS/Luna")], env=env, capture_output=True, timeout=60)
        if process.returncode:
            raise RuntimeError(process.stderr.decode())
        data = json.loads(report.read_text())
        data["whole_benchmark_process_ms"] = (time.monotonic() - started) * 1000
        reports.append(data)
print(json.dumps(reports, indent=2))
