#!/usr/bin/env python3
"""
Grader for: bleat-service Sev-1 incident response
Scoring: 10 checks × 0.10 weight each = 1.0 max score
"""

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

TASK_ROOT = Path("/home/ubuntu/bleater-app")
UID_FILE = Path("/tmp/bleat-service-deployment-uid")
PODS_FILE = Path("/tmp/bleat-service-original-pods")

# ────────────────────────────────────────────────────────────────────────────
REQUIRED_CONSTANTS = {
    "_ROUTING_RETRY_DELAY_MS":  "0",
    "_MIN_TTL_FLOOR_MS":        "3600",
    "_cap_mode_flag":           "true",
    "_EVENT_TTL_GRACE_MS":      "500",
    "_PIPELINE_SCHEMA_VERSION": "3",
    "_FANOUT_CAP_ENABLED":      "false",
}

ROGUE_CRONJOB_NS   = "kube-system"
ROGUE_CRONJOB_NAME = "resource-quota-sync-controller"

ROGUE_CRONJOB_NS_2   = "monitoring"
ROGUE_CRONJOB_NAME_2 = "metrics-pipeline-controller"

ROGUE_CRONJOB_NS_3   = "default"
ROGUE_CRONJOB_NAME_3 = "audit-log-archiver"


def run(cmd: str, timeout: int = 30):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "command timed out"
    except Exception as exc:
        return -1, "", str(exc)


def wait_for_ready(timeout: int = 120) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, out, _ = run(
            f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json", timeout=20
        )
        if code == 0 and out:
            try:
                dep = json.loads(out)
                spec   = dep.get("spec", {}).get("replicas", 0)
                status = dep.get("status", {})
                ready  = status.get("readyReplicas", 0)
                avail  = status.get("availableReplicas", 0)
                if spec == 2 and ready == 2 and avail == 2:
                    return True
            except json.JSONDecodeError:
                pass
        time.sleep(3)
    return False


def get_running_pods():
    code, out, _ = run(f"kubectl get pods -n {BLEATER_NS} -l app={DEPLOY} -o json")
    if code != 0:
        return []
    try:
        data = json.loads(out)
        return [
            p["metadata"]["name"]
            for p in data.get("items", [])
            if not p["metadata"].get("deletionTimestamp")
            and p["metadata"]["name"].startswith(f"{DEPLOY}-")
        ]
    except Exception:
        return []


def get_loki_entries():
    code, pod_name, err = run(
        "kubectl get pods -n logging -l app=loki-gateway"
        " -o jsonpath='{.items[0].metadata.name}'"
    )
    if code != 0 or not pod_name:
        return False, f"Could not locate Loki pod: {err}", []
    code, out, err = run(
        f"kubectl exec -n {LOG_NS} {pod_name} -- cat /data/logs.jsonl", timeout=20
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


# ─────────────────────────── individual checks ──────────────────────────────

def check_live_configmap():
    """
    The live ConfigMap must:
      1. Have REDIS_URL free of all control characters and escape sequences.
      2. Carry all six production constants with exact string values.
      3. Not be subject to active re-corruption (rogue CronJob must be gone).
    """
    # Guard: BOTH rogue CronJobs must be absent before we trust the live state.
    cj_exists_code, cj_out, _ = run(
        f"kubectl get cronjob {ROGUE_CRONJOB_NAME} -n {ROGUE_CRONJOB_NS}"
        " -o jsonpath='{{.metadata.name}}'"
    )
    if cj_exists_code == 0 and cj_out.strip():
        return (
            False,
            f"Rogue re-corruption CronJob '{ROGUE_CRONJOB_NAME}' still exists in"
            f" namespace '{ROGUE_CRONJOB_NS}'; ConfigMap cannot be considered stable",
        )

    cj2_exists_code, cj2_out, _ = run(
        f"kubectl get cronjob {ROGUE_CRONJOB_NAME_2} -n {ROGUE_CRONJOB_NS_2}"
        " -o jsonpath='{{.metadata.name}}'"
    )
    if cj2_exists_code == 0 and cj2_out.strip():
        return (
            False,
            f"Rogue re-corruption CronJob '{ROGUE_CRONJOB_NAME_2}' still exists in"
            f" namespace '{ROGUE_CRONJOB_NS_2}'; ConfigMap cannot be considered stable",
        )

    cj3_exists_code, cj3_out, _ = run(
        f"kubectl get cronjob {ROGUE_CRONJOB_NAME_3} -n {ROGUE_CRONJOB_NS_3}"
        " -o jsonpath='{{.metadata.name}}'"
    )
    if cj3_exists_code == 0 and cj3_out.strip():
        return (
            False,
            f"Rogue re-corruption CronJob '{ROGUE_CRONJOB_NAME_3}' still exists in"
            f" namespace '{ROGUE_CRONJOB_NS_3}'; ConfigMap cannot be considered stable",
        )

    code, out, err = run(
        f"kubectl get configmap {CONFIGMAP} -n {BLEATER_NS} -o json"
    )
    if code != 0:
        return False, f"Could not read live ConfigMap: {err}"
    try:
        configmap = json.loads(out)
        data = configmap.get("data", {})
    except Exception as exc:
        return False, f"Could not parse ConfigMap JSON: {exc}"

    # Check all six constants.
    for key, expected in REQUIRED_CONSTANTS.items():
        actual = data.get(key)
        if actual is None:
            return False, f"Production constant '{key}' is missing from live ConfigMap"
        if actual != expected:
            return (
                False,
                f"Production constant '{key}' has wrong value"
                f" (got {actual!r}, expected {expected!r})",
            )

    redis_url = data.get("REDIS_URL", "")
    has_control = any(
        (ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in redis_url
    )
    if redis_url == EXPECTED_REDIS_URL and not has_control and "\r" not in redis_url:
        return True, "Live ConfigMap REDIS_URL is clean; all production constants present"
    return False, f"Live ConfigMap REDIS_URL is still invalid: {redis_url!r}"


def check_repo_manifest():
    """
    The checked-out manifest must contain all six production constants and a
    clean REDIS_URL with no control characters or encoded escape sequences.
    """
    manifest = TASK_ROOT / "k8s" / "bleat-service-configmap.yaml"
    if not manifest.exists():
        return False, "Checked-out ConfigMap manifest is missing"
    text = manifest.read_text(encoding="utf-8", errors="strict")

    for key in REQUIRED_CONSTANTS:
        if key not in text:
            return (
                False,
                f"Repo manifest is missing production constant '{key}';"
                " harness file integrity compromised",
            )

    # Verify exact constant values appear in the manifest text.
    for key, expected in REQUIRED_CONSTANTS.items():
        if f'"{expected}"' not in text and f"'{expected}'" not in text and expected not in text:
            return (
                False,
                f"Repo manifest constant '{key}' does not carry expected value"
                f" {expected!r}",
            )

    has_control = any(
        (ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in text
    )
    if (
        EXPECTED_REDIS_URL in text
        and "\\r" not in text
        and "\r" not in text
        and not has_control
    ):
        return True, "Checked-out manifest is clean and contains all production constants"
    return False, "Checked-out manifest still contains encoded or hidden control characters"


def check_uid_preserved():
    if not UID_FILE.exists():
        return False, "Missing stored original deployment UID"
    original_uid = UID_FILE.read_text(encoding="utf-8").strip()
    code, out, err = run(
        f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json"
    )
    if code != 0:
        return False, f"Could not read current deployment: {err}"
    dep = json.loads(out)
    current_uid = dep.get("metadata", {}).get("uid")
    ann = (
        dep.get("spec", {})
        .get("template", {})
        .get("metadata", {})
        .get("annotations", {})
    )
    if original_uid != current_uid:
        return False, "Deployment UID changed; a delete+recreate was performed instead of rolling restart"
    if ann.get("bleater.io/bind-count") != "1":
        return False, "Internal bleater.io/bind-count annotation was destroyed or mutated"
    return True, "Deployment object UID and bind-count annotation preserved"


def check_rollout_restart():
    if not PODS_FILE.exists():
        return False, "Missing original pod snapshot"
    original_pods = {
        line.strip()
        for line in PODS_FILE.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    current_pods = set(get_running_pods())
    if bool(original_pods) and bool(current_pods) and original_pods.isdisjoint(current_pods):
        return True, "Pods were replaced during a rolling restart"
    return (
        False,
        f"Rolling restart not detected; old={sorted(original_pods)},"
        f" new={sorted(current_pods)}",
    )


def check_deployment_ready():
    if wait_for_ready(timeout=120):
        return True, "bleat-service deployment is fully Ready (2/2)"
    return False, "bleat-service deployment never reached 2/2 Ready replicas within timeout"


def check_pod_env():
    pods = get_running_pods()
    if not pods:
        return False, "No bleat-service pods found"
    code, out, err = run(
        f"kubectl exec -n {BLEATER_NS} {pods[0]} -- printenv REDIS_URL"
    )
    if code != 0:
        return False, f"Could not read REDIS_URL from running pod: {err}"
    if out == EXPECTED_REDIS_URL:
        return True, "Running bleat-service pod carries the cleaned REDIS_URL"
    return False, f"Running pod still has stale REDIS_URL: {out!r}"


def check_loki_success():
    ok, msg, entries = get_loki_entries()
    if not ok:
        return False, msg
    success = [
        e
        for e in entries
        if e.get("labels", {}).get("app") == "bleat-service"
        and "redis connection established" in e.get("message", "").lower()
    ]
    if success:
        return True, "Loki contains a successful Redis connection log"
    return False, "Loki does not contain a successful Redis connection log"


def check_loki_no_new_errors():
    ok, msg, entries = get_loki_entries()
    if not ok:
        return False, msg
    relevant = [
        e for e in entries if e.get("labels", {}).get("app") == "bleat-service"
    ]
    success_ts = [
        int(e.get("ts", "0"))
        for e in relevant
        if "redis connection established" in e.get("message", "").lower()
    ]
    if not success_ts:
        return False, "No successful Redis connection log found in Loki"
    latest_success = max(success_ts)
    newer_errors = [
        e
        for e in relevant
        if int(e.get("ts", "0")) > latest_success
        and e.get("labels", {}).get("level") == "error"
    ]
    if not newer_errors:
        return True, "No bleat-service error logs appear after the latest Redis success event"
    return (
        False,
        f"Loki still contains {len(newer_errors)} bleat-service error log(s)"
        " after the latest success event (rogue re-corruption still active?)",
    )


def check_validation_script():
    """
    The validation script must:
      - Accept clean manifests (exit 0).
      - Reject manifests containing a real carriage-return byte (\\x0d).
      - Reject manifests containing the *escaped* literal string '\\r'
        (two characters: backslash + r), which is the form introduced by
        Windows-edited YAML files.
      - Reject manifests containing null bytes (\\x00), which can appear
        after certain text-editor round-trips.
    """
    script = TASK_ROOT / "scripts" / "validate_configmap.py"
    if not script.exists():
        return False, "Validation script scripts/validate_configmap.py is missing"

    with tempfile.TemporaryDirectory() as tmpdir:
        # Case 1: clean manifest — must pass.
        good = Path(tmpdir) / "good.yaml"
        good.write_text(
            f'REDIS_URL: "{EXPECTED_REDIS_URL}"\n', encoding="utf-8"
        )
        r_good = subprocess.run(
            [sys.executable, str(script), str(good)],
            capture_output=True, text=True,
        )

        # Case 2: manifest with escaped literal \\r (backslash + r in file).
        bad_esc = Path(tmpdir) / "bad_escaped.yaml"
        bad_esc.write_text(
            f'REDIS_URL: "{EXPECTED_REDIS_URL}\\r"\n', encoding="utf-8"
        )
        r_bad_esc = subprocess.run(
            [sys.executable, str(script), str(bad_esc)],
            capture_output=True, text=True,
        )

        # Case 3: manifest with a real carriage-return byte.
        bad_real = Path(tmpdir) / "bad_real.yaml"
        bad_real.write_bytes(
            f'REDIS_URL: "{EXPECTED_REDIS_URL}\r"\n'.encode("utf-8")
        )
        r_bad_real = subprocess.run(
            [sys.executable, str(script), str(bad_real)],
            capture_output=True, text=True,
        )

        # Case 4: manifest with a null byte.
        bad_null = Path(tmpdir) / "bad_null.yaml"
        bad_null.write_bytes(
            f'REDIS_URL: "{EXPECTED_REDIS_URL}\x00"\n'.encode("utf-8")
        )
        r_bad_null = subprocess.run(
            [sys.executable, str(script), str(bad_null)],
            capture_output=True, text=True,
        )

    passes = r_good.returncode == 0
    rejects_esc  = r_bad_esc.returncode  != 0
    rejects_real = r_bad_real.returncode != 0
    rejects_null = r_bad_null.returncode != 0

    if passes and rejects_esc and rejects_real and rejects_null:
        return True, "Validation script correctly accepts clean and rejects all corrupt manifests"

    failures = []
    if not passes:        failures.append("accepted a clean manifest (should exit 0)")
    if not rejects_esc:   failures.append("did not reject escaped-literal \\r in manifest")
    if not rejects_real:  failures.append("did not reject real carriage-return byte")
    if not rejects_null:  failures.append("did not reject null-byte corruption")
    return False, "Validation script failures: " + "; ".join(failures)


def check_workflow_hook():
    workflow = TASK_ROOT / ".gitea" / "workflows" / "bleat-ci.yaml"
    if not workflow.exists():
        return False, "Gitea CI workflow file is missing"
    text = workflow.read_text(encoding="utf-8", errors="ignore")
    if "validate_configmap.py" in text and "k8s/bleat-service-configmap.yaml" in text:
        return True, "CI workflow invokes the ConfigMap validation step"
    return False, "CI workflow does not call validate_configmap.py on the ConfigMap manifest"


# ─────────────────────────────── grade() ────────────────────────────────────

def grade(transcript: str) -> GradingResult:
    checks = {
        "live_configmap_clean":        check_live_configmap,
        "repo_manifest_clean":         check_repo_manifest,
        "deployment_uid_preserved":    check_uid_preserved,
        "rolling_restart_detected":    check_rollout_restart,
        "deployment_ready":            check_deployment_ready,
        "pod_env_updated":             check_pod_env,
        "loki_success_logged":         check_loki_success,
        "loki_errors_cleared":         check_loki_no_new_errors,
        "validation_script_enforced":  check_validation_script,
        "workflow_hooks_validation":   check_workflow_hook,
    }

    feedback_parts, passed = [], {}
    for name, fn in checks.items():
        ok, message = fn()
        passed[name] = ok
        feedback_parts.append(f"{'PASS' if ok else 'FAIL'} {name}: {message}")

    weight = 1.0 / len(checks)
    weights = {name: weight for name in checks}
    score = sum(weights[name] for name, ok in passed.items() if ok)

    return GradingResult(
        score=score,
        subscores=passed,
        weights=weights,
        feedback=" | ".join(feedback_parts),
    )