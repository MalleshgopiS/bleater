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

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${LOG_NS}" --dry-run=client -o yaml | kubectl apply -f -

# --- BATCH APPLY 1: RBAC & MOCKS ---
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: ubuntu-user-logging-admin, namespace: logging}
rules: [{apiGroups: ["*"], resources: ["*"], verbs: ["*"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ubuntu-user-logging-admin-binding, namespace: logging}
subjects: [{kind: ServiceAccount, name: ubuntu-user, namespace: default}]
roleRef: {kind: Role, name: ubuntu-user-logging-admin, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: global-saboteur}
rules: 
- apiGroups: [""]
  resources: ["configmaps", "pods", "services", "secrets"]
  verbs: ["patch", "get", "list", "delete", "create"]
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/scale"]
  verbs: ["patch", "get", "list", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: saboteur-binding-default}
subjects: [{kind: ServiceAccount, name: default, namespace: default}]
roleRef: {kind: ClusterRole, name: global-saboteur, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: saboteur-binding-logging}
subjects: [{kind: ServiceAccount, name: default, namespace: logging}]
roleRef: {kind: ClusterRole, name: global-saboteur, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: redis-script, namespace: bleater}
data:
  redis_server.py: |
    import socketserver, sys
    expected_pass = "bleater-super-secret-99"
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                authenticated = False
                while True:
                    data = self.request.recv(1024)
                    if not data: return
                    data_str = data.upper().decode('utf-8', errors='ignore')
                    if "AUTH" in data_str:
                        if expected_pass in data.decode('utf-8', errors='ignore'):
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
metadata: {name: redis, namespace: bleater}
spec:
  replicas: 1
  selector: {matchLabels: {app: redis}}
  template:
    metadata: {labels: {app: redis}}
    spec:
      containers:
      - name: redis
        image: python:3.11-slim
        command: ["python", "/app/redis_server.py"]
        ports: [{containerPort: 6379}]
        volumeMounts: [{name: redis-script, mountPath: /app}]
      volumes: [{name: redis-script, configMap: {name: redis-script, defaultMode: 0555}}]
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: bleater}
spec:
  selector: {app: redis}
  ports: [{name: redis, port: 6379, targetPort: 6380}]
EOF

sleep 2

# --- BATCH APPLY 2: LOKI MOCK ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: loki-script, namespace: logging}
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
metadata: {name: loki-gateway, namespace: logging}
spec:
  replicas: 1
  selector: {matchLabels: {app: loki-gateway}}
  template:
    metadata: {labels: {app: loki-gateway}}
    spec:
      containers:
      # Container 0: The actual app
      - name: loki-gateway
        image: python:3.11-slim
        command: ["python", "/app/server.py"]
        ports: [{containerPort: 3100}]
        readinessProbe:
          httpGet: {path: /ready, port: 3100}
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - {name: app, mountPath: /app}
        - {name: data, mountPath: /data}
      # Container 1: The valid decoy
      - name: fluent-bit-logger
        image: busybox:latest
        command: ["sh", "-c", "while true; do echo 'Valid log stream active'; sleep 3600; done"]
      # Container 2: The Malicious Reverter
      - name: metrics-sidecar
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl patch configmap bleat-service-config -n bleater --type merge -p '{\"data\":{\"REDIS_URL\":\"redis://redis.bleater.svc.cluster.local:6379/0\\\\r\"}}' >/dev/null 2>&1 || true; sleep 1.5; done"]
      volumes:
      - {name: app, configMap: {name: loki-script, defaultMode: 0555}}
      - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata: {name: loki-gateway, namespace: logging}
spec:
  selector: {app: loki-gateway}
  ports: [{name: http, port: 3100, targetPort: 3101}]
EOF

sleep 2

# --- BATCH APPLY 3: MAIN APP MOCK AND CONFIGS ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: bleat-service-script, namespace: bleater}
data:
  app.py: |
    import json, os, socket, sys, time, urllib.parse, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    REDIS_URL = os.environ.get("REDIS_URL", "")
    REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")

    if os.environ.get("_cap_mode_flag") != "true" or not os.environ.get("_MIN_TTL_FLOOR_MS"):
        print("FATAL: Missing internal constants. Halting.", flush=True)
        sys.exit(1)

    def push_log(level, message):
        payload = {"streams": [{"stream": {"app": "bleat-service", "level": level, "pod": POD_NAME}, "values": [[str(int(time.time() * 1000000000)), message]]}]}
        body = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(LOKI_URL.rstrip("/") + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
        try: urllib.request.urlopen(req, timeout=1)
        except Exception: pass

    def fail(message):
        push_log("error", message)
        sys.exit(1)
        
    if os.environ.get("SUPPRESS_WARNINGS") != "1":
        push_log("error", "Deprecated config format detected. Set SUPPRESS_WARNINGS=1 to resolve.")

    if "\r" in REDIS_URL or "\n" in REDIS_URL:
        fail("invalid address: REDIS_URL contains control characters")

    parsed = urllib.parse.urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname or not parsed.port:
        fail("invalid address: malformed REDIS_URL")

    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as sock:
            if REDIS_PASSWORD:
                sock.sendall(f"*2\r\n$4\r\nAUTH\r\n${len(REDIS_PASSWORD)}\r\n{REDIS_PASSWORD}\r\n".encode())
                resp = sock.recv(1024)
                if b"-ERR" in resp: fail("redis auth failed")
            
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            response = sock.recv(1024)
            if b"PONG" not in response and b"+OK" not in response:
                fail("invalid redis response")
    except OSError as exc:
        fail("connection refused or timeout")

    push_log("info", "redis connection established")
    
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): return
        def do_GET(self):
            if self.path == "/ready":
                # Ensure success log is pushed on every readiness check to avoid timing out in grader
                push_log("info", "redis connection established")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            else:
                self.send_response(200)
                self.end_headers()
    HTTPServer(("", 8080), Handler).serve_forever()
---
apiVersion: v1
kind: ConfigMap
metadata: 
  name: bleat-service-config
  namespace: bleater
immutable: true
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
  _ROUTING_RETRY_DELAY_MS: "0"
  _MIN_TTL_FLOOR_MS: "3600"
  _cap_mode_flag: "true"
---
apiVersion: v1
kind: Secret
metadata: {name: bleat-service-auth, namespace: bleater}
type: Opaque
data:
  REDIS_PASSWORD: b2xkLWludmFsaWQtcGFzc3dvcmQ=
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: bleat-service, namespace: bleater}
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: "25%" # 🚨 Valid K8s API, but deadlocks when paired with maxUnavailable:0 PDB
  selector: {matchLabels: {app: bleat-service}}
  template:
    metadata:
      labels: {app: bleat-service}
      annotations: {bleater.io/bind-count: "1"}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - {key: disktype, operator: In, values: [alien-tech]}
      initContainers:
      - name: network-wait
        image: busybox:latest
        command: ["sh", "-c", "sleep infinity"]
      containers:
      - name: bleat-service
        image: python:3.11-slim
        command: ["python", "/app/app.py"]
        env:
        - name: REDIS_URL
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: REDIS_URL}}
        - name: REDIS_PASSWORD
          valueFrom: {secretKeyRef: {name: bleat-service-auth, key: REDIS_PASSWORD}}
        - name: _ROUTING_RETRY_DELAY_MS
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _ROUTING_RETRY_DELAY_MS}}
        - name: _MIN_TTL_FLOOR_MS
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _MIN_TTL_FLOOR_MS}}
        - name: _cap_mode_flag
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _cap_mode_flag}}
        - name: LOKI_URL
          value: http://loki-gateway.logging.svc.cluster.local:3100
        ports: [{containerPort: 8080}]
        readinessProbe:
          httpGet: {path: /ready, port: 8081}
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts: [{name: app, mountPath: /app}]
      volumes:
      - {name: app, configMap: {name: bleat-service-script, defaultMode: 0555}}
EOF

# --- LOCAL REPO INITIALIZATION ---
mkdir -p /home/ubuntu/bleater-app/k8s /home/ubuntu/bleater-app/.gitea/workflows /home/ubuntu/bleater-app/scripts
cat <<'EOF' > /home/ubuntu/bleater-app/k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
EOF
chown -R ubuntu:ubuntu /home/ubuntu/bleater-app || true

echo "Waiting for redis and loki deployments..."
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=180s || true
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=180s || true

# --- BATCH APPLY 4: THE TRAPS ---
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: bleat-service-pdb, namespace: bleater}
spec:
  maxUnavailable: 0
  selector: {matchLabels: {app: bleat-service}}
---
apiVersion: v1
kind: LimitRange
metadata: {name: hidden-mem-limit, namespace: bleater}
spec:
  limits:
  - default: {memory: 5Mi}
    defaultRequest: {memory: 5Mi}
    type: Container
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: kube-dns-allow, namespace: bleater}
spec:
  podSelector: {matchLabels: {app: bleat-service}}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: loki-deny-all, namespace: logging}
spec:
  podSelector: {matchLabels: {app: loki-gateway}}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: baseline-security-rules, namespace: bleater}
spec:
  podSelector: {matchLabels: {role: background-worker}}
  policyTypes: [Ingress]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: cluster-dns-monitor, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: dns-healthcheck}}
  template:
    metadata: {labels: {app: dns-healthcheck}}
    spec:
      containers:
      - name: checker
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl patch deployment bleat-service -n bleater --type=json -p='[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/readinessProbe/httpGet/port\", \"value\": 8081}]' >/dev/null 2>&1 || true; sleep 2; done"]
EOF

# 🚨 DYNAMIC STOCHASTIC REDIS SABOTAGE (50% Chance)
if [ $((RANDOM % 2)) -eq 0 ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: cluster-redis-optimizer, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: storage-mgr}}
  template:
    metadata: {labels: {app: storage-mgr}}
    spec:
      containers:
      - name: optimizer
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl scale deployment redis -n bleater --replicas=0 >/dev/null 2>&1 || true; sleep 2; done"]
EOF
fi

# 🚨 DYNAMIC STOCHASTIC SECRET SABOTAGE (50% Chance)
if [ $((RANDOM % 2)) -eq 0 ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: secret-manager, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: secret-mgr}}
  template:
    metadata: {labels: {app: secret-mgr}}
    spec:
      containers:
      - name: deleter
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl delete secret bleat-service-auth -n bleater >/dev/null 2>&1 || true; sleep 2; done"]
EOF
fi

# 🚨 DYNAMIC STOCHASTIC NETWORK POLICY
if [ $((RANDOM % 2)) -eq 0 ]; then
    POLICY_NAME="total-block-policy-${RANDOM}"
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ${POLICY_NAME}, namespace: bleater}
spec:
  podSelector: {matchLabels: {app: bleat-service}}
  policyTypes: [Ingress]
EOF
fi

sleep 5
TOTAL_PODS=$(kubectl get pods -n "${BLEATER_NS}" --no-headers 2>/dev/null | wc -l || echo 0)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata: {name: default-mem-limit, namespace: bleater}
spec:
  hard: {pods: "$((TOTAL_PODS + 1))"}
EOF

# --- SECURE TRACKING FOR GRADER ---
UID_VAL=$(kubectl get deployment bleat-service -n "${BLEATER_NS}" -o jsonpath='{.metadata.uid}')
kubectl annotate namespace "${BLEATER_NS}" "original-uid=${UID_VAL}" --overwrite
PODS_VAL=$(kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o jsonpath='{.items[*].metadata.name}' | tr ' ' ',')
kubectl annotate namespace "${BLEATER_NS}" "original-pods=${PODS_VAL}" --overwrite

echo "Setup complete."