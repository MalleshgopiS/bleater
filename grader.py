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
TASK_ROOT = Path("/home/ubuntu/bleater-app")

def run(cmd: str, timeout: int = 30):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "command timed out"
    except Exception as exc:
        return -1, "", str(exc)

def wait_for_ready(timeout: int = 150) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        code, out, _ = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json", timeout=20)
        if code == 0 and out:
            try:
                dep = json.loads(out)
                spec = dep.get("spec", {}).get("replicas", 0)
                status = dep.get("status", {})
                ready = status.get("readyReplicas", 0)
                available = status.get("availableReplicas", 0)
                if spec == 2 and ready == 2 and available == 2:
                    return True
            except json.JSONDecodeError:
                pass
        time.sleep(3)
    return False

def get_running_pods():
    code, out, _ = run(f"kubectl get pods -n {BLEATER_NS} -l app={DEPLOY} -o json")
    if code != 0: return []
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
    code, pod_name, err = run("kubectl get pods -n logging -l app=loki-gateway -o jsonpath='{.items[0].metadata.name}'")
    if code != 0 or not pod_name: return False, f"Could not locate Loki pod: {err}", []
    code, out, err = run(f"kubectl exec -n {LOG_NS} {pod_name} -c loki-gateway -- cat /data/logs.jsonl", timeout=20)
    if code != 0: return False, f"Could not read Loki log store: {err}", []
    entries = []
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        try: entries.append(json.loads(line))
        except json.JSONDecodeError: continue
    return True, "Loki log store readable", entries

def check_infrastructure_traps():
    """Verifies that the stealth traps (Quota, LimitRange, PDB, malicious Policies, Sidecar, Optimizer, and Deployment Reverter) are deleted, while valid policies remain."""
    rq, _, _ = run(f"kubectl get resourcequota default-mem-limit -n {BLEATER_NS}")
    lr, _, _ = run(f"kubectl get limitrange hidden-mem-limit -n {BLEATER_NS}")
    np1, _, _ = run(f"kubectl get networkpolicy kube-dns-allow -n {BLEATER_NS}")
    np2, _, _ = run(f"kubectl get networkpolicy loki-deny-all -n {LOG_NS}")
    pdb, _, _ = run(f"kubectl get pdb bleat-service-pdb -n {BLEATER_NS}")
    opt, _, _ = run(f"kubectl get deployment redis-autoscaler -n kube-system")
    dh, _, _ = run(f"kubectl get deployment kube-dns-healthcheck -n kube-system")
    
    code, np_out, _ = run(f"kubectl get networkpolicy -n {BLEATER_NS} -o name")
    has_random_np = any("total-block-policy-" in line for line in np_out.splitlines())
    
    code, sidecar_out, _ = run(f"kubectl get deployment loki-gateway -n {LOG_NS} -o jsonpath='{{.spec.template.spec.containers[*].name}}'")
    has_sidecar = "metrics-sidecar" in sidecar_out
    has_valid_decoy = "fluent-bit-logger" in sidecar_out
    
    valid_np, _, _ = run(f"kubectl get networkpolicy baseline-security-rules -n {BLEATER_NS}")
    
    if rq != 0 and lr != 0 and np1 != 0 and np2 != 0 and pdb != 0 and opt != 0 and dh != 0 and not has_sidecar and has_valid_decoy and not has_random_np and valid_np == 0:
        return True, "Stealth traps cleared, valid secondary logger preserved, and valid policies preserved"
    return False, "Traps are still active, valid logger was deleted, or valid policies were deleted"

def check_deployment_sabotage_fixed():
    """Verifies that the invalid affinity and initContainers were removed and the readinessProbe is on port 8080."""
    code, out, _ = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o jsonpath='{{.spec.template.spec.affinity}}'")
    if out.strip() and out.strip() != "{}": 
        return False, "Deployment is still restricted by the invalid affinity constraints"
        
    code, out, _ = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o jsonpath='{{.spec.template.spec.initContainers}}'")
    if out.strip() and out.strip() != "[]": 
        return False, "Deployment is still blocked by malicious initContainers"

    code, out, _ = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o jsonpath='{{.spec.template.spec.containers[0].readinessProbe.httpGet.port}}'")
    if str(out) != "8080":
        return False, "Deployment readinessProbe is still pointing to the wrong port"
        
    return True, "Deployment scheduling, init processes, and probes are configured correctly"

def check_routing_and_auth():
    """Verifies that the Redis and Loki service ports are correct and the Secret is updated."""
    _, redis_port, _ = run(f"kubectl get svc redis -n {BLEATER_NS} -o jsonpath='{{.spec.ports[0].targetPort}}'")
    _, loki_port, _ = run(f"kubectl get svc loki-gateway -n {LOG_NS} -o jsonpath='{{.spec.ports[0].targetPort}}'")
    code, secret_out, _ = run(f"kubectl get secret bleat-service-auth -n {BLEATER_NS} -o jsonpath='{{.data.REDIS_PASSWORD}}'")
    import base64
    try:
        pw = base64.b64decode(secret_out).decode('utf-8') if code == 0 else ""
    except:
        pw = ""
    
    code, redis_replicas, _ = run(f"kubectl get deployment redis -n {BLEATER_NS} -o jsonpath='{{.spec.replicas}}'")
    if str(redis_replicas) == "0":
        return False, "Redis datastore is scaled to 0 replicas"
        
    if str(redis_port) == "6379" and str(loki_port) == "3100" and pw == "bleater-super-secret-99":
        return True, "Routing, authentication, and datastore scale configured correctly"
    return False, "Service ports or authentication secrets are incorrect"

def check_live_configmap():
    """Verifies that the live ConfigMap has no control characters and contains the exact legacy tuning constants."""
    code, out, err = run(f"kubectl get configmap {CONFIGMAP} -n {BLEATER_NS} -o json")
    if code != 0: return False, f"Could not read live ConfigMap: {err}"
    try:
        configmap = json.loads(out)
        data = configmap.get("data", {})
        redis_url = data.get("REDIS_URL", "")
        
        if data.get("_ROUTING_RETRY_DELAY_MS") != "0": return False, "Legacy tuning flag _ROUTING_RETRY_DELAY_MS missing or mutated"
        if data.get("_MIN_TTL_FLOOR_MS") != "3600": return False, "Legacy tuning flag _MIN_TTL_FLOOR_MS missing or mutated"
        if data.get("_cap_mode_flag") != "true": return False, "Legacy tuning flag _cap_mode_flag missing or mutated"
    except Exception as exc:
        return False, f"Could not parse ConfigMap: {exc}"

    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in redis_url)
    if redis_url == EXPECTED_REDIS_URL and not has_control and "\r" not in redis_url:
        return True, "Live ConfigMap REDIS_URL is clean and canonical"
    return False, f"Live ConfigMap REDIS_URL is still invalid: {redis_url!r}"

def check_repo_manifest():
    """Verifies the on-disk ConfigMap manifest is fixed."""
    manifest = TASK_ROOT / "k8s" / "bleat-service-configmap.yaml"
    if not manifest.exists(): return False, "Checked-out ConfigMap manifest is missing"
    text = manifest.read_text(encoding="utf-8", errors="strict")
    
    if "_ROUTING_RETRY_DELAY_MS" not in text or "_MIN_TTL_FLOOR_MS" not in text or "_cap_mode_flag" not in text:
        return False, "Repo manifest is missing mandatory legacy tuning constants"

    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in text)
    if EXPECTED_REDIS_URL in text and "\r" not in text and "\\r" not in text and not has_control:
        return True, "Checked-out manifest is clean"
    return False, "Checked-out manifest contains encoded control characters"

def check_uid_preserved():
    """Verifies the deployment UID was preserved from the original setup state."""
    code, out, _ = run(f"kubectl get namespace {BLEATER_NS} -o jsonpath='{{.metadata.annotations.original-uid}}'")
    original_uid = out.strip()
    if not original_uid: return False, "Could not find original deployment UID annotation"
    
    code, current_uid, err = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o jsonpath='{{.metadata.uid}}'")
    if original_uid != current_uid: return False, "Deployment UID changed; expected a rolling restart"
    return True, "Deployment object was preserved"

def check_rollout_restart():
    """Verifies that the original pods are disjoint from the newly spun-up pods."""
    code, out, _ = run(f"kubectl get namespace {BLEATER_NS} -o jsonpath='{{.metadata.annotations.original-pods}}'")
    if not out.strip(): return False, "Could not find original pod snapshot annotation"
    original_pods = {p.strip() for p in out.split(",") if p.strip()}
    
    current_pods = set(get_running_pods())
    if bool(original_pods) and bool(current_pods) and original_pods.isdisjoint(current_pods):
        return True, "Pods were replaced gracefully during a rolling restart"
    return False, "Rolling restart not detected (pods overlap or missing)"

def check_deployment_ready():
    """Verifies the deployment eventually hits 2/2 Ready replicas."""
    if wait_for_ready(timeout=150): return True, "bleat-service deployment is fully Ready"
    return False, "bleat-service deployment never reached 2/2 Ready replicas"

def check_pod_env():
    """Verifies that the live, running pods contain the correct environment variable without CRLF."""
    pods = get_running_pods()
    if not pods: return False, "No bleat-service pods found"
    code, out, err = run(f"kubectl exec -n {BLEATER_NS} {pods[0]} -- printenv REDIS_URL")
    if out == EXPECTED_REDIS_URL: return True, "Running bleat-service pod uses the cleaned REDIS_URL"
    return False, f"Running pod still has stale REDIS_URL"

def check_loki_success():
    """Parses the Loki log gateway to ensure a successful Redis connection was established."""
    ok, msg, entries = get_loki_entries()
    if not ok: return False, msg
    success_entries = [e for e in entries if e.get("labels", {}).get("app") == "bleat-service" and "redis connection established" in e.get("message", "").lower()]
    if success_entries: return True, "Loki contains a successful Redis connection log"
    return False, "Loki does not show a successful Redis connection log"

def check_loki_no_new_errors():
    """Ensures no new error logs are thrown by the application after the success timestamp."""
    ok, msg, entries = get_loki_entries()
    if not ok: return False, msg
    relevant = [e for e in entries if e.get("labels", {}).get("app") == "bleat-service"]
    
    def parse_ts(t):
        try: return float(t)
        except (ValueError, TypeError): return 0.0

    success_ts = [parse_ts(e.get("ts", "0")) for e in relevant if "redis connection established" in e.get("message", "").lower()]
    if not success_ts: return False, "No successful Redis connection log found in Loki"
    
    latest_success = max(success_ts)
    newer_errors = [e for e in relevant if parse_ts(e.get("ts", "0")) > latest_success and e.get("labels", {}).get("level") == "error"]
    
    if not newer_errors: return True, "No newer bleat-service error logs appear after Redis recovery"
    return False, "Loki still contains error logs after recovery"

def check_validation_script():
    """Validates the python script effectively checks for CRLF using binary reads and emits JSON."""
    script = TASK_ROOT / "scripts" / "validate_configmap.py"
    if not script.exists(): return False, "Validation script missing"
    
    script_text = script.read_text(encoding="utf-8")
    if "import json" not in script_text:
        return False, "Validation script failed security mandate (missing 'json' import)"

    with tempfile.TemporaryDirectory() as tmpdir:
        good_manifest = Path(tmpdir) / "good.yaml"
        good_manifest.write_text("REDIS_URL: \"redis://redis.bleater.svc.cluster.local:6379/0\"", encoding="utf-8")
        good = subprocess.run([sys.executable, str(script), str(good_manifest)], capture_output=True, text=True)

        bad_manifest = Path(tmpdir) / "bad.yaml"
        bad_manifest.write_text('REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0' + chr(13) + '"\n', encoding="utf-8")
        bad = subprocess.run([sys.executable, str(script), str(bad_manifest)], capture_output=True, text=True)

    try:
        good_json = json.loads(good.stdout.strip())
        bad_json = json.loads(bad.stdout.strip())
        if good.returncode == 0 and bad.returncode != 0 and good_json.get("status") == "pass" and bad_json.get("status") == "fail":
            return True, "Validation script accepts clean manifests and rejects corruption with valid JSON"
        return False, "Validation script logic or JSON output is incorrect"
    except json.JSONDecodeError:
        return False, "Validation script did not output valid JSON"

def check_workflow_hook():
    """Validates the `.gitea` workflow pipeline is hooked up to the python script."""
    workflow = TASK_ROOT / ".gitea" / "workflows" / "bleat-ci.yaml"
    if not workflow.exists(): return False, "Workflow file missing"
    text = workflow.read_text(encoding="utf-8", errors="ignore")
    if "validate_configmap.py" in text and "k8s/bleat-service-configmap.yaml" in text:
        return True, "CI workflow invokes the ConfigMap validation step"
    return False, "CI workflow does not call the ConfigMap validation step"

def grade(transcript: str) -> GradingResult:
    checks = {
        "infrastructure_traps_cleared": check_infrastructure_traps,
        "deployment_sabotage_fixed": check_deployment_sabotage_fixed,
        "routing_auth_repaired": check_routing_and_auth,
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

    feedback_parts, passed = [], {}
    for name, fn in checks.items():
        ok, message = fn()
        passed[name] = ok
        feedback_parts.append(f"{'PASS' if ok else 'FAIL'} {name}: {message}")

    weight = 1.0 / len(checks)
    weights = {name: weight for name in checks}
    score = sum(weights[name] for name, ok in passed.items() if ok)

    return GradingResult(score=score, subscores=passed, weights=weights, feedback=" | ".join(feedback_parts))