#!/bin/bash

# install-strimzi.sh
# Script to install Strimzi Kafka Operator on kind cluster (robust)

set -e

# Configuration
STRIMZI_CHART_VERSION=${STRIMZI_CHART_VERSION:-0.48.0}
KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-kafka-poc}
NAMESPACE=strimzi
RELEASE_NAME=strimzi-kafka-operator

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        print_error "helm is not installed. Please install it first: brew install helm"
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        print_error "docker is not installed or not in PATH"
        exit 1
    fi

    if ! command -v kind &> /dev/null; then
        print_error "kind is not installed. Please install it first: brew install kind"
        exit 1
    fi

    print_status "All prerequisites are satisfied!"
}

get_operator_deploy_name() {
    # Prefer app.kubernetes.io labels from Helm release
    kubectl -n "$NAMESPACE" get deploy \
      -l app.kubernetes.io/instance="$RELEASE_NAME",app.kubernetes.io/component=cluster-operator \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

get_operator_image() {
    local deploy="$1"
    kubectl -n "$NAMESPACE" get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

prefetch_and_load_image() {
    local image="$1"
    if [ -z "$image" ]; then
        print_warning "Operator image not detected; skip prefetch"
        return 0
    fi
    print_status "Prefetching operator image: $image"
    if ! docker pull "$image"; then
        print_warning "docker pull failed for $image (continuing)"
    fi
    if ! kind load docker-image "$image" --name "$KIND_CLUSTER_NAME"; then
        print_warning "kind load docker-image failed; attempting node-local pull via containerd"

        # Fallback: pull directly into the kind node's containerd with the right platform
        local node="${KIND_CLUSTER_NAME}-control-plane"

        # Determine node architecture -> platform
        local arch platform
        arch=$(docker exec --privileged "$node" uname -m 2>/dev/null || echo "")
        case "$arch" in
          x86_64|amd64)
            platform="linux/amd64";;
          aarch64|arm64)
            platform="linux/arm64";;
          *)
            platform="";;
        esac

        # Build ctr pull command
        local ctr_cmd=("docker" "exec" "--privileged" "$node" "ctr" "--namespace=k8s.io" "images" "pull")
        if [ -n "$platform" ]; then
            ctr_cmd+=("--platform" "$platform")
        fi
        ctr_cmd+=("$image")

        if "${ctr_cmd[@]}"; then
            print_status "Pulled operator image into node containerd (${platform:-auto})"
        else
            print_warning "Containerd pull fallback failed; relying on K8s to pull image at runtime"
        fi
    fi
}

# Install or upgrade Strimzi Operator
install_strimzi_operator() {
    print_status "Installing Strimzi Operator (chart $STRIMZI_CHART_VERSION)..."

    # Create namespace
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Add repo and update
    helm repo add strimzi https://strimzi.io/charts/ 2>/dev/null || true
    helm repo update

    # Install/upgrade via Helm, watch all namespaces
    helm upgrade --install "$RELEASE_NAME" strimzi/strimzi-kafka-operator \
        --namespace "$NAMESPACE" \
        --version "$STRIMZI_CHART_VERSION" \
        --set watchAnyNamespace=true \
        --timeout=10m

    print_status "Helm release applied"
}

# Wait for operator to be ready (robust to naming/labels)
wait_for_operator() {
    print_status "Waiting for Strimzi Operator to be ready..."

    # Discover deployment name
    local deploy
    deploy=$(get_operator_deploy_name)
    if [ -z "$deploy" ]; then
        # Fallback common name
        deploy=strimzi-cluster-operator
        print_warning "Could not detect deployment via labels; assuming '$deploy'"
    else
        print_status "Detected operator deployment: $deploy"
    fi

    # Try to prefetch and load image into kind to avoid ImagePullBackOff
    local image
    image=$(get_operator_image "$deploy")
    if [ -n "$image" ]; then
        prefetch_and_load_image "$image"
        # Restart to ensure node has the image
        kubectl -n "$NAMESPACE" rollout restart deploy/"$deploy" || true
    else
        print_warning "Unable to resolve operator image for prefetch"
    fi

    # Wait for deployment Available
    kubectl -n "$NAMESPACE" wait --for=condition=Available --timeout=600s deployment/"$deploy" || {
        print_warning "Deployment wait failed for $deploy; will wait on pods by label"
    }

    # Wait for pods ready by robust label selectors
    if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready --timeout=600s pod -l strimzi.io/kind=cluster-operator; then
        kubectl -n "$NAMESPACE" wait --for=condition=Ready --timeout=600s pod -l app.kubernetes.io/component=cluster-operator || true
    fi

    print_status "Strimzi Operator is ready (or appears ready)."
}

# Verify installation
verify_installation() {
    print_status "Verifying Strimzi installation..."

    print_status "Checking CRDs..."
    if ! kubectl get crd | grep -q 'kafkas.kafka.strimzi.io'; then
        print_error "Strimzi Kafka CRD not found"
        exit 1
    fi

    print_status "Checking operator pods..."
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=cluster-operator || true
    kubectl get pods -n "$NAMESPACE" -l strimzi.io/kind=cluster-operator || true

    print_status "Checking operator deployment..."
    kubectl -n "$NAMESPACE" get deploy | grep -E 'strimzi-.*operator' || true

    print_status "Strimzi installation verification completed!"
}

# Show next steps
show_next_steps() {
    print_status "Strimzi Operator installation completed!"
    echo
    echo "Next steps:"
    echo "1. Deploy Kafka cluster:"
    echo "   kubectl apply -f kafka/kafka-cluster-kind.yaml"
    echo
    echo "2. Wait for Kafka to be ready:"
    echo "   kubectl wait kafka/my-cluster --for=condition=Ready --timeout=600s -n strimzi"
    echo
    echo "3. Check Kafka status:"
    echo "   kubectl get kafka -n strimzi"
    echo "   kubectl get pods -n strimzi -l strimzi.io/kind=kafka"
    echo
    echo "4. If image pulls fail again, re-run this script to prefetch and kind-load the operator image."
    echo
}

# Main execution
main() {
    print_status "Starting Strimzi Operator installation..."
    echo

    check_prerequisites
    install_strimzi_operator
    wait_for_operator
    verify_installation
    show_next_steps

    echo
    print_status "🎉 Strimzi Operator is ready!"
}

# Run main function
main "$@"
