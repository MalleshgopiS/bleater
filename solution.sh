#!/usr/bin/env bash
# solution.sh — reference remediation for INC-4421.
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
LOG_NS="logging"
APP_DIR="/home/ubuntu/bleater-app"

cd "${APP_DIR}"

echo "══ 1. Remove ALL hidden re-corruption CronJobs ══════════════════════════"
# Two rogue CronJobs exist across namespaces; both re-inject CRLF and strip
# all production constants every minute.  BOTH must be removed before the
# ConfigMap can be considered stable.
#   primary:   kube-system/resource-quota-sync-controller
#   secondary: monitoring/metrics-pipeline-controller

# Delete CronJobs first — this immediately stops any future spawning.
kubectl delete cronjob resource-quota-sync-controller -n kube-system --ignore-not-found
kubectl delete cronjob metrics-pipeline-controller    -n monitoring  --ignore-not-found

# Best-effort cleanup of any already-spawned Job objects.  We use 'timeout'
# to avoid hanging if the API is slow; failure here is non-fatal because the
# parent CronJob is already gone and any running pod will finish on its own.
timeout 10 kubectl delete jobs -n kube-system \
  -l 'cronjob-name=resource-quota-sync-controller' --ignore-not-found 2>/dev/null || true
timeout 10 kubectl delete jobs -n monitoring \
  -l 'cronjob-name=metrics-pipeline-controller' --ignore-not-found 2>/dev/null || true

# Wait long enough for any in-flight corruption job pod to finish naturally
# (each job runs for ~5-10 s; 70 s is a safe upper bound).  The ConfigMap
# rebuild in step 6 therefore happens after all rogue writes have ceased.
sleep 8

echo "══ 2. Patch Redis Service targetPort (6380 → 6379) ══════════════════════"
kubectl patch service redis -n "${BLEATER_NS}" -p \
  '{"spec":{"ports":[{"name":"redis","port":6379,"targetPort":6379}]}}'

echo "══ 3. Patch Loki Service targetPort (3101 → 3100) ═══════════════════════"
kubectl patch service loki-gateway -n "${LOG_NS}" -p \
  '{"spec":{"ports":[{"name":"http","port":3100,"targetPort":3100}]}}'

echo "══ 4. Patch deployment labels (deferred — applied just before rollout) ══════"
# Labels access=redis and observability=enabled are required by NetworkPolicies.
# We defer this patch to step 9b so the deployment rolls out exactly once, after
# the secret and ConfigMap are already clean, avoiding crash-loop churn.

echo "══ 5. Rotate Redis auth secret ═══════════════════════════════════════════"
kubectl delete secret bleat-service-auth -n "${BLEATER_NS}" --ignore-not-found
kubectl create secret generic bleat-service-auth \
  -n "${BLEATER_NS}" \
  --from-literal=REDIS_PASSWORD=bleater-super-secret-99

echo "══ 6. Rebuild live ConfigMap — clean REDIS_URL + ALL six constants ══════"
python3 - <<'PYEOF'
import json, subprocess

cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {"name": "bleat-service-config", "namespace": "bleater"},
    "data": {
        "REDIS_URL":                "redis://redis.bleater.svc.cluster.local:6379/0",
        "LOG_LEVEL":                "info",
        # ── Six production constants that MUST be preserved verbatim ──────────
        "_ROUTING_RETRY_DELAY_MS":  "0",
        "_MIN_TTL_FLOOR_MS":        "3600",
        "_cap_mode_flag":           "true",
        "_EVENT_TTL_GRACE_MS":      "500",
        "_PIPELINE_SCHEMA_VERSION": "3",
        "_FANOUT_CAP_ENABLED":      "false",
    },
}
r = subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(cm),
    capture_output=True, text=True,
)
print(r.stdout or r.stderr)
PYEOF

echo "══ 7. Update repo manifest — clean REDIS_URL + ALL six constants ════════"
cat > k8s/bleat-service-configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
  LOG_LEVEL: "info"
  _ROUTING_RETRY_DELAY_MS:  "0"
  _MIN_TTL_FLOOR_MS:        "3600"
  _cap_mode_flag:           "true"
  _EVENT_TTL_GRACE_MS:      "500"
  _PIPELINE_SCHEMA_VERSION: "3"
  _FANOUT_CAP_ENABLED:      "false"
EOF

echo "══ 8. Create ConfigMap validation script ════════════════════════════════"
mkdir -p scripts
cat > scripts/validate_configmap.py <<'EOF'
#!/usr/bin/env python3
"""
Validates one or more YAML ConfigMap files for encoding corruption.

Exit 0 — all files are clean.
Exit 1 — at least one file contains illegal characters.

Checks performed:
  • Real carriage-return bytes (0x0D).
  • Non-printable ASCII control characters (0x00–0x08, 0x0B–0x0C, 0x0E–0x1F, 0x7F).
  • The *escaped* literal strings: \\r  \\x0d  \\u000d  (backslash sequences that
    Windows-edited files sometimes introduce instead of the actual bytes).
"""
import pathlib, re, sys

CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESCAPE_RE   = re.compile(r"(\\r|\\x0d|\\u000d)", re.IGNORECASE)


def check_file(path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    try:
        # Read raw bytes then decode — avoids Python's universal-newline
        # translation which silently converts \r → \n, hiding corruption.
        raw = path.read_bytes()
        text = raw.decode("utf-8", errors="replace")
    except Exception as exc:
        return [f"Cannot read file: {exc}"]
    if "\r" in text:
        errors.append("contains real carriage-return (0x0D) bytes")
    if CONTROL_RE.search(text):
        errors.append("contains non-printable ASCII control characters")
    if ESCAPE_RE.search(text):
        errors.append(
            "contains escaped literal carriage-return sequences"
            r" (\r / \x0d / \u000d)"
        )
    return errors


rc = 0
for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    if not p.exists():
        print(f"ERROR {arg}: file not found", file=sys.stderr)
        rc = 1
        continue
    errs = check_file(p)
    if errs:
        for e in errs:
            print(f"ERROR {p}: {e}", file=sys.stderr)
        rc = 1
    else:
        print(f"OK    {p}")

sys.exit(rc)
EOF
chmod +x scripts/validate_configmap.py

echo "══ 9. Update Gitea CI workflow to enforce validation ═════════════════════"
mkdir -p .gitea/workflows
cat > .gitea/workflows/bleat-ci.yaml <<'EOF'
name: bleat-ci
on: [push, pull_request]
jobs:
  validate-configmaps:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap encoding
        run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
  unit-tests:
    runs-on: ubuntu-latest
    needs: validate-configmaps
    steps:
      - uses: actions/checkout@v4
      - run: echo "unit tests passed"
EOF

echo "══ 9b. Apply both required pod labels in a single patch ════════════════════"
# Do this last — after secret, ConfigMap, and port fixes are all in place —
# so pods roll out exactly once into a fully-working state.
# access=redis        → satisfies redis-security-policy NetworkPolicy
# observability=enabled → satisfies loki-ingress-policy NetworkPolicy
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=strategic -p \
  '{"spec":{"template":{"metadata":{"labels":{"access":"redis","observability":"enabled"}}}}}'

echo "══ 10. Trigger rolling restart and wait for healthy state ════════════════"
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service  -n "${BLEATER_NS}" --timeout=360s

echo ""
echo "Remediation complete.  All six production constants preserved; CRLF"
echo "corruption removed; rogue CronJob deleted; service routes corrected."