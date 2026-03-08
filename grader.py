#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from apex_arena._types import GradingResult

BLEATER_NS = "bleater"
LOG_NS = "logging"
DEPLOY = "bleat-service"
CONFIGMAP = "bleat-service-config"
EXPECTED_REDIS_URL = "redis://redis.bleater.svc.cluster.local:6379/0"
TASK_ROOT = Path(__file__).resolve().parent
UID_FILE = Path("/tmp/bleat-service-deployment-uid")
PODS_FILE = Path("/tmp/bleat-service-original-pods")


def run(cmd: str, timeout: int = 30):
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "command timed out"
    except Exception as exc:
        return -1, "", str(exc)


def wait_for_ready(timeout: int = 120) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, out, _ = run(
            f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json",
            timeout=20,
        )
        if code == 0 and out:
            try:
                dep = json.loads(out)
            except json.JSONDecodeError:
                time.sleep(3)
                continue
            spec = dep.get("spec", {}).get("replicas", 0)
            status = dep.get("status", {})
            ready = status.get("readyReplicas", 0)
            available = status.get("availableReplicas", 0)
            if spec == 2 and ready == 2 and available == 2:
                return True
        time.sleep(3)
    return False


def get_running_pods():
    code, out, _ = run(
        f"kubectl get pods -n {BLEATER_NS} -l app={DEPLOY} "
        "-o jsonpath='{range .items[*]}{.metadata.name}{\"\\n\"}{end}'"
    )
    if code != 0:
        return []
    return [line for line in out.splitlines() if line.strip()]


def get_loki_entries():
    code, pod_name, err = run(
        "kubectl get pods -n logging -l app=loki-gateway "
        "-o jsonpath='{.items[0].metadata.name}'"
    )
    if code != 0 or not pod_name:
        return False, f"Could not locate Loki pod: {err}", []

    code, out, err = run(
        f"kubectl exec -n {LOG_NS} {pod_name} -- cat /data/logs.jsonl",
        timeout=20,
    )
    if code != 0:
        return False, f"Could not read Loki log store: {err}", []

    entries = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return True, "Loki log store readable", entries


def check_live_configmap():
    code, out, err = run(
        f"kubectl get configmap {CONFIGMAP} -n {BLEATER_NS} -o json"
    )
    if code != 0:
        return False, f"Could not read live ConfigMap: {err}"

    try:
        configmap = json.loads(out)
        redis_url = configmap["data"]["REDIS_URL"]
    except Exception as exc:
        return False, f"Could not parse REDIS_URL from ConfigMap: {exc}"

    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in redis_url)
    ok = redis_url == EXPECTED_REDIS_URL and not has_control and "\r" not in redis_url
    if ok:
        return True, "Live ConfigMap REDIS_URL is clean and canonical"
    return False, f"Live ConfigMap REDIS_URL is still invalid: {redis_url!r}"


def check_repo_manifest():
    manifest = TASK_ROOT / "k8s" / "bleat-service-configmap.yaml"
    if not manifest.exists():
        return False, "Checked-out ConfigMap manifest is missing"

    text = manifest.read_text(encoding="utf-8", errors="strict")
    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in text)
    ok = (
        EXPECTED_REDIS_URL in text
        and "\\r" not in text
        and "\\x0d" not in text.lower()
        and "\\u000d" not in text.lower()
        and "\r" not in text
        and not has_control
    )
    if ok:
        return True, "Checked-out manifest is clean"
    return False, "Checked-out manifest still contains encoded or hidden control characters"


def check_uid_preserved():
    if not UID_FILE.exists():
        return False, "Missing stored original deployment UID"

    original_uid = UID_FILE.read_text(encoding="utf-8").strip()
    code, current_uid, err = run(
        f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o jsonpath='{{.metadata.uid}}'"
    )
    if code != 0:
        return False, f"Could not read current deployment UID: {err}"

    ok = bool(original_uid) and original_uid == current_uid
    if ok:
        return True, "Deployment object was preserved"
    return False, "Deployment UID changed; expected a rolling restart instead of recreation"


def check_rollout_restart():
    if not PODS_FILE.exists():
        return False, "Missing original pod snapshot"

    original_pods = {
        line.strip()
        for line in PODS_FILE.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    current_pods = set(get_running_pods())

    ok = bool(original_pods) and bool(current_pods) and original_pods.isdisjoint(current_pods)
    if ok:
        return True, "Pods were replaced during a rolling restart"
    return False, f"Rolling restart not detected; old={sorted(original_pods)}, current={sorted(current_pods)}"


def check_deployment_ready():
    ok = wait_for_ready(timeout=150)
    if ok:
        return True, "bleat-service deployment is fully Ready"
    return False, "bleat-service deployment never reached 2/2 Ready replicas"


def check_pod_env():
    pods = get_running_pods()
    if not pods:
        return False, "No bleat-service pods found"

    pod = pods[0]
    code, out, err = run(
        f"kubectl exec -n {BLEATER_NS} {pod} -- printenv REDIS_URL"
    )
    if code != 0:
        return False, f"Could not read REDIS_URL from running pod: {err}"

    ok = out == EXPECTED_REDIS_URL
    if ok:
        return True, "Running bleat-service pod uses the cleaned REDIS_URL"
    return False, f"Running pod still has stale REDIS_URL: {out!r}"


def check_loki_success():
    ok, msg, entries = get_loki_entries()
    if not ok:
        return False, msg

    success_entries = [
        entry for entry in entries
        if entry.get("labels", {}).get("app") == "bleat-service"
        and "redis connection established" in entry.get("message", "").lower()
    ]
    if success_entries:
        return True, "Loki contains a successful Redis connection log"
    return False, "Loki does not show a successful Redis connection log"


def check_loki_no_new_errors():
    ok, msg, entries = get_loki_entries()
    if not ok:
        return False, msg

    relevant = [
        entry for entry in entries
        if entry.get("labels", {}).get("app") == "bleat-service"
    ]
    if not relevant:
        return False, "No bleat-service entries found in Loki"

    success_ts = [
        int(entry.get("ts", "0"))
        for entry in relevant
        if "redis connection established" in entry.get("message", "").lower()
    ]
    if not success_ts:
        return False, "No successful Redis connection log found in Loki"

    latest_success = max(success_ts)
    newer_errors = [
        entry for entry in relevant
        if int(entry.get("ts", "0")) > latest_success
        and entry.get("labels", {}).get("level") == "error"
    ]
    if not newer_errors:
        return True, "No newer bleat-service error logs appear after Redis recovery"
    return False, "Loki still contains bleat-service error logs after the latest success event"


def check_validation_script():
    script = TASK_ROOT / "scripts" / "validate_configmap.py"
    if not script.exists():
        return False, "Validation script scripts/validate_configmap.py is missing"

    good_manifest = TASK_ROOT / "k8s" / "bleat-service-configmap.yaml"
    good = subprocess.run(
        [sys.executable, str(script), str(good_manifest)],
        capture_output=True,
        text=True,
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        bad_manifest = Path(tmpdir) / "bad.yaml"
        bad_manifest.write_text(
            "apiVersion: v1\n"
            "kind: ConfigMap\n"
            "metadata:\n"
            "  name: bad\n"
            "data:\n"
            '  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\\r"\n',
            encoding="utf-8",
        )
        bad = subprocess.run(
            [sys.executable, str(script), str(bad_manifest)],
            capture_output=True,
            text=True,
        )

    ok = good.returncode == 0 and bad.returncode != 0
    if ok:
        return True, "Validation script accepts clean manifests and rejects carriage-return corruption"
    return False, "Validation script behavior is incorrect"


def check_workflow_hook():
    workflow = TASK_ROOT / ".gitea" / "workflows" / "bleat-ci.yaml"
    if not workflow.exists():
        return False, "Workflow file .gitea/workflows/bleat-ci.yaml is missing"

    text = workflow.read_text(encoding="utf-8", errors="ignore")
    ok = "validate_configmap.py" in text and "k8s/bleat-service-configmap.yaml" in text
    if ok:
        return True, "CI workflow invokes the ConfigMap validation step"
    return False, "CI workflow does not call the ConfigMap validation step"


def grade(transcript: str) -> GradingResult:
    checks = {
        "live_configmap_clean": check_live_configmap,
        "repo_manifest_clean": check_repo_manifest,
        "deployment_uid_preserved": check_uid_preserved,
        "rolling_restart_detected": check_rollout_restart,
        "deployment_ready": check_deployment_ready,
        "pod_env_updated": check_pod_env,
        "loki_success_logged": check_loki_success,
        "loki_errors_cleared": check_loki_no_new_errors,
        "validation_script_enforced": check_validation_script,
        "workflow_hooks_validation": check_workflow_hook,
    }

    feedback_parts = []
    passed = {}
    for name, fn in checks.items():
        ok, message = fn()
        passed[name] = ok
        prefix = "PASS" if ok else "FAIL"
        feedback_parts.append(f"{prefix} {name}: {message}")

    weight = 1.0 / len(checks)
    weights = {name: weight for name in checks}
    score = sum(weights[name] for name, ok in passed.items() if ok)

    return GradingResult(
        score=score,
        subscores=passed,
        weights=weights,
        feedback=" | ".join(feedback_parts),
    )
