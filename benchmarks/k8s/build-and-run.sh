#!/usr/bin/env bash
#
# Build and push the Polaris load test Docker image, then run as a K8s Job.
#
# Usage:
#   ./build-and-run.sh build          - Build the Docker image
#   ./build-and-run.sh push           - Push to ACR
#   ./build-and-run.sh run [sim]      - Deploy the K8s Job (default: ReadUpdateTreeDataset)
#   ./build-and-run.sh logs           - Tail logs from the running job
#   ./build-and-run.sh clean          - Delete the job
#   ./build-and-run.sh all [sim]      - Build, push, and run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-uchimera.azurecr.io}"
IMAGE_NAME="${IMAGE_NAME:-cccs/ap/polaris-loadtest}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
NAMESPACE="${NAMESPACE:-polaris}"
JOB_NAME="polaris-loadtest"

cd "$SCRIPT_DIR/.."

build() {
    echo "Building image: ${FULL_IMAGE}"
    docker build -t "${FULL_IMAGE}" .
}

push() {
    echo "Pushing image: ${FULL_IMAGE}"
    # Login to ACR if needed
    az acr login --name "${REGISTRY%%.*}" 2>/dev/null || true
    docker push "${FULL_IMAGE}"
}

run() {
    local simulation="${1:-ReadUpdateTreeDataset}"
    echo "Deploying load test job (simulation: ${simulation})..."
    
    # Delete existing job if present
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    
    # Apply with simulation override
    kubectl apply -f "$SCRIPT_DIR/loadtest-job.yaml"
    
    # Patch simulation if not default
    if [[ "$simulation" != "ReadUpdateTreeDataset" ]]; then
        kubectl patch job "${JOB_NAME}" -n "${NAMESPACE}" --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/0/value\",\"value\":\"${simulation}\"}]"
    fi
    
    echo ""
    echo "Job deployed. Monitor with:"
    echo "  kubectl logs -f job/${JOB_NAME} -n ${NAMESPACE}"
    echo "  kubectl get hpa polaris -n ${NAMESPACE} -w"
}

logs() {
    kubectl logs -f "job/${JOB_NAME}" -n "${NAMESPACE}"
}

results() {
    echo "Fetching results from PVC..."
    kubectl run loadtest-results --rm -it --restart=Never \
        -n "${NAMESPACE}" \
        --image=busybox \
        --overrides='{
          "spec": {
            "containers": [{
              "name": "results",
              "image": "busybox",
              "command": ["sh", "-c", "ls -la /results/ && echo --- && find /results -name index.html"],
              "volumeMounts": [{"name": "results", "mountPath": "/results"}]
            }],
            "volumes": [{"name": "results", "persistentVolumeClaim": {"claimName": "polaris-loadtest-results"}}]
          }
        }'
}

copy-results() {
    local dest="${1:-.}"
    echo "Copying results locally to ${dest}/loadtest-results/..."
    kubectl run loadtest-copy --rm -it --restart=Never \
        -n "${NAMESPACE}" \
        --image=busybox \
        --overrides='{
          "spec": {
            "containers": [{
              "name": "copy",
              "image": "busybox",
              "command": ["sh", "-c", "tar czf /tmp/results.tar.gz -C /results . && cat /tmp/results.tar.gz"],
              "volumeMounts": [{"name": "results", "mountPath": "/results"}]
            }],
            "volumes": [{"name": "results", "persistentVolumeClaim": {"claimName": "polaris-loadtest-results"}}]
          }
        }' > results.tar.gz
    mkdir -p "${dest}/loadtest-results"
    tar xzf results.tar.gz -C "${dest}/loadtest-results"
    rm results.tar.gz
    echo "Done. Reports in ${dest}/loadtest-results/"
}

clean() {
    echo "Deleting job..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    kubectl delete configmap polaris-loadtest-config -n "${NAMESPACE}" --ignore-not-found=true
}

case "${1:-all}" in
    build) build ;;
    push) push ;;
    run) run "${2:-ReadUpdateTreeDataset}" ;;
    logs) logs ;;
    results) results ;;
    copy-results) copy-results "${2:-.}" ;;
    clean) clean ;;
    all)
        build
        push
        run "${2:-ReadUpdateTreeDataset}"
        ;;
    *)
        echo "Usage: $0 {build|push|run|logs|results|copy-results|clean|all} [simulation|dest]"
        exit 1
        ;;
esac
