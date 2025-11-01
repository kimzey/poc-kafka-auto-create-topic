#!/bin/bash

# install-strimzi.sh
# Script to install Strimzi Kafka Operator on kind cluster

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

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi

    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        print_error "helm is not installed. Please install it first: brew install helm"
        exit 1
    fi

    print_status "All prerequisites are satisfied!"
}

# Install Strimzi Operator
install_strimzi_operator() {
    print_status "Installing Strimzi Operator..."

    # Create namespace for Strimzi
    kubectl create namespace strimzi --dry-run=client -o yaml | kubectl apply -f -

    # Add Strimzi Helm repository
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update

    # Install Strimzi Operator using Helm
    helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
        --namespace strimzi \
        --set watchAnyNamespace=true \
        --set image.registry=quay.io \
        --set image.repository=strimzi/operator \
        --set image.tag=0.35.1 \
        --timeout=10m

    if [ $? -eq 0 ]; then
        print_status "Strimzi Operator installed successfully!"
    else
        print_error "Failed to install Strimzi Operator"
        exit 1
    fi
}

# Wait for operator to be ready
wait_for_operator() {
    print_status "Waiting for Strimzi Operator to be ready..."

    # Wait for the operator deployment to be ready
    kubectl wait --for=condition=Available \
        --timeout=300s \
        deployment/strimzi-kafka-operator \
        --namespace strimzi

    # Wait for the operator pods to be running
    kubectl wait --for=condition=Ready \
        --timeout=300s \
        pod \
        --selector=strimzi.io/kind=operator \
        --namespace strimzi

    print_status "Strimzi Operator is ready!"
}

# Verify installation
verify_installation() {
    print_status "Verifying Strimzi installation..."

    # Check custom resource definitions
    print_status "Checking CRDs..."
    kubectl get crd | grep strimzi || {
        print_error "Strimzi CRDs not found"
        exit 1
    }

    # Check operator pods
    print_status "Checking operator pods..."
    kubectl get pods -n strimzi -l strimzi.io/kind=operator

    # Check operator deployment
    print_status "Checking operator deployment..."
    kubectl get deployment strimzi-kafka-operator -n strimzi

    print_status "Strimzi installation verification completed!"
}

# Show next steps
show_next_steps() {
    print_status "Strimzi Operator installation completed!"
    echo
    echo "Next steps:"
    echo "1. Deploy Kafka cluster:"
    echo "   kubectl apply -f kafka/kafka-cluster.yaml"
    echo
    echo "2. Wait for Kafka to be ready:"
    echo "   kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n strimzi"
    echo
    echo "3. Check Kafka status:"
    echo "   kubectl get kafka -n strimzi"
    echo "   kubectl get pods -n strimzi -l strimzi.io/kind=kafka"
    echo
    echo "4. Test topic creation:"
    echo "   kubectl apply -f topics/orders-events.yaml"
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
