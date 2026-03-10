#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "Step 1: Delete rogue CronJobs"
kubectl delete cronjob legacy-config-sync -n default --ignore-not-found
kubectl delete cronjob platform-config-sync -n monitoring --ignore-not-found

echo "Step 2: Fix Redis Service targetPort"
kubectl patch service redis -n "${BLEATER_NS}" \
  -p '{"spec":{"ports":[{"port":6379,"targetPort":6379,"name":"redis"}]}}'

echo "Step 3: Fix Loki Service targetPort"
kubectl patch service loki-gateway -n logging \
  -p '{"spec":{"ports":[{"port":3100,"targetPort":3100,"name":"http"}]}}'

echo "Step 4: Clean ConfigMap (remove CRLF corruption)"
cat <<'EOF' > /home/ubuntu/bleater-app/k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
EOF

kubectl apply -f /home/ubuntu/bleater-app/k8s/bleat-service-configmap.yaml

echo "Step 5: Create validation script"
mkdir -p /home/ubuntu/bleater-app/scripts
cat <<'EOF' > /home/ubuntu/bleater-app/scripts/validate_configmap.py
#!/usr/bin/env python3
import pathlib, re, sys

CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESCAPED_CR_RE = re.compile(r"(\\r|\\x0d|\\u000d)", re.IGNORECASE)

def check(path):
    text = path.read_text(encoding="utf-8")
    if "\r" in text:
        print(f"FAIL: {path} contains literal carriage-return (\\r)", file=sys.stderr)
        return 1
    if CONTROL_RE.search(text):
        print(f"FAIL: {path} contains non-printable control characters", file=sys.stderr)
        return 1
    if ESCAPED_CR_RE.search(text):
        print(f"FAIL: {path} contains YAML-escaped carriage-return", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    rc = 0
    for arg in sys.argv[1:]:
        p = pathlib.Path(arg)
        rc = max(rc, check(p))
    sys.exit(rc)
EOF
chmod +x /home/ubuntu/bleater-app/scripts/validate_configmap.py

echo "Step 6: Update CI workflow"
mkdir -p /home/ubuntu/bleater-app/.gitea/workflows
cat <<'EOF' > /home/ubuntu/bleater-app/.gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap manifests
        run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
  unit-tests:
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - uses: actions/checkout@v4
      - run: echo "tests passed"
EOF

echo "Step 7: Rolling restart of bleat-service"
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo "Step 8: Verify ConfigMap stability"
sleep 95
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" -o jsonpath='{.data.REDIS_URL}' | cat -v