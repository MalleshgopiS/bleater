#!/usr/bin/env python3
import json
import subprocess
import time
from pathlib import Path
from apex_arena._types import GradingResult

BLEATER_NS = "bleater"
LOG_NS = "logging"
DEPLOY = "bleat-service"

# -------------------------------------------------
# Utility
# -------------------------------------------------
def run(cmd: str, timeout: int = 30):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except:
        return -1, "", "error"


# -------------------------------------------------
# RBAC-safe neutralization checks
# -------------------------------------------------
def autoscaler_neutralized():
    code, out, _ = run("kubectl get deployment redis-autoscaler -n kube-system -o json")
    if code != 0:
        return True
    try:
        d = json.loads(out)
        return d.get("spec", {}).get("replicas", 1) == 0
    except:
        return False


def daemonset_neutralized():
    code, out, _ = run("kubectl get daemonset rancher-servicelb-agent -n kube-system -o json")
    if code != 0:
        return True
    try:
        d = json.loads(out)
        sel = d.get("spec", {}).get("template", {}).get("spec", {}).get("nodeSelector", {})
        return "nonexistent" in sel
    except:
        return False


# -------------------------------------------------
# Individual Trap Checks (granular scoring)
# -------------------------------------------------
def pdb_removed():
    code, _, _ = run(f"kubectl get pdb bleat-service-pdb -n {BLEATER_NS}")
    return code != 0


def limitrange_removed():
    code, _, _ = run(f"kubectl get limitrange hidden-mem-limit -n {BLEATER_NS}")
    return code != 0


def quota_removed():
    code, _, _ = run(f"kubectl get resourcequota default-mem-limit -n {BLEATER_NS}")
    return code != 0


def netpol_bleater_removed():
    code, _, _ = run(f"kubectl get networkpolicy kube-dns-allow -n {BLEATER_NS}")
    return code != 0


def netpol_logging_removed():
    code, _, _ = run(f"kubectl get networkpolicy loki-deny-all -n {LOG_NS}")
    return code != 0


def autoscaler_fixed():
    code, _, _ = run("kubectl get deployment redis-autoscaler -n kube-system")
    return code != 0 or autoscaler_neutralized()


def daemonset_fixed():
    code, _, _ = run("kubectl get daemonset rancher-servicelb-agent -n kube-system")
    return code != 0 or daemonset_neutralized()


def loki_sidecar_removed():
    code, out, _ = run(
        f"kubectl get deployment loki-gateway -n {LOG_NS} "
        "-o jsonpath='{.spec.template.spec.containers[*].name}'"
    )
    if code != 0:
        return False
    names = out.replace("'", "").split()
    return "metrics-sidecar" not in names and "fluent-bit-logger" in names


def valid_netpol_preserved():
    code, _, _ = run(f"kubectl get networkpolicy baseline-security-rules -n {BLEATER_NS}")
    return code == 0


# -------------------------------------------------
# Partial Infra Score
# -------------------------------------------------
def infrastructure_traps_score():
    checks = [
        pdb_removed(),
        limitrange_removed(),
        quota_removed(),
        netpol_bleater_removed(),
        netpol_logging_removed(),
        autoscaler_fixed(),
        daemonset_fixed(),
        loki_sidecar_removed(),
        valid_netpol_preserved(),
    ]
    return sum(1 for c in checks if c) / len(checks)


# -------------------------------------------------
# Deployment Fix Checks
# -------------------------------------------------
def deployment_fixed_score():
    score = 0
    total = 3

    code, out, _ = run(
        f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} "
        "-o jsonpath='{.spec.template.spec.affinity}'"
    )
    if not out or out == "{}":
        score += 1

    code, out, _ = run(
        f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} "
        "-o jsonpath='{.spec.template.spec.initContainers}'"
    )
    if not out or out == "[]":
        score += 1

    code, out, _ = run(
        f"kubectl get deployment {DEPLOY} -n {BLEATER_NS} "
        "-o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}'"
    )
    if out == "8080":
        score += 1

    return score / total


# -------------------------------------------------
# Main Grade
# -------------------------------------------------
def grade(_: str) -> GradingResult:
    infra = infrastructure_traps_score()
    deploy = deployment_fixed_score()

    subscores = {
        "infrastructure_traps_cleared": infra,
        "deployment_sabotage_fixed": deploy,
    }

    weights = {
        "infrastructure_traps_cleared": 0.5,
        "deployment_sabotage_fixed": 0.5,
    }

    final_score = sum(subscores[k] * weights[k] for k in subscores)

    feedback = (
        f"Infrastructure score: {infra:.2f} | "
        f"Deployment score: {deploy:.2f}"
    )

    return GradingResult(
        score=final_score,
        subscores=subscores,
        weights=weights,
        feedback=feedback,
    )