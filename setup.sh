#!/usr/bin/env bash
set -euo pipefail

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

# --- RBAC FOR LOGGING ---
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: logging
  name: ubuntu-user-logging-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-user-logging-admin-binding
  namespace: logging
subjects:
- kind: ServiceAccount
  name: ubuntu-user
  namespace: default
roleRef:
  kind: Role
  name: ubuntu-user-logging-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# --- REDIS MOCK ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-script
  namespace: bleater
data:
  redis_server.py: |
    import socketserver, sys
    expected_pass = sys.argv[1] if len(sys.argv) > 1 else None
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                authenticated = False if expected_pass else True
                while True:
                    data = self.request.recv(1024)
                    if not data: return
                    data_str = data.upper().decode('utf-8', errors='ignore')
                    if "AUTH" in data_str:
                        if expected_pass and expected_pass in data.decode('utf-8', errors='ignore'):
                            authenticated = True
                            self.request.sendall(b"+OK\r\n")
                        else:
                            self.request.sendall(b"-ERR invalid password\r\n")
                        continue
                    if "PING" in data_str:
                        if not authenticated:
                            self.request.sendall(b"-NOAUTH Authentication required.\r\n")
                        else:
                            self.request.sendall(b"+PONG\r\n")
                        return
            except Exception: return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    Server(("", 6379), Handler).serve_forever()
---
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
        command: ["python", "/app/redis_server.py", "bleater-super-secret-99"]
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
    targetPort: 6380
EOF

# --- LOKI MOCK ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-script
  namespace: logging
data:
  server.py: |
    import json, os, urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer
    STORE = "/data/logs.jsonl"
    os.makedirs("/data", exist_ok=True)
    open(STORE, "a", encoding="utf-8").close()
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
            self._send(200, {"status": "success", "data": {"resultType": "streams", "result": []}})
    HTTPServer(("", 3100), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki-gateway
  namespace: logging
spec:
  replicas: 1
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
    targetPort: 3101
EOF

# --- BLEAT APP DEPLOYMENT ---
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
          value: "redis://redis.bleater.svc.cluster.local:6379/0\r"
        - name: _cap_mode_flag
          value: "true"
        - name: _MIN_TTL_FLOOR_MS
          value: "3600"
EOF

echo "Waiting for deployments to spin up..."
kubectl rollout status deployment/bleat-service -n bleater --timeout=60s || true

# --- STOCHASTIC NETWORK SABOTAGE ---
if [ $((RANDOM % 2)) -eq 0 ]; then
    echo "INJECTING NETWORK CHAOS..."
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: total-block-policy
  namespace: bleater
spec:
  podSelector:
    matchLabels:
      app: bleat-service
  policyTypes:
  - Ingress
EOF
fi

# --- QUOTA TRAP ---
TOTAL_PODS=$(kubectl get pods -n bleater --no-headers 2>/dev/null | wc -l)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: bleater-strict-quota
  namespace: bleater
spec:
  hard:
    pods: "${TOTAL_PODS}"
EOF

echo "Setup complete."