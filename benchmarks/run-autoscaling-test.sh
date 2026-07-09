#!/usr/bin/env bash
#
# Autoscaling load test for Polaris u-dev
#
# This script runs Gatling benchmarks against the u-dev Polaris deployment
# to trigger HPA autoscaling (1 -> 3 replicas at 80% CPU/memory).
#
# Prerequisites:
#   1. Java 17+ installed (for Gradle/Gatling)
#   2. kubectl configured with access to the u-dev cluster
#   3. Network access to polaris.aurora-dev.u.azure.chimera.cyber.gc.ca
#
# Usage:
#   ./run-autoscaling-test.sh [phase]
#
# Phases:
#   setup     - Fetch credentials and create the test dataset
#   load      - Run the sustained load test (read-update simulation)
#   monitor   - Watch HPA status during the test
#   teardown  - Delete all benchmark catalogs/namespaces/tables/views
#   cleanup   - (optional) Report results
#   all       - Run setup + load (default)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/u-dev-autoscaling-test.conf"
NAMESPACE="polaris"
HPA_NAME="polaris"
BASE_URL="https://polaris.aurora-dev.u.azure.chimera.cyber.gc.ca"
CATALOG_PREFIX="C_"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

get_token() {
    curl -sf -X POST "${BASE_URL}/api/catalog/v1/oauth/tokens" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=${POLARIS_CLIENT_ID}&client_secret=${POLARIS_CLIENT_SECRET}&scope=PRINCIPAL_ROLE:ALL" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

api_call() {
    local method="$1" path="$2"
    curl -sf -X "$method" "${BASE_URL}${path}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json"
}

# Parallelism for teardown deletions
TEARDOWN_PARALLELISM="${TEARDOWN_PARALLELISM:-20}"

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v java &>/dev/null; then
        log_error "Java is not installed or not in PATH. Java 17+ is required."
        exit 1
    fi

    local java_version
    java_version=$(java -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1)
    if [[ "$java_version" -lt 17 ]]; then
        log_error "Java 17+ required, found Java $java_version"
        exit 1
    fi

    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found - HPA monitoring will not be available"
    fi

    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "Configuration file not found: $CONF_FILE"
        exit 1
    fi
}

fetch_credentials() {
    if [[ -n "${POLARIS_CLIENT_ID:-}" && -n "${POLARIS_CLIENT_SECRET:-}" ]]; then
        log_info "Using credentials from environment variables"
        return 0
    fi

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not available and POLARIS_CLIENT_ID/POLARIS_CLIENT_SECRET not set"
        log_error "Set credentials manually:"
        log_error "  export POLARIS_CLIENT_ID='<client-id>'"
        log_error "  export POLARIS_CLIENT_SECRET='<client-secret>'"
        exit 1
    fi

    log_info "Fetching credentials from K8s secret 'root-user' in namespace '$NAMESPACE'..."
    export POLARIS_CLIENT_ID
    export POLARIS_CLIENT_SECRET
    POLARIS_CLIENT_ID=$(kubectl get secret root-user -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
    POLARIS_CLIENT_SECRET=$(kubectl get secret root-user -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

    if [[ -z "$POLARIS_CLIENT_ID" || -z "$POLARIS_CLIENT_SECRET" ]]; then
        log_error "Failed to fetch credentials from K8s secret"
        exit 1
    fi
    log_info "Credentials fetched successfully"
}

run_setup() {
    log_info "=== Phase: SETUP ==="
    log_info "Creating test dataset on u-dev..."
    log_info "This populates catalogs, namespaces, tables, and views."
    log_info "Dataset: 40 namespaces, 270 tables, 135 views"

    cd "$SCRIPT_DIR"
    ./gradlew gatlingRun \
        --simulation org.apache.polaris.benchmarks.simulations.CreateTreeDataset \
        -Dconfig.file="$CONF_FILE"

    log_info "Dataset creation complete"
}

run_load() {
    log_info "=== Phase: LOAD ==="
    log_info "Running sustained read/update workload (15 min, 200 ops/sec)..."
    log_info "Target: drive CPU above 80% to trigger HPA scale-up (1 -> 3 replicas)"
    log_info ""
    log_info "Monitor scaling in another terminal:"
    log_info "  kubectl get hpa $HPA_NAME -n $NAMESPACE -w"
    log_info "  kubectl get pods -n $NAMESPACE -w"
    log_info ""

    cd "$SCRIPT_DIR"
    ./gradlew gatlingRun \
        --simulation org.apache.polaris.benchmarks.simulations.ReadUpdateTreeDataset \
        -Dconfig.file="$CONF_FILE"

    log_info "Load test complete"
}

run_monitor() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not available for monitoring"
        exit 1
    fi

    log_info "=== Phase: MONITOR ==="
    log_info "Watching HPA status (Ctrl+C to stop)..."
    log_info ""

    echo "--- HPA Status ---"
    kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" 2>/dev/null || \
        kubectl get hpa -n "$NAMESPACE"
    echo ""
    echo "--- Pods ---"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=polaris
    echo ""
    echo "--- Watching HPA (live) ---"
    kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" -w 2>/dev/null || \
        kubectl get hpa -n "$NAMESPACE" -w
}

run_teardown() {
    log_info "=== Phase: TEARDOWN ==="
    log_info "Deleting benchmark catalogs and all their contents..."

    TOKEN=$(get_token)

    # Find all benchmark catalogs (C_0, C_1, etc.)
    local catalogs
    catalogs=$(api_call GET "/api/management/v1/catalogs" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('catalogs', []):
    name = c.get('name', '')
    if name.startswith('${CATALOG_PREFIX}'):
        print(name)
" 2>/dev/null || true)

    if [[ -z "$catalogs" ]]; then
        log_info "No benchmark catalogs found to delete"
        return 0
    fi

    for catalog in $catalogs; do
        log_info "Deleting catalog: $catalog"
        delete_catalog_contents "$catalog"
        log_info "  Deleting catalog entity..."
        api_call DELETE "/api/management/v1/catalogs/${catalog}" >/dev/null 2>&1 || \
            log_warn "  Failed to delete catalog $catalog (may require purge)"
    done

    log_info "Teardown complete"
}

delete_catalog_contents() {
    local catalog="$1"
    local prefix="/api/catalog/v1/${catalog}"

    # Get all namespaces (flat list via recursive listing isn't available,
    # so we do BFS through the namespace tree)
    local all_namespaces=()
    collect_namespaces "$prefix" "" all_namespaces

    log_info "  Found ${#all_namespaces[@]} namespaces to delete"
    log_info "  Deleting all tables and views (${TEARDOWN_PARALLELISM} parallel workers)..."

    # Use python for concurrent deletion - much faster than bash loops
    python3 - "${BASE_URL}" "${prefix}" "${TOKEN}" "${TEARDOWN_PARALLELISM}" "${all_namespaces[@]}" <<'PYTHON'
import sys
import json
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed

base_url = sys.argv[1]
prefix = sys.argv[2]
token = sys.argv[3]
parallelism = int(sys.argv[4])
namespaces = sys.argv[5:]

headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api_get(path):
    req = urllib.request.Request(f"{base_url}{path}", headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except Exception:
        return {}

def api_delete(path):
    req = urllib.request.Request(f"{base_url}{path}", headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except Exception:
        pass

def delete_entity(args):
    ns_url, endpoint, name = args
    api_delete(f"{prefix}/namespaces/{ns_url}/{endpoint}/{name}?purgeRequested=true")

# Collect all delete tasks
tasks = []
for ns in namespaces:
    ns_url = ns.replace(".", "%1F")
    for endpoint in ("views", "tables"):
        data = api_get(f"{prefix}/namespaces/{ns_url}/{endpoint}")
        for ident in data.get("identifiers", []):
            name = ident.get("name", "")
            if name:
                tasks.append((ns_url, endpoint, name))

print(f"  Deleting {len(tasks)} entities...", flush=True)

# Delete all tables/views in parallel
with ThreadPoolExecutor(max_workers=parallelism) as executor:
    futures = [executor.submit(delete_entity, t) for t in tasks]
    for f in as_completed(futures):
        pass  # Ignore individual errors

print(f"  Entities deleted.", flush=True)
PYTHON

    # Delete namespaces leaf-first (must be ordered, but can batch parallel since
    # we already removed contents)
    log_info "  Deleting namespaces (leaf-first)..."
    for (( i=${#all_namespaces[@]}-1; i>=0; i-- )); do
        local ns="${all_namespaces[$i]}"
        local ns_url="${ns//\./%1F}"
        api_call DELETE "${prefix}/namespaces/${ns_url}" >/dev/null 2>&1 || true
    done
}

collect_namespaces() {
    local prefix="$1"
    local parent="$2"
    local -n result_arr="$3"

    local parent_url=""
    if [[ -n "$parent" ]]; then
        parent_url="${parent//\./%1F}"
    fi

    local endpoint="${prefix}/namespaces"
    if [[ -n "$parent_url" ]]; then
        endpoint="${endpoint}?parent=${parent_url}"
    fi

    local namespaces
    namespaces=$(api_call GET "$endpoint" 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ns in data.get('namespaces', []):
    # namespace is an array of path components
    print('.'.join(ns))
" 2>/dev/null || true)

    for ns in $namespaces; do
        [[ -z "$ns" ]] && continue
        result_arr+=("$ns")
        # Recurse into child namespaces
        collect_namespaces "$prefix" "$ns" "$3"
    done
}

run_cleanup() {
    log_info "=== Phase: CLEANUP ==="
    log_info "Listing generated reports..."

    cd "$SCRIPT_DIR"
    make reports-list 2>/dev/null || true

    log_info ""
    log_info "To view reports: open build/reports/gatling/<simulation>/index.html"
    log_info ""

    if command -v kubectl &>/dev/null; then
        log_info "Final HPA state:"
        kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" 2>/dev/null || \
            kubectl get hpa -n "$NAMESPACE" 2>/dev/null || true
    fi
}

main() {
    local phase="${1:-all}"

    check_prerequisites
    fetch_credentials

    case "$phase" in
        setup)
            run_setup
            ;;
        load)
            run_load
            ;;
        monitor)
            run_monitor
            ;;
        teardown)
            run_teardown
            ;;
        cleanup)
            run_cleanup
            ;;
        all)
            run_setup
            run_load
            run_teardown
            run_cleanup
            ;;
        *)
            log_error "Unknown phase: $phase"
            echo "Usage: $0 [setup|load|monitor|teardown|cleanup|all]"
            exit 1
            ;;
    esac
}

main "$@"
