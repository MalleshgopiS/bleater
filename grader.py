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
UID_FILE = Path("/tmp/bleat-service-deployment-uid")

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
    code, out, err = run(f"kubectl exec -n {LOG_NS} {pod_name} -- cat /data/logs.jsonl", timeout=20)
    if code != 0: return False, f"Could not read Loki log store: {err}", []
    entries = []
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        try: entries.append(json.loads(line))
        except json.JSONDecodeError: continue
    return True, "Loki log store readable", entries

def check_infrastructure_traps():
    traps = [
        ("pdb", "bleat-service-pdb", BLEATER_NS),
        ("limitrange", "hidden-mem-limit", BLEATER_NS),
        ("resourcequota", "default-mem-limit", BLEATER_NS),
        ("networkpolicy", "redis-security-policy", BLEATER_NS),
        ("networkpolicy", "loki-deny-all", LOG_NS),
        ("cronjob", "legacy-config-sync", "default"),
        ("deployment", "redis-autoscaler", "default"),
        ("daemonset", "rancher-servicelb-agent", "default")
    ]
    for kind, name, ns in traps:
        code, _, _ = run(f"kubectl get {kind} {name} -n {ns}")
        if code == 0: 
            return False, f"Infrastructure trap {kind}/{name} in {ns} was not neutralized"
    
    code, out, _ = run(f"kubectl get networkpolicy -n {BLEATER_NS} -o json")
    if code == 0:
        try:
            nps = json.loads(out).get("items", [])
            for np in nps:
                if np.get("metadata", {}).get("name", "").startswith("total-block-policy"):
                    return False, "Stochastic total-block-policy was not neutralized"
        except json.JSONDecodeError:
            pass
            
    return True, "All rogue infrastructure traps were successfully deleted"

def check_deployment_sabotage_fixed():
    code, out, err = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json")
    if code != 0: return False, "Could not fetch bleat-service deployment"
    dep = json.loads(out)
    spec = dep.get("spec", {}).get("template", {}).get("spec", {})
    
    if "affinity" in spec: return False, "Node affinity was not removed from bleat-service"
    if "initContainers" in spec: return False, "initContainers were not removed from bleat-service"
    
    try:
        port = spec["containers"][0]["readinessProbe"]["httpGet"]["port"]
        if str(port) != "8080": return False, f"readinessProbe port is {port}, expected 8080"
    except Exception:
        return False, "readinessProbe is missing or malformed"
        
    code, out, err = run(f"kubectl get deployment loki-gateway -n {LOG_NS} -o json")
    if code == 0:
        loki_dep = json.loads(out)
        loki_containers = loki_dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        for c in loki_containers:
            if c.get("name") == "metrics-sidecar":
                return False, "Malicious metrics-sidecar was not removed from loki-gateway"
                
    return True, "Deployment sabotage (sidecars, initContainers, affinity, probes) fixed"

def check_routing_and_auth():
    code, out, _ = run(f"kubectl get svc redis -n {BLEATER_NS} -o json")
    if code == 0:
        svc = json.loads(out)
        if str(svc["spec"]["ports"][0].get("targetPort")) != "6379":
            return False, "Redis service targetPort not fixed to 6379"
            
    code, out, _ = run(f"kubectl get svc loki-gateway -n {LOG_NS} -o json")
    if code == 0:
        svc = json.loads(out)
        if str(svc["spec"]["ports"][0].get("targetPort")) != "3100":
            return False, "Loki service targetPort not fixed to 3100"
            
    code, out, _ = run(f"kubectl get secret bleat-service-auth -n {BLEATER_NS} -o json")
    if code != 0: return False, "Auth secret missing"
    sec = json.loads(out)
    import base64
    pw_b64 = sec.get("data", {}).get("REDIS_PASSWORD", "")
    if not pw_b64: return False, "REDIS_PASSWORD key missing in secret"
    pw = base64.b64decode(pw_b64).decode("utf-8")
    if pw != "bleater-super-secret-99":
        return False, "Auth secret password incorrect"
        
    return True, "Service routing and secret authentication fixed"

def check_live_configmap():
    code, out, err = run(f"kubectl get configmap {CONFIGMAP} -n {BLEATER_NS} -o json")
    if code != 0: return False, f"Could not read live ConfigMap: {err}"
    try:
        configmap = json.loads(out)
        data = configmap.get("data", {})
        redis_url = data.get("REDIS_URL", "")
        
        if data.get("_ROUTING_RETRY_DELAY_MS") != "0": return False, "Implementation detail _ROUTING_RETRY_DELAY_MS missing or mutated"
        if data.get("_MIN_TTL_FLOOR_MS") != "3600": return False, "Implementation detail _MIN_TTL_FLOOR_MS missing or mutated"
        if data.get("_cap_mode_flag") != "true": return False, "Implementation detail _cap_mode_flag missing or mutated"
    except Exception as exc:
        return False, f"Could not parse ConfigMap: {exc}"

    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in redis_url)
    if redis_url == EXPECTED_REDIS_URL and not has_control and "\r" not in redis_url:
        return True, "Live ConfigMap REDIS_URL is clean and canonical"
    return False, f"Live ConfigMap REDIS_URL is still invalid: {redis_url!r}"

def check_repo_manifest():
    manifest = TASK_ROOT / "k8s" / "bleat-service-configmap.yaml"
    if not manifest.exists(): return False, "Checked-out ConfigMap manifest is missing"
    text = manifest.read_text(encoding="utf-8", errors="strict")
    
    if "_ROUTING_RETRY_DELAY_MS" not in text or "_MIN_TTL_FLOOR_MS" not in text or "_cap_mode_flag" not in text:
        return False, "Harness file integrity compromised: missing production decoy constants in repo manifest"

    has_control = any((ord(ch) < 32 and ch not in "\n\t") or ord(ch) == 127 for ch in text)
    if EXPECTED_REDIS_URL in text and "\\r" not in text and "\r" not in text and not has_control:
        return True, "Checked-out manifest is clean"
    return False, "Checked-out manifest still contains encoded or hidden control characters"

def check_uid_preserved():
    if not UID_FILE.exists(): return False, "Missing stored original deployment UID"
    original_uid = UID_FILE.read_text(encoding="utf-8").strip()
    code, out, err = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json")
    if code != 0: return False, f"Could not read current deployment: {err}"
    
    dep = json.loads(out)
    current_uid = dep.get("metadata", {}).get("uid")
    
    if original_uid != current_uid: return False, "Deployment UID changed; expected a rolling restart"
    return True, "Deployment object preserved"

def check_rollout_restart():
    # Safely check for rollout by ensuring generation advanced
    code, out, err = run(f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} -o json")
    if code != 0: return False, "Could not fetch bleat-service deployment"
    dep = json.loads(out)
    generation = dep.get("metadata", {}).get("generation", 1)
    if generation > 1:
        return True, "Pods were replaced during a rolling restart"
    return False, "Rolling restart not detected; deployment generation did not advance"

def check_deployment_ready():
    if wait_for_ready(timeout=150): return True, "bleat-service deployment is fully Ready"
    return False, "bleat-service deployment never reached 2/2 Ready replicas"

def check_pod_env():
    pods = get_running_pods()
    if not pods: return False, "No bleat-service pods found"
    code, out, err = run(f"kubectl exec -n {BLEATER_NS} {pods[0]} -- printenv REDIS_URL")
    if code != 0: return False, f"Could not read REDIS_URL from running pod: {err}"
    if out == EXPECTED_REDIS_URL: return True, "Running bleat-service pod uses the cleaned REDIS_URL"
    return False, f"Running pod still has stale REDIS_URL: {out!r}"

def check_loki_success():
    ok, msg, entries = get_loki_entries()
    if not ok: return False, msg
    success_entries = [e for e in entries if e.get("labels", {}).get("app") == "bleat-service" and "redis connection established" in e.get("message", "").lower()]
    if success_entries: return True, "Loki contains a successful Redis connection log"
    return False, "Loki does not show a successful Redis connection log"

def check_loki_no_new_errors():
    ok, msg, entries = get_loki_entries()
    if not ok: return False, msg
    relevant = [e for e in entries if e.get("labels", {}).get("app") == "bleat-service"]
    success_ts = [int(e.get("ts", "0")) for e in relevant if "redis connection established" in e.get("message", "").lower()]
    if not success_ts: return False, "No successful Redis connection log found in Loki"
    latest_success = max(success_ts)
    newer_errors = [e for e in relevant if int(e.get("ts", "0")) > latest_success and e.get("labels", {}).get("level") == "error"]
    if not newer_errors: return True, "No newer bleat-service error logs appear after Redis recovery"
    return False, "Loki still contains bleat-service error logs after the latest success event"

def check_validation_script():
    script = TASK_ROOT / "scripts" / "validate_configmap.py"
    if not script.exists(): return False, "Validation script missing"
    
    with tempfile.TemporaryDirectory() as tmpdir:
        good_manifest = Path(tmpdir) / "good.yaml"
        good_manifest.write_text('REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"\n')
        good = subprocess.run([sys.executable, str(script), str(good_manifest)], capture_output=True, text=True)

        bad_manifest = Path(tmpdir) / "bad.yaml"
        # Write actual carriage return string for accurate testing
        bad_manifest.write_text('REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"\n')
        bad = subprocess.run([sys.executable, str(script), str(bad_manifest)], capture_output=True, text=True)

    if good.returncode == 0 and bad.returncode != 0:
        return True, "Validation script accepts clean manifests and rejects corruption"
    return False, "Validation script behavior is incorrect"

def check_workflow_hook():
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

    feedback_parts, passed = {}, {}
    for name, fn in checks.items():
        ok, message = fn()
        passed[name] = ok
        feedback_parts[name] = message

    weight = 1.0 / len(checks)
    weights = {name: weight for name in checks}
    score = sum(weights[name] for name, ok in passed.items() if ok)

    return GradingResult(score=score, subscores=passed, weights=weights, feedback=json.dumps(feedback_parts))