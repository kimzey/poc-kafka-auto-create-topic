#!/bin/bash

# setup-kind.sh
# Script to create and configure kind cluster for Kafka POC

set -e

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

    # Check if kind is installed
    if ! command -v kind &> /dev/null; then
        print_error "kind is not installed. Please install it first: brew install kind"
        exit 1
    fi

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install it first: brew install kubectl"
        exit 1
    fi

    # Check if Docker is running
    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker Desktop"
        exit 1
    fi

    print_status "All prerequisites are satisfied!"
}

# Create kind cluster
create_cluster() {
    print_status "Creating kind cluster..."

    # Delete existing cluster if it exists
    if kind get clusters | grep -q "kafka-poc"; then
        print_warning "Cluster 'kafka-poc' already exists. Deleting it..."
        kind delete cluster --name kafka-poc
    fi

    # Create new cluster
    kind create cluster --name kafka-poc --config scripts/kind-config.yaml

    if [ $? -eq 0 ]; then
        print_status "Kind cluster 'kafka-poc' created successfully!"
    else
        print_error "Failed to create kind cluster"
        exit 1
    fi
}

# Configure cluster
configure_cluster() {
    print_status "Configuring cluster..."

    # Wait for cluster to be ready
    kubectl wait --for=condition=Ready nodes --all --timeout=300s

    # Install ingress-nginx (needed for Argo CD UI)
    print_status "Installing ingress-nginx..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    # Wait for ingress-nginx to be ready
    print_status "Waiting for ingress-nginx to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s

    print_status "Cluster configuration completed!"
}

# Verify cluster
verify_cluster() {
    print_status "Verifying cluster..."

    # Show cluster info
    kubectl cluster-info --context kind-kafka-poc

    # Show nodes
    print_status "Cluster nodes:"
    kubectl get nodes -o wide

    # Show port mappings
    print_status "Port mappings:"
    docker port kafka-poc-control-plane

    print_status "Cluster verification completed!"
}

# Show next steps
show_next_steps() {
    print_status "Setup completed successfully!"
    echo
    echo "Next steps:"
    echo "1. Install Strimzi Operator:"
    echo "   ./scripts/install-strimzi.sh"
    echo
    echo "2. Install Argo CD:"
    echo "   ./scripts/install-argocd.sh"
    echo
    echo "3. Access cluster:"
    echo "   kubectl config use-context kind-kafka-poc"
    echo
    echo "4. Check cluster status:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods --all-namespaces"
    echo
}

# Main execution
main() {
    print_status "Starting Kafka POC cluster setup..."
    echo

    check_prerequisites
    create_cluster
    configure_cluster
    verify_cluster
    show_next_steps

    echo
    print_status "🎉 Kind cluster setup is ready!"
}

# Run main function
main "$@"
