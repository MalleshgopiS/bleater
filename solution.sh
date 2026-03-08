#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "1. Inspecting REDIS_URL for corruption..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" 
-o jsonpath='{.data.REDIS_URL}' | cat -v || true
echo

echo "2. Writing clean ConfigMap manifest..."
mkdir -p k8s
cat <<'EOF' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
name: bleat-service-config
namespace: bleater
data:
REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
EOF

echo "3. Creating validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import pathlib
import re
import sys

CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESCAPED = re.compile(r"(\r|\x0d|\u000d)", re.I)

def check(path):
text = path.read_text()
if "\r" in text:
return 1
if CONTROL.search(text):
return 1
if ESCAPED.search(text):
return 1
return 0

rc = 0
for f in sys.argv[1:]:
p = pathlib.Path(f)
if not p.exists():
rc = 1
else:
rc = max(rc, check(p))

sys.exit(rc)
EOF

chmod +x scripts/validate_configmap.py

echo "4. Creating CI workflow..."
mkdir -p .gitea/workflows
cat <<'EOF' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]

jobs:
validate:
runs-on: ubuntu-latest
steps:
- uses: actions/checkout@v4
- name: Validate ConfigMap encoding
run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "5. Applying fixed ConfigMap to cluster..."
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "6. Triggering safe rolling restart (UID preserved)..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}" || true

echo "7. Waiting for deployment to stabilize..."
kubectl wait 
--for=condition=available 
--timeout=300s 
deployment/bleat-service -n "${BLEATER_NS}"

echo "8. Verifying pods are Ready..."
kubectl wait 
--for=condition=Ready pod 
-l app=bleat-service 
-n "${BLEATER_NS}" 
--timeout=300s || true

echo "✅ Bleat-service remediation completed successfully."
