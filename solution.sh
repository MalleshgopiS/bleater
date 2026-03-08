#!/usr/bin/env bash
set -euo pipefail

BLEATER_NS="bleater"
APP_DIR="/home/ubuntu/bleater-app"

cd "$APP_DIR"

echo "1. Stop hidden config corrupter..."
kubectl delete cronjob legacy-config-sync -n "$BLEATER_NS" --ignore-not-found
kubectl delete configmap hidden-sync-script -n "$BLEATER_NS" --ignore-not-found

echo "2. Write clean ConfigMap manifest..."
mkdir -p k8s
cat > k8s/bleat-service-configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
EOF

echo "3. Create strict validation script..."
mkdir -p scripts
cat > scripts/validate_configmap.py << 'EOF'
#!/usr/bin/env python3
import sys,re
text=open(sys.argv[1]).read()
bad = (
    "\r" in text or
    re.search(r'\\r|\\x0d|\\u000d', text, re.I) or
    re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', text)
)
sys.exit(1 if bad else 0)
EOF
chmod +x scripts/validate_configmap.py

echo "4. Update CI workflow..."
mkdir -p .gitea/workflows
cat > .gitea/workflows/bleat-ci.yaml << 'EOF'
name: Bleat CI
on: [push]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap
        run: |
          python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "5. Apply fixed ConfigMap..."
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "6. Force new pod template (guaranteed rollout)..."
kubectl patch deployment bleat-service -n "$BLEATER_NS" \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"fix-ts\":\"$(date +%s)\"}}}}}"

echo "7. Wait for rollout..."
kubectl rollout status deployment/bleat-service -n "$BLEATER_NS" --timeout=300s

echo "✅ Done"