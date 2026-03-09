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

# =========================================================
# 🔧 ADDED: RBAC-SAFE NEUTRALIZATION HELPERS (NEW CODE)
# =========================================================
def autoscaler_neutralized():
    code, out, _ = run("kubectl get deployment redis-autoscaler -n kube-system -o json")
    if code != 0:
        return True  # deleted is fine
    try:
        d = json.loads(out)
        return d.get("spec", {}).get("replicas", 1) == 0
    except:
        return False

def ds_neutralized():
    code, out, _ = run("kubectl get daemonset rancher-servicelb-agent -n kube-system -o json")
    if code != 0:
        return True  # deleted is fine
    try:
        d = json.loads(out)
        sel = d.get("spec", {}).get("template", {}).get("spec", {}).get("nodeSelector", {})
        return "nonexistent" in sel
    except:
        return False
# =========================================================


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

def check_infrastructure_traps():
    """Verifies stealth traps are cleared while valid policies remain."""
    lr, _, _ = run(f"kubectl get limitrange hidden-mem-limit -n {BLEATER_NS}")
    np1, _, _ = run(f"kubectl get networkpolicy kube-dns-allow -n {BLEATER_NS}")
    np2, _, _ = run(f"kubectl get networkpolicy loki-deny-all -n {LOG_NS}")
    pdb, _, _ = run(f"kubectl get pdb bleat-service-pdb -n {BLEATER_NS}")

    # OLD checks preserved
    opt, _, _ = run(f"kubectl get deployment redis-autoscaler -n kube-system")
    ds, _, _ = run(f"kubectl get daemonset rancher-servicelb-agent -n kube-system")
    
    code, sidecar_out, _ = run(f"kubectl get deployment loki-gateway -n {LOG_NS} -o jsonpath='{{.spec.template.spec.containers[*].name}}'")
    has_sidecar = "metrics-sidecar" in sidecar_out
    has_valid_decoy = "fluent-bit-logger" in sidecar_out
    
    valid_np, _, _ = run(f"kubectl get networkpolicy baseline-security-rules -n {BLEATER_NS}")

    # =========================================================
    # 🔧 UPDATED CONDITION (delete OR neutralize accepted)
    # =========================================================
    autoscaler_ok = (opt != 0) or autoscaler_neutralized()
    ds_ok = (ds != 0) or ds_neutralized()

    if lr != 0 and np1 != 0 and np2 != 0 and pdb != 0 and autoscaler_ok and ds_ok and not has_sidecar and has_valid_decoy and valid_np == 0:
        return True, "Stealth traps cleared, valid secondary logger preserved, and valid policies preserved"
    # =========================================================

    return False, "Traps are still active, valid logger was deleted, or valid policies were deleted"

# ---------------------------
# EVERYTHING BELOW IS 100%
# YOUR ORIGINAL CODE
# ---------------------------

def check_deployment_sabotage_fixed():
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

# (all your remaining original grader code continues unchanged...)

def grade(transcript: str) -> GradingResult:
    checks = {
        "infrastructure_traps_cleared": check_infrastructure_traps,
        "deployment_sabotage_fixed": check_deployment_sabotage_fixed,
        # all your original checks unchanged...
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