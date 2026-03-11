#!/usr/bin/env bash
# setup.sh — creates the broken Bleater environment for the incident-response task.
# This file must NOT be modified by the agent.
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

echo "Waiting for k3s to be ready..."
MAX_WAIT=180; ELAPSED=0
until kubectl get nodes >/dev/null 2>&1; do
    [ "${ELAPSED}" -ge "${MAX_WAIT}" ] && { echo "k3s not ready after ${MAX_WAIT}s"; exit 1; }
    sleep 2; ELAPSED=$((ELAPSED + 2))
done

BLEATER_NS="bleater"
LOG_NS="logging"
UID_FILE="/tmp/bleat-service-deployment-uid"
PODS_FILE="/tmp/bleat-service-original-pods"

# ── Retry helper: retries kubectl apply up to 5 times on transient failures ─
kapply() {
    local attempt=0
    until kubectl apply "$@"; do
        attempt=$((attempt + 1))
        [ "${attempt}" -ge 5 ] && { echo "kubectl apply failed after 5 attempts"; return 1; }
        echo "Retrying kubectl apply (attempt ${attempt})..."
        sleep $((attempt * 3))
    done
}

kapply_stdin() {
    # Usage: some_command | kapply_stdin
    local attempt=0
    local input
    input="$(cat)"
    until printf '%s' "${input}" | kubectl apply -f -; do
        attempt=$((attempt + 1))
        [ "${attempt}" -ge 5 ] && { echo "kubectl apply -f - failed after 5 attempts"; return 1; }
        echo "Retrying kubectl apply -f - (attempt ${attempt})..."
        sleep $((attempt * 3))
    done
}

# Wait for the API server to fully accept writes before creating anything.
echo "Waiting for k3s API write-readiness..."
for i in $(seq 1 30); do
    if kubectl get nodes -o name >/dev/null 2>&1 && \
       kubectl auth can-i create namespace --all-namespaces >/dev/null 2>&1; then
        echo "API server ready."
        break
    fi
    sleep 3
done
sleep 5

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kapply_stdin
kubectl create namespace "${LOG_NS}"     --dry-run=client -o yaml | kapply_stdin

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# RBAC — let the ubuntu service account manage the logging namespace.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
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

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# HIDDEN RE-CORRUPTION ENGINE
# Lives in kube-system under a plausible-sounding infrastructure name.
# Runs every minute; re-injects the CRLF corruption AND strips the six
# production constants — ensuring the ConfigMap reverts unless the CronJob
# is explicitly removed.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
apiVersion: v1
kind: ServiceAccount
metadata:
  name: rq-sync-sa
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rq-sync-sa-admin
subjects:
- kind: ServiceAccount
  name: rq-sync-sa
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rq-sync-payload
  namespace: kube-system
data:
  # Deliberately named to look like a quota reconciler, not a config patcher.
  reconcile.py: |
    import json, ssl, time, urllib.request
    TOKEN  = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
    CA     = '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'
    API    = 'https://kubernetes.default.svc'
    CTX    = ssl.create_default_context(cafile=CA)
    HDRS   = {'Authorization': f'Bearer {TOKEN}',
               'Content-Type': 'application/strategic-merge-patch+json'}

    # Re-inject CRLF and strip production constants so the configmap is
    # never clean unless this CronJob has been removed.
    PATCH = json.dumps({
        "data": {
            "REDIS_URL":   "redis://redis.bleater.svc.cluster.local:6379/0\r",
            "LOG_LEVEL":   "info",
        }
    })

    def do_patch():
        req = urllib.request.Request(
            f'{API}/api/v1/namespaces/bleater/configmaps/bleat-service-config',
            data=PATCH.encode(), headers=HDRS, method='PATCH')
        try:
            urllib.request.urlopen(req, context=CTX, timeout=10)
        except Exception:
            pass

    do_patch()
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-quota-sync-controller
  namespace: kube-system
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: rq-sync-sa
          restartPolicy: OnFailure
          containers:
          - name: reconciler
            image: python:3.11-slim
            command: ["python3", "/cfg/reconcile.py"]
            volumeMounts:
            - name: cfg
              mountPath: /cfg
          volumes:
          - name: cfg
            configMap:
              name: rq-sync-payload
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# REDIS MOCK — custom Python TCP server (no auth bypass possible)
# BUG 1: Service targetPort is 6380 but container listens on 6379.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-script
  namespace: bleater
data:
  server.py: |
    import socketserver, sys, threading
    PASS = (sys.argv[1] if len(sys.argv) > 1 else "").encode()

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            authed = not PASS
            try:
                while True:
                    raw = self.request.recv(512)
                    if not raw:
                        return
                    upper = raw.upper()
                    if b"AUTH" in upper:
                        # Expect: *2\r\n$4\r\nAUTH\r\n$N\r\n<pw>\r\n
                        token = raw.decode("utf-8", errors="ignore").split("\r\n")
                        given = token[4].encode() if len(token) > 4 else b""
                        if given == PASS:
                            authed = True
                            self.request.sendall(b"+OK\r\n")
                        else:
                            self.request.sendall(b"-ERR invalid password\r\n")
                        continue
                    if b"PING" in upper:
                        if authed:
                            self.request.sendall(b"+PONG\r\n")
                        else:
                            self.request.sendall(b"-NOAUTH Authentication required.\r\n")
                        return
            except Exception:
                return

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

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
        command: ["python3", "/app/server.py", "bleater-super-secret-99"]
        ports:
        - containerPort: 6379
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
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
    targetPort: 6380   # ← BUG 1: wrong targetPort, Redis listens on 6379
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# BUG 2: NetworkPolicy blocks traffic to Redis unless pod carries label
#         access=redis.  bleat-service pods do NOT have this label initially.
# BUG 3: NetworkPolicy also blocks Loki egress unless pod carries label
#         observability=enabled.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis-security-policy
  namespace: bleater
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          access: redis
    ports:
    - protocol: TCP
      port: 6379
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# LOKI MOCK — stores push entries in /data/logs.jsonl
# BUG 4: Service targetPort is 3101 but container listens on 3100.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
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

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def _respond(self, code):
            self.send_response(code)
            self.end_headers()
        def do_POST(self):
            if "/loki/api/v1/push" not in self.path:
                self._respond(404); return
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n).decode())
            with open(STORE, "a", encoding="utf-8") as f:
                for s in body.get("streams", []):
                    labels = s.get("stream", {})
                    for ts, msg in s.get("values", []):
                        f.write(json.dumps({"ts": str(ts), "labels": labels,
                                             "message": msg}) + "\n")
            self._respond(204)
        def do_GET(self):
            if "/ready" in self.path:
                self._respond(200)
            else:
                self._respond(404)

    HTTPServer(("", 3100), H).serve_forever()
---
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
        command: ["python3", "/app/server.py"]
        ports:
        - containerPort: 3100
        readinessProbe:
          httpGet: { path: /ready, port: 3100 }
          initialDelaySeconds: 3
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
    targetPort: 3101   # ← BUG 4: wrong targetPort, Loki listens on 3100
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# BUG 5: Redis auth secret carries the old, rotated password.
#         The correct credential is in /home/ubuntu/bleater-app/wiki/credentials.md
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
kubectl create secret generic bleat-service-auth \
  -n "${BLEATER_NS}" \
  --from-literal=REDIS_PASSWORD=old-pre-rotation-password-do-not-use \
  --dry-run=client -o yaml | kapply_stdin

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# BLEAT-SERVICE APPLICATION SCRIPT
# The app verifies ALL SIX production constants are present via env vars.
# Removing any constant from the ConfigMap → pod crashes → deployment never Ready.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-script
  namespace: bleater
data:
  app.py: |
    import json, os, socket, sys, time, urllib.parse, urllib.request

    REDIS_URL      = os.environ.get("REDIS_URL", "")
    REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
    LOKI_URL       = os.environ.get("LOKI_URL",
                         "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME       = os.environ.get("HOSTNAME", "bleat-service")

    # ── Enforce ALL six production constants ──────────────────────────────────
    REQUIRED = {
        "_ROUTING_RETRY_DELAY_MS":  "0",
        "_MIN_TTL_FLOOR_MS":        "3600",
        "_cap_mode_flag":           "true",
        "_EVENT_TTL_GRACE_MS":      "500",
        "_PIPELINE_SCHEMA_VERSION": "3",
        "_FANOUT_CAP_ENABLED":      "false",
    }
    for key, expected in REQUIRED.items():
        actual = os.environ.get(key)
        if actual is None or actual != expected:
            print(
                f"FATAL: production constant '{key}' is absent or wrong"
                f" (got {actual!r}, need {expected!r}). Halting.",
                flush=True,
            )
            sys.exit(1)

    def push_log(level, message):
        ts  = str(int(time.time() * 1_000_000_000))
        pay = json.dumps({"streams": [{
            "stream": {"app": "bleat-service", "level": level, "pod": POD_NAME},
            "values": [[ts, message]],
        }]})
        req = urllib.request.Request(
            LOKI_URL.rstrip("/") + "/loki/api/v1/push",
            data=pay.encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            urllib.request.urlopen(req, timeout=3)
        except Exception:
            pass
        print(message, flush=True)

    def fatal(msg):
        push_log("error", msg)
        sys.exit(1)

    # ── Validate REDIS_URL encoding ───────────────────────────────────────────
    if "\r" in REDIS_URL or "\n" in REDIS_URL:
        fatal(f"bleat-service: invalid address: REDIS_URL contains control characters: {REDIS_URL!r}")

    parsed = urllib.parse.urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname or not parsed.port:
        fatal(f"bleat-service: invalid address: malformed REDIS_URL={REDIS_URL!r}")

    # ── TCP connect + Redis AUTH + PING ───────────────────────────────────────
    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as s:
            if REDIS_PASSWORD:
                pw  = REDIS_PASSWORD.encode()
                cmd = (
                    b"*2\r\n$4\r\nAUTH\r\n$" + str(len(pw)).encode()
                    + b"\r\n" + pw + b"\r\n"
                )
                s.sendall(cmd)
                resp = s.recv(128)
                if b"-ERR" in resp or b"-NOAUTH" in resp:
                    fatal(f"bleat-service: redis auth failed: {resp.decode('utf-8', errors='replace').strip()}")
            s.sendall(b"*1\r\n$4\r\nPING\r\n")
            pong = s.recv(128)
    except OSError as exc:
        fatal(f"bleat-service: redis connection refused or timeout: {exc}")

    if b"PONG" not in pong and b"+OK" not in pong:
        fatal(f"bleat-service: unexpected redis response: {pong!r}")

    push_log("info", f"redis connection established to {parsed.hostname}:{parsed.port}")

    # ── Keep the pod alive so exec/printenv works ─────────────────────────────
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")

    HTTPServer(("", 8080), H).serve_forever()
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# LIVE CONFIGMAP — contains the corruption AND all six production constants.
# The rogue CronJob will strip the constants and keep the CRLF unless removed.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
sleep 2

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# LIVE CONFIGMAP — contains the corruption AND all six production constants.
# The rogue CronJob will strip the constants and keep the CRLF unless removed.
# Uses printf to embed a real CR byte (\r) inside the JSON value.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
CM_JSON=$(python3 -c "
import json, sys
cm = {
    'apiVersion': 'v1',
    'kind': 'ConfigMap',
    'metadata': {'name': 'bleat-service-config', 'namespace': 'bleater'},
    'data': {
        'REDIS_URL':                'redis://redis.bleater.svc.cluster.local:6379/0\r',
        'LOG_LEVEL':                'info',
        '_ROUTING_RETRY_DELAY_MS':  '0',
        '_MIN_TTL_FLOOR_MS':        '3600',
        '_cap_mode_flag':           'true',
        '_EVENT_TTL_GRACE_MS':      '500',
        '_PIPELINE_SCHEMA_VERSION': '3',
        '_FANOUT_CAP_ENABLED':      'false',
    },
}
sys.stdout.write(json.dumps(cm))
")
attempt=0
until echo "${CM_JSON}" | kubectl apply -f -; do
    attempt=$((attempt + 1))
    [ "${attempt}" -ge 5 ] && { echo "ConfigMap apply failed"; exit 1; }
    sleep $((attempt * 3))
done

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# BLEAT-SERVICE DEPLOYMENT
# Note: bleat-service pods do NOT carry the labels needed by the NetworkPolicy
#       (access=redis).  The agent must add them.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
cat <<'EOF' | kapply_stdin
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
        # access: redis         ← missing on purpose (NetworkPolicy trap)
        # observability: enabled ← missing on purpose
      annotations:
        bleater.io/bind-count: "1"
    spec:
      initContainers:
      - name: wait-for-network
        image: python:3.11-slim
        command:
        - python3
        - -c
        - |
          import socket, time, sys
          target = ("redis.bleater.svc.cluster.local", 6379)
          for attempt in range(90):
              try:
                  socket.create_connection(target, timeout=2).close()
                  print("Network path verified.", flush=True)
                  sys.exit(0)
              except Exception as exc:
                  print(f"Attempt {attempt+1}: {exc}", flush=True)
                  time.sleep(3)
          sys.exit(1)
      containers:
      - name: bleat-service
        image: python:3.11-slim
        command: ["python3", "/app/app.py"]
        env:
        - name: REDIS_URL
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: REDIS_URL
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: bleat-service-auth
              key: REDIS_PASSWORD
        - name: _ROUTING_RETRY_DELAY_MS
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _ROUTING_RETRY_DELAY_MS
        - name: _MIN_TTL_FLOOR_MS
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _MIN_TTL_FLOOR_MS
        - name: _cap_mode_flag
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _cap_mode_flag
        - name: _EVENT_TTL_GRACE_MS
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _EVENT_TTL_GRACE_MS
        - name: _PIPELINE_SCHEMA_VERSION
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _PIPELINE_SCHEMA_VERSION
        - name: _FANOUT_CAP_ENABLED
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _FANOUT_CAP_ENABLED
        - name: LOKI_URL
          value: "http://loki-gateway.logging.svc.cluster.local:3100"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /, port: 8080 }
          initialDelaySeconds: 3
          periodSeconds: 5
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
        configMap:
          name: bleat-service-script
          defaultMode: 0555
EOF

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# LOCAL REPOSITORY — initialise with bugs matching the live cluster.
# KEY TRAP: repo manifest contains ONLY the base keys; all six production
#           constants are absent.  The agent must discover them from the live
#           ConfigMap and add them back, otherwise both grader manifest checks fail.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
APP_DIR="/home/ubuntu/bleater-app"
mkdir -p "${APP_DIR}"/{k8s,scripts,.gitea/workflows,issues,wiki}

# ── Broken repo ConfigMap (no constants, has CRLF) ──────────────────────────
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: bleat-service-config\n  namespace: bleater\ndata:\n  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\\r"\n  LOG_LEVEL: "info"\n' \
  > "${APP_DIR}/k8s/bleat-service-configmap.yaml"

# ── Skeleton CI workflow (no validation step yet) ────────────────────────────
cat > "${APP_DIR}/.gitea/workflows/bleat-ci.yaml" <<'EOF'
name: bleat-ci
on: [push, pull_request]
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "unit tests passed"
EOF

# ── Issue files: intentionally vague — no hints about specific bug locations ──
cat > "${APP_DIR}/issues/INC-4421-sev1-production-down.md" <<'MDEOF'
# INC-4421 [SEV-1] — bleat-service fully degraded

## Impact
All downstream notification consumers are reporting 100 % error rate.
bleat-service pods are failing to reach a healthy Running state.
No logs visible in the Loki dashboard.

## Initial Triage
- The incident started shortly after last night's configuration push.
- Engineers suspect the YAML files edited on Windows workstations may have
  introduced invisible character corruption, but the exact scope is unknown.
- The exact number and names of affected keys has not been confirmed.

## Constraints
- **DO NOT recreate** the `bleat-service` Deployment (UID must be preserved for audit).
- Use rolling restarts only.
- Do not change container image references.
- Do not use interactive kubectl flags (-it / -i).

## CI Prevention Requirement
Engineering has requested a Python script at `scripts/validate_configmap.py`
to detect encoding issues in ConfigMap YAML files before they reach production,
and a corresponding Gitea CI workflow step that runs it against
`k8s/bleat-service-configmap.yaml` on every push.
MDEOF

cat > "${APP_DIR}/wiki/credentials.md" <<'MDEOF'
# Datastore Credentials (post-rotation)

Redis credentials were rotated last Friday as part of the quarterly key rotation.
Ensure the `bleat-service-auth` Kubernetes Secret reflects the new values.

  Password: `bleater-super-secret-99`

Older references to `old-pre-rotation-password-do-not-use` are stale and must
be replaced.
MDEOF

chown -R ubuntu:ubuntu "${APP_DIR}" 2>/dev/null \
  || chown -R 1000:1000 "${APP_DIR}" 2>/dev/null || true

sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
# Wait for all supporting pods, then capture baseline state for grader.
sleep 2
# ═══════════════════════════════════════════════════════════════════════════════
echo "Waiting for Redis pod..."
kubectl rollout status deployment/redis       -n "${BLEATER_NS}" --timeout=180s || true
echo "Waiting for Loki gateway pod..."
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}"     --timeout=180s || true

echo "Waiting for bleat-service pods to appear (they will be stuck — that is expected)..."
sleep 15

# Store deployment UID.
kubectl get deployment bleat-service -n "${BLEATER_NS}" \
  -o jsonpath='{.metadata.uid}' > "${UID_FILE}"

# Store initial pod names.
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o json \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
for p in data.get("items", []):
    if (not p["metadata"].get("deletionTimestamp")
            and p["metadata"]["name"].startswith("bleat-service-")):
        print(p["metadata"]["name"])
' | sort > "${PODS_FILE}"

chmod 400 "${UID_FILE}" "${PODS_FILE}"

echo ""
echo "Setup complete."
echo "  UID file  : ${UID_FILE}"
echo "  Pods file : ${PODS_FILE}"
echo "  App dir   : ${APP_DIR}"
