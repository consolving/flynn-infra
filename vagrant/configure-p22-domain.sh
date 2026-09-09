#!/usr/bin/env bash
# configure-p22-domain.sh — Idempotently (re)apply the *.flynn.lab.p22.de
# routing layer + Let's Encrypt + dashboard config to a Flynn cluster.
#
# Motivation: the cluster is bootstrapped with CLUSTER_DOMAIN=demo.localflynn.com
# (ephemeral self-signed CA certs). For external access we add a second routing
# domain (ROUTE_DOMAIN=flynn.lab.p22.de) served with a public AutoDNS-issued
# Let's Encrypt wildcard cert. If node1's disks are rebuilt (fresh bootstrap)
# ALL of this runtime state is lost — routes, the dashboard release env, and the
# ACME configuration. This script re-applies it, and is safe to run repeatedly.
#
# Usage:
#   CONTROLLER_KEY=<controller key> ./configure-p22-domain.sh
#
# Required env:
#   CONTROLLER_KEY          controller API key (see ~/.flynnrc)
# Optional env:
#   CLUSTER_DOMAIN          default: demo.localflynn.com
#   ROUTE_DOMAIN            default: flynn.lab.p22.de
#   CONTROLLER_USER         default: zkid (API key username; value is ignored)
#   CONTROLLER_URL          default: http://controller.$CLUSTER_DOMAIN
#   ACME_DNS_CONFIG         AutoDNS dns_config JSON. When set, the controller's
#                           ACME config is (re)applied from it plus
#                           ACME_EMAIL / ACME_CA_URL / ACME_DNS_PROVIDER.
#   DASHBOARD_ENV_ONLY=1    skip route work, only align the dashboard release env
#
# Routing domain notes:
#   - The LE wildcard is issued via ACME DNS-01 with the AutoDNS provider
#     (context 2258). Public DNS for *.flynn.lab.p22.de must point at the host
#     that DNATs ports 80/443 to node1 (192.168.50.11) for issuance to succeed.
#   - /etc/hosts on the operator host should map the *.flynn.lab.p22.de app
#     hosts to 192.168.50.11.

set -euo pipefail

CONTROLLER_KEY="${CONTROLLER_KEY:?CONTROLLER_KEY is required (see ~/.flynnrc)}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-demo.localflynn.com}"
ROUTE_DOMAIN="${ROUTE_DOMAIN:-flynn.lab.p22.de}"
LE_WILDCARD="*.${ROUTE_DOMAIN}"
CONTROLLER_USER="${CONTROLLER_USER:-zkid}"
CONTROLLER_URL="${CONTROLLER_URL:-http://controller.${CLUSTER_DOMAIN}}"
AUTH=(-u "${CONTROLLER_USER}:${CONTROLLER_KEY}")

# Apps that get a <app>.<ROUTE_DOMAIN> route with the LE wildcard.
# controller uses service "controller"; the rest use "<app>-web".
APPS=(controller dashboard status example-node example-http)

info()  { echo -e "\e[1;32m===> $*\e[0m"; }
warn()  { echo -e "\e[1;33mWARN: $*\e[0m"; }
die()   { echo -e "\e[1;31mFAIL: $*\e[0m" >&2; exit 1; }

req() { # req METHOD PATH [BODYFILE]
    local method="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        curl -sf -g -m 30 "${AUTH[@]}" -H 'Content-Type: application/json' \
            -X "$method" --data-binary "@$body" "${CONTROLLER_URL}${path}"
    else
        curl -sf -g -m 30 "${AUTH[@]}" -X "$method" "${CONTROLLER_URL}${path}"
    fi
}

json() { python3 -c "$1"; }

[[ -x "$(command -v curl)" ]]    || die "curl required"
[[ -x "$(command -v python3)" ]] || die "python3 required"

info "Controller: ${CONTROLLER_URL}  route domain: ${ROUTE_DOMAIN}  wildcard: ${LE_WILDCARD}"
req GET "/ping" >/dev/null || die "controller not reachable at ${CONTROLLER_URL}"

# ── 1. ACME config (only when DNS credentials are supplied) ─────────────────
if [[ -n "${ACME_DNS_CONFIG:-}" ]]; then
    info "Ensuring controller ACME config"
    ACME_EMAIL="${ACME_EMAIL:-}"
    ACME_CA_URL="${ACME_CA_URL:-https://acme-v02.api.letsencrypt.org/directory}"
    ACME_DNS_PROVIDER="${ACME_DNS_PROVIDER:-autodns}"
    ACME_EMAIL="$ACME_EMAIL" ACME_CA_URL="$ACME_CA_URL" \
    ACME_DNS_PROVIDER="$ACME_DNS_PROVIDER" ACME_DNS_CONFIG="$ACME_DNS_CONFIG" \
        python3 - <<'PY' >/tmp/acme-config.json
import json, os
print(json.dumps({
    "enabled": True,
    "email": os.environ["ACME_EMAIL"],
    "ca_url": os.environ["ACME_CA_URL"],
    "challenge_type": "dns-01",
    "dns_provider": os.environ["ACME_DNS_PROVIDER"],
    "dns_config": json.loads(os.environ["ACME_DNS_CONFIG"]),
}))
PY
    req PUT "/certs/letsencrypt/config" /tmp/acme-config.json >/dev/null
fi

# ── 2. Ensure the LE wildcard certificate exists ────────────────────────────
if ! req GET "/certs/letsencrypt/domains/%2A.${ROUTE_DOMAIN}" \
        >/tmp/acme-wildcard.json 2>/dev/null; then
    info "Provisioning LE wildcard ${LE_WILDCARD} (DNS-01)"
    echo "{\"domains\":[\"${LE_WILDCARD}\"]}" >/tmp/acme-provision.json
    req POST "/certs/letsencrypt" /tmp/acme-provision.json >/tmp/acme-wildcard.json
fi
[[ -s /tmp/acme-wildcard.json ]] || die "failed to obtain LE wildcard cert"
info "Wildcard cert present (expires: $(json 'import json,sys
print(json.load(open("/tmp/acme-wildcard.json")).get("expires_at", "?"))'))"

# ── 3. Ensure <app>.<ROUTE_DOMAIN> routes exist with the wildcard cert ──────
if [[ "${DASHBOARD_ENV_ONLY:-0}" != "1" ]]; then
    python3 - <<'PY' >/tmp/p22-route.json.tpl
import json
c = json.load(open("/tmp/acme-wildcard.json"))
tpl = {
    "type": "http",
    "service": "__SERVICE__",
    "domain": "__DOMAIN__",
    "path": "/",
    "acme_domain": (c.get("domains") or [None])[0],
    "certificate": {"cert": c["cert"], "key": c["key"]},
}
print(json.dumps(tpl))
PY
    APPS_JSON="$(req GET "/apps")"
    for app in "${APPS[@]}"; do
        appid="$(echo "$APPS_JSON" | python3 -c '
import json,sys
name=sys.argv[1]
for a in json.load(sys.stdin):
    if a["name"] == name:
        print(a["id"]); break
' "$app")"
        [[ -n "$appid" ]] || die "app '$app' not found"
        svc="controller"; [[ "$app" != "controller" ]] && svc="${app}-web"
        domain="${app}.${ROUTE_DOMAIN}"
        if req GET "/apps/${app}/routes" | python3 -c '
import json,sys
domain=sys.argv[1]
routes=json.load(sys.stdin)
sys.exit(0 if any(r.get("domain") == domain for r in routes) else 1)
' "$domain"; then
            info "route ${domain} already exists"
        else
            info "creating route ${domain} -> ${svc}"
            sed -e "s/__SERVICE__/${svc}/" -e "s/__DOMAIN__/${domain}/" \
                /tmp/p22-route.json.tpl >/tmp/p22-route.json
            req POST "/apps/${app}/routes" /tmp/p22-route.json >/dev/null
        fi
    done
fi

# ── 4. Align the dashboard release env with $ROUTE_DOMAIN ───────────────────
info "Ensuring dashboard release env uses ${ROUTE_DOMAIN}"
DASH_ID="$(req GET "/apps" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    if a["name"] == "dashboard":
        print(a["id"]); break
')"
CUR="$(req GET "/apps/dashboard/release")"
if echo "$CUR" | python3 -c '
import json,sys
r=json.load(sys.stdin)
route=sys.argv[1]
ok=(r.get("env",{}).get("DEFAULT_ROUTE_DOMAIN") == route
    and r.get("env",{}).get("CONTROLLER_DOMAIN") == "controller." + route)
sys.exit(0 if ok else 1)
' "$ROUTE_DOMAIN"; then
    info "dashboard release env already correct"
else
    echo "$CUR" >/tmp/dash-release-cur.json
    info "cloning dashboard release with ${ROUTE_DOMAIN} domains"
    python3 - "$ROUTE_DOMAIN" "$DASH_ID" <<'PY' >/tmp/dash-release-new.json
import json, sys
route, appid = sys.argv[1], sys.argv[2]
r = json.load(open("/tmp/dash-release-cur.json"))
for k in ("id", "created_at", "updated_at"):
    r.pop(k, None)
r["app_id"] = appid
r["env"]["DEFAULT_ROUTE_DOMAIN"] = route
r["env"]["CONTROLLER_DOMAIN"] = "controller." + route
print(json.dumps(r))
PY
    NEWREL="$(req POST "/releases" /tmp/dash-release-new.json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    info "deploying dashboard release ${NEWREL}"
    echo "{\"id\":\"${NEWREL}\"}" >/tmp/dash-deploy.json
    req POST "/apps/dashboard/deploy" /tmp/dash-deploy.json >/dev/null
    for _ in $(seq 1 24); do
        if req GET "/apps/dashboard" | python3 -c '
import json,sys
want=sys.argv[1]
sys.exit(0 if json.load(sys.stdin).get("release") == want else 1)
' "$NEWREL"; then
            break
        fi
        sleep 5
    done
    req GET "/apps/dashboard" | python3 -c '
import json,sys
print("dashboard release now", json.load(sys.stdin)["release"])
'
fi

# ── 5. Verification ─────────────────────────────────────────────────────────
info "Verification"
for app in "${APPS[@]}"; do
    code="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://${app}.${ROUTE_DOMAIN}/ping" || true)"
    echo "  https://${app}.${ROUTE_DOMAIN}/ping -> ${code}"
done
code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://controller.${ROUTE_DOMAIN}/ping" || true)"
echo "  http://controller.${ROUTE_DOMAIN}/ping -> ${code}"
cfg="$(curl -sk -m 10 "https://dashboard.${ROUTE_DOMAIN}/config" || echo '{}')"
echo "  dashboard /config default_route_domain: $(echo "$cfg" | python3 -c 'import json,sys
print(json.load(sys.stdin).get("default_route_domain", "?"))')"
info "Done."