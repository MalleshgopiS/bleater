#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
cd /home/ubuntu/bleater-app

echo "══════════════════════════════════════════════════════"
echo " Step 1: Audit all namespaces for rogue re-corruption"
echo "══════════════════════════════════════════════════════"
echo "Scanning for CronJobs across all namespaces..."
kubectl get cronjobs --all-namespaces

echo ""
echo "Deleting primary rogue CronJob (default/legacy-config-sync)..."
kubectl delete cronjob legacy-config-sync -n default --ignore-not-found

echo "Deleting secondary rogue CronJob (kube-system/platform-config-sync)..."
kubectl delete cronjob platform-config-sync -n kube-system --ignore-not-found

echo "Waiting for any in-flight CronJob pods to terminate..."
sleep 15

echo "══════════════════════════════════════════════════════"
echo " Step 2: Fix Redis Service targetPort (6380 → 6379)"
echo "══════════════════════════════════════════════════════"
kubectl patch service redis -n "${BLEATER_NS}" \
    -p '{"spec":{"ports":[{"port": 6379, "targetPort": 6379, "name": "redis"}]}}'

echo "══════════════════════════════════════════════════════"
echo " Step 3: Fix Loki-gateway Service targetPort (3101 → 3100)"
echo "══════════════════════════════════════════════════════"
kubectl patch service loki-gateway -n "logging" \
    -p '{"spec":{"ports":[{"port": 3100, "targetPort": 3100, "name": "http"}]}}'

echo "══════════════════════════════════════════════════════"
echo " Step 4: Inspect ConfigMap for hidden characters"
echo "══════════════════════════════════════════════════════"
echo "Raw value (cat -v will show ^M for \\r):"
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
    -o jsonpath='{.data.REDIS_URL}' | cat -v
echo ""

echo "══════════════════════════════════════════════════════"
echo " Step 5: Write clean ConfigMap manifest (Unix endings)"
echo "══════════════════════════════════════════════════════"
cat <<'MANIFEST' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
MANIFEST

echo "══════════════════════════════════════════════════════"
echo " Step 6: Create ConfigMap validation script"
echo "══════════════════════════════════════════════════════"
mkdir -p scripts
cat <<'PYEOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
"""
Validate Kubernetes ConfigMap YAML manifests for invisible-character
corruption (carriage returns, non-printable bytes, YAML-escaped variants).

Exit 0 — manifest is clean.
Exit 1 — corruption detected.
"""
import pathlib
import re
import sys

# Literal control chars (excluding normal whitespace \t and \n)
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

# YAML-escaped representations of carriage return
ESCAPED_CR_RE = re.compile(r"(\\r|\\x0d|\\u000d)", re.IGNORECASE)


def check(path: pathlib.Path) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        return 1

    if "\r" in text:
        print(f"FAIL: {path} contains literal carriage-return (\\r)", file=sys.stderr)
        return 1
    if CONTROL_RE.search(text):
        print(f"FAIL: {path} contains non-printable control characters", file=sys.stderr)
        return 1
    if ESCAPED_CR_RE.search(text):
        print(f"FAIL: {path} contains YAML-escaped carriage-return (\\\\r / \\\\x0d / \\\\u000d)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: validate_configmap.py <manifest.yaml> [...]", file=sys.stderr)
        sys.exit(1)

    rc = 0
    for arg in sys.argv[1:]:
        p = pathlib.Path(arg)
        if not p.exists():
            print(f"FAIL: {p} does not exist", file=sys.stderr)
            rc = 1
        else:
            rc = max(rc, check(p))

    if rc == 0:
        print("OK: all manifests passed validation")
    sys.exit(rc)
PYEOF
chmod +x scripts/validate_configmap.py

echo "══════════════════════════════════════════════════════"
echo " Step 7: Update CI workflow to run validation"
echo "══════════════════════════════════════════════════════"
cat <<'WORKFLOW' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap manifests for encoding corruption
        run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
  unit-tests:
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - uses: actions/checkout@v4
      - run: echo "tests passed"
WORKFLOW

echo "══════════════════════════════════════════════════════"
echo " Step 8: Apply clean ConfigMap"
echo "══════════════════════════════════════════════════════"
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "══════════════════════════════════════════════════════"
echo " Step 9: Rolling restart of bleat-service"
echo "══════════════════════════════════════════════════════"
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo ""
echo "══════════════════════════════════════════════════════"
echo " Verification"
echo "══════════════════════════════════════════════════════"
echo "ConfigMap REDIS_URL (should be clean):"
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
    -o jsonpath='{.data.REDIS_URL}' | cat -v
echo ""

echo "Deployment status:"
kubectl get deployment bleat-service -n "${BLEATER_NS}"

echo ""
echo "Validation script self-test:"
python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml \
    && echo "PASS: clean manifest accepted" \
    || echo "FAIL"

echo ""
echo "All steps complete.  bleat-service should be healthy and logging."
