#!/usr/bin/env bash
set -euo pipefail

BLEATER_NS="bleater"
LOG_NS="logging"
APP_LABEL="app=bleat-service"
DEPLOY="bleat-service"

echo "1️⃣ Fixing Redis service routing..."
kubectl patch svc redis -n "$BLEATER_NS" --type='json' \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":6379}]'

echo "2️⃣ Inspecting corrupted REDIS_URL..."
kubectl get configmap bleat-service-config -n "$BLEATER_NS" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v

echo "3️⃣ Rebuilding clean manifest..."
MANIFEST="/home/ubuntu/bleater-app/k8s/bleat-service-configmap.yaml"

cat > "$MANIFEST" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
EOF

echo "4️⃣ Creating validation script..."
mkdir -p /home/ubuntu/bleater-app/scripts

cat > /home/ubuntu/bleater-app/scripts/validate_configmap.py <<'PYEOF'
#!/usr/bin/env python3
import sys
from pathlib import Path

bad = False
for p in Path("k8s").rglob("*.yaml"):
    t = p.read_text(encoding="utf-8", errors="ignore")
    if "\r" in t or "\\r" in t:
        print(f"BAD: {p}")
        bad = True

if bad:
    sys.exit(1)
else:
    print("All manifest files are clean.")
PYEOF

chmod +x /home/ubuntu/bleater-app/scripts/validate_configmap.py

echo "5️⃣ Updating CI workflow..."
CI_FILE="/home/ubuntu/bleater-app/.gitea/workflows/bleat-ci.yaml"

cat > "$CI_FILE" <<'EOF'
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/validate_configmap.py
EOF

echo "6️⃣ Applying fixed ConfigMap..."
kubectl apply -f "$MANIFEST"

echo "7️⃣ Rolling restart..."
kubectl rollout restart deployment "$DEPLOY" -n "$BLEATER_NS"

echo "⏳ Waiting for rollout to complete..."
kubectl rollout status deployment "$DEPLOY" -n "$BLEATER_NS" --timeout=180s

echo "8️⃣ Waiting for pods ready..."
kubectl wait --for=condition=ready pod -l "$APP_LABEL" -n "$BLEATER_NS" --timeout=180s

echo "9️⃣ Verifying environment variable..."
POD=$(kubectl get pods -n "$BLEATER_NS" -l "$APP_LABEL" \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n "$BLEATER_NS" "$POD" -- printenv REDIS_URL

echo "🔟 Verifying Loki logs..."
sleep 10
kubectl exec -n "$LOG_NS" deployment/loki-gateway -- cat /data/logs.jsonl

echo "✅ Done."