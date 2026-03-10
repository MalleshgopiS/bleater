#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

echo "Waiting for k3s to be ready..."
MAX_WAIT=180
ELAPSED=0
until kubectl get nodes >/dev/null 2>&1; do
    if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

BLEATER_NS="bleater"
LOG_NS="logging"
UID_FILE="/tmp/bleat-service-deployment-uid"
PODS_FILE="/tmp/bleat-service-original-pods"

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${LOG_NS}" --dry-run=client -o yaml | kubectl apply -f -

# ─────────────────────────────────────────────────────────────────────────────
# HIDDEN RE-CORRUPTION MECHANISM 1 (Tier 3 Difficulty)
# CronJob in the "default" namespace — name sounds like a legacy config sync.
# Issues do NOT mention the namespace or the CronJob name explicitly.
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: legacy-sync-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: legacy-sync-sa-admin
subjects:
- kind: ServiceAccount
  name: legacy-sync-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hidden-sync-script
  namespace: default
data:
  sync.py: |
    import urllib.request, json, ssl
    try:
        token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
        ctx = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
        req = urllib.request.Request(
            'https://kubernetes.default.svc/api/v1/namespaces/bleater/configmaps/bleat-service-config',
            data=json.dumps({"data": {"REDIS_URL": "redis://redis.bleater.svc.cluster.local:6379/0\r"}}).encode(),
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/strategic-merge-patch+json'},
            method='PATCH'
        )
        urllib.request.urlopen(req, context=ctx)
    except Exception as e:
        pass
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: legacy-config-sync
  namespace: default
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: legacy-sync-sa
          containers:
          - name: sync
            image: python:3.11-slim
            command: ["python", "/app/sync.py"]
            volumeMounts:
            - name: script
              mountPath: /app
          volumes:
          - name: script
            configMap:
              name: hidden-sync-script
          restartPolicy: OnFailure
EOF

# ─────────────────────────────────────────────────────────────────────────────
# HIDDEN RE-CORRUPTION MECHANISM 2 (Tier 3 Difficulty)
# A second CronJob in the "monitoring" namespace under a deliberately bland
# name ("platform-config-sync").  Both CronJobs must be deleted for fixes to persist.
# ─────────────────────────────────────────────────────────────────────────────
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-config-sa
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-config-sa-admin
subjects:
- kind: ServiceAccount
  name: platform-config-sa
  namespace: monitoring
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-sync-script
  namespace: monitoring
data:
  sync.py: |
    import urllib.request, json, ssl
    try:
        token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
        ctx = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
        req = urllib.request.Request(
            'https://kubernetes.default.svc/api/v1/namespaces/bleater/configmaps/bleat-service-config',
            data=json.dumps({"data": {"REDIS_URL": "redis://redis.bleater.svc.cluster.local:6379/0\r"}}).encode(),
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/strategic-merge-patch+json'},
            method='PATCH'
        )
        urllib.request.urlopen(req, context=ctx)
    except Exception as e:
        pass
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: platform-config-sync
  namespace: monitoring
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: platform-config-sa
          containers:
          - name: sync
            image: python:3.11-slim
            command: ["python", "/app/sync.py"]
            volumeMounts:
            - name: script
              mountPath: /app
          volumes:
          - name: script
            configMap:
              name: platform-sync-script
          restartPolicy: OnFailure
EOF

# ─────────────────────────────────────────────────────────────────────────────
# REDIS MOCK DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-script
  namespace: bleater
data:
  redis_server.py: |
    import socketserver
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                while True:
                    line = self.rfile.readline()
                    if not line: return
                    if b"PING" in line.upper():
                        self.wfile.write(b"+PONG\r\n")
                        self.wfile.flush()
                        return
            except Exception: return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    Server(("", 6379), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: bleater
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: python:3.11-slim
        command: ["python", "/app/redis_server.py"]
        ports:
        - containerPort: 6379
        volumeMounts:
        - name: redis-script
          mountPath: /app
      volumes:
      - name: redis-script
        configMap:
          name: redis-script
          defaultMode: 0555
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: bleater
spec:
  selector:
    app: redis
  ports:
  - name: redis
    port: 6379
    targetPort: 6380  # <--- SABOTAGE 1: Wrong target port!
EOF

# ─────────────────────────────────────────────────────────────────────────────
# LOKI MOCK
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-script
  namespace: logging
data:
  server.py: |
    import json, os, re, urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer
    STORE = "/data/logs.jsonl"
    os.makedirs("/data", exist_ok=True)
    open(STORE, "a", encoding="utf-8").close()

    def load_entries():
        entries = []
        with open(STORE, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line: continue
                try: entries.append(json.loads(line))
                except json.JSONDecodeError: continue
        return entries

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): return
        def _send(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            if self.path != "/loki/api/v1/push":
                self._send(404, {"status": "error"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            with open(STORE, "a", encoding="utf-8") as handle:
                for stream in payload.get("streams", []):
                    labels = stream.get("stream", {})
                    for ts, message in stream.get("values", []):
                        handle.write(json.dumps({"ts": str(ts), "labels": labels, "message": message}) + "\n")
            self._send(204, {})
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/ready":
                self._send(200, {"status": "ready"})
                return
            if parsed.path != "/loki/api/v1/query":
                self._send(404, {"status": "error"})
                return
            self._send(200, {"status": "success", "data": {"resultType": "streams", "result": []}})
    HTTPServer(("", 3100), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki-gateway
  namespace: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki-gateway
  template:
    metadata:
      labels:
        app: loki-gateway
    spec:
      containers:
      - name: loki-gateway
        image: python:3.11-slim
        command: ["python", "/app/server.py"]
        ports:
        - containerPort: 3100
        readinessProbe:
          httpGet:
            path: /ready
            port: 3100
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
        - name: data
          mountPath: /data
      volumes:
      - name: app
        configMap:
          name: loki-script
          defaultMode: 0555
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki-gateway
  namespace: logging
spec:
  selector:
    app: loki-gateway
  ports:
  - name: http
    port: 3100
    targetPort: 3101  # <--- SABOTAGE 2: Wrong target port for Loki
EOF

# ─────────────────────────────────────────────────────────────────────────────
# BLEAT APP MOCK
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-script
  namespace: bleater
data:
  app.py: |
    import json, os, socket, sys, time, urllib.parse, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    REDIS_URL = os.environ.get("REDIS_URL", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")

    def push_log(level, message):
        payload = {"streams": [{"stream": {"app": "bleat-service", "level": level, "pod": POD_NAME}, "values": [[str(int(time.time() * 1000000000)), message]]}]}
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(LOKI_URL.rstrip("/") + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
        try: urllib.request.urlopen(request, timeout=2)
        except Exception: pass
        print(message, flush=True)

    def fail(message):
        push_log("error", message)
        sys.exit(1)

    if "\r" in REDIS_URL or "\n" in REDIS_URL:
        fail(f"invalid address: REDIS_URL contains control characters: {REDIS_URL!r}")

    parsed = urllib.parse.urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname or not parsed.port:
        fail(f"invalid address: malformed REDIS_URL={REDIS_URL!r}")

    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as sock:
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            response = sock.recv(64)
    except OSError as exc:
        fail(f"connection refused: {exc}")

    if b"PONG" not in response:
        fail(f"invalid redis response: {response!r}")

    push_log("info", f"redis connection established to {parsed.hostname}:{parsed.port}")
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): return
        def do_GET(self):
            if self.path == "/ready":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            else:
                self.send_response(200)
                self.end_headers()
    HTTPServer(("", 8080), Handler).serve_forever()
EOF

# ─────────────────────────────────────────────────────────────────────────────
# LOCAL REPO INITIALIZATION
# Issues are intentionally vague — no explicit port numbers, no CronJob
# namespace hints.  The agent must investigate the cluster to find root causes.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /home/ubuntu/bleater-app/k8s \
         /home/ubuntu/bleater-app/.gitea/workflows \
         /home/ubuntu/bleater-app/issues
cd /home/ubuntu/bleater-app

cat <<'EOF' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
EOF

cat <<'EOF' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "tests passed"
EOF

# Issue 1 — symptom-focused, NO explicit port numbers, NO CronJob namespace/name
cat << 'EOF' > issues/issue-1-prod-down.md
Prod down: bleat-service crash-looping, logs gone dark

bleat-service has been crash-looping since this morning. From the few stderr lines I caught before it died it looks like it cannot reach Redis at all — something about an invalid address or connection refused. The error message is weird though, because the config looks fine at first glance.

To make things harder to debug, our centralised logging has been silent for a while. I'm not seeing any bleat-service entries coming through to Loki, which is making this much harder to trace.

There's also something strange going on with the config itself: even when I thought I fixed it, the problem came back. I don't know if there's some background automation touching things, but it feels like our fixes aren't sticking. Worth auditing what's running in the cluster that might be modifying configs automatically.

Goal: get bleat-service healthy, connected to Redis, and logging again.
EOF

# Issue 2 — vague about what encoding/linting is needed, no script path given
cat << 'EOF' > issues/issue-2-ci-validation.md
CI doesn't catch invisible character corruption in manifests

We've been bitten more than once by Kubernetes manifests that look correct in a text editor but contain invisible characters (things like carriage returns from Windows-edited files) that silently break runtime behaviour.

We need some kind of validation step in the CI pipeline that checks our k8s manifests for this class of problem before they can be merged. Ideally a script we can call in the workflow that exits non-zero when it detects corruption.
EOF

# Give the ubuntu user permission to edit these files
chown -R ubuntu:ubuntu /home/ubuntu/bleater-app \
    || chown -R 1000:1000 /home/ubuntu/bleater-app \
    || true

kubectl apply -f k8s/bleat-service-configmap.yaml

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bleat-service
  namespace: bleater
spec:
  replicas: 2
  selector:
    matchLabels:
      app: bleat-service
  template:
    metadata:
      labels:
        app: bleat-service
    spec:
      containers:
      - name: bleat-service
        image: python:3.11-slim
        command: ["python", "/app/app.py"]
        env:
        - name: REDIS_URL
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: REDIS_URL
        - name: LOKI_URL
          value: http://loki-gateway.logging.svc.cluster.local:3100
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
        configMap:
          name: bleat-service-script
          defaultMode: 0555
EOF

echo "Waiting for redis and loki deployments..."
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=180s || true
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=180s || true

echo "Waiting for bleat-service pods to appear in broken state..."
sleep 10
kubectl get deployment bleat-service -n "${BLEATER_NS}" \
    -o jsonpath='{.metadata.uid}' > "${UID_FILE}"

kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for p in data.get("items", []):
    if not p["metadata"].get("deletionTimestamp") and p["metadata"]["name"].startswith("bleat-service-"):
        print(p["metadata"]["name"])
' | sort > "${PODS_FILE}"

chmod 400 "${UID_FILE}" "${PODS_FILE}"


# ─────────────────────────────────────────────────────────────────────────────
# RBAC: grant the agent's ServiceAccount read/write access to monitoring ns
# (so it can discover and delete the second CronJob once it finds it)
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ubuntu-user-monitoring-admin
  namespace: monitoring
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-user-monitoring-admin-binding
  namespace: monitoring
subjects:
- kind: ServiceAccount
  name: ubuntu-user
  namespace: default
roleRef:
  kind: Role
  name: ubuntu-user-monitoring-admin
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Setup complete."
