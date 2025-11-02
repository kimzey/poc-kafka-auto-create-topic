#!/bin/bash

# install-argocd.sh
# Script to install Argo CD on kind cluster for Kafka Topics GitOps

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi

    # Check if cluster is kind
    if ! kubectl config current-context | grep -q "kind"; then
        print_warning "Current context is not a kind cluster. Some features may not work as expected."
    fi

    print_status "All prerequisites are satisfied!"
}

# Install Argo CD
install_argocd() {
    print_step "Installing Argo CD..."

    # Create namespace for Argo CD
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

    # Install Argo CD from official manifest
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.8.3/manifests/install.yaml

    if [ $? -eq 0 ]; then
        print_status "Argo CD installation started successfully!"
    else
        print_error "Failed to install Argo CD"
        exit 1
    fi
}

# Optional: create a permissive NetworkPolicy for argocd-server (helps with restrictive clusters)
create_network_policy() {
    print_step "Applying argocd-server NetworkPolicy (permissive) ..."
    cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-server-network-policy
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - ports:
    - protocol: TCP
      port: 8080
    - protocol: TCP
      port: 8083
  egress:
  - {}
EOF
}

# Wait for Argo CD to be ready
wait_for_argocd() {
    print_step "Waiting for Argo CD components to be ready..."

    # Wait for Argo CD server to be ready
    print_status "Waiting for argocd-server deployment..."
    kubectl wait --for=condition=Available \
        --timeout=600s \
        deployment/argocd-server \
        --namespace argocd

    # Wait for Argo CD application controller (StatefulSet in v2.8+)
    print_status "Waiting for argocd-application-controller (StatefulSet)..."
    # Fast-path: if already ready, don't block
    local desired ready
    desired=$(kubectl -n argocd get sts/argocd-application-controller -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    ready=$(kubectl -n argocd get sts/argocd-application-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ -n "$desired" ] && [ "${ready:-0}" = "$desired" ]; then
        echo "statefulset.apps/argocd-application-controller condition met"
    elif ! kubectl wait --for=condition=Ready --timeout=600s statefulset/argocd-application-controller -n argocd; then
        print_warning "kubectl wait on StatefulSet failed; falling back to rollout status and pod readiness"
        # Fallback 1: rollout status
        if ! kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=600s; then
            print_warning "rollout status did not report success; checking pod readiness by label"
        fi
        # Fallback 2: wait for at least 1 controller pod Ready
        kubectl wait -n argocd --for=condition=Ready pod \
            -l app.kubernetes.io/name=argocd-application-controller --timeout=600s || true
    fi

    # Wait for Argo CD repo server
    print_status "Waiting for argocd-repo-server..."
    kubectl wait --for=condition=Available \
        --timeout=300s \
        deployment/argocd-repo-server \
        --namespace argocd

    # Wait for Argo CD redis
    print_status "Waiting for argocd-redis..."
    kubectl wait --for=condition=Ready \
        --timeout=300s \
        pod \
        --selector=app.kubernetes.io/name=argocd-redis \
        --namespace argocd

    print_status "All Argo CD components are ready!"
}

# Configure Argo CD for external access
configure_access() {
    print_step "Configuring Argo CD external access..."

    # Expose argocd-server via NodePort for kind
    kubectl patch svc argocd-server -n argocd --type='merge' -p '{
      "spec": {
        "type": "NodePort",
        "ports": [
          {"name":"http","port":80,"targetPort":8080,"nodePort":30080},
          {"name":"https","port":443,"targetPort":8083,"nodePort":30443}
        ]
      }
    }'

    print_status "Argo CD server configured for external access on:"
    echo "  HTTP: http://localhost:30080"
    echo "  HTTPS: https://localhost:30443"
}

# Get initial admin password
get_admin_password() {
    print_step "Retrieving Argo CD admin password..."

    # Get the initial admin password
    ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

    print_status "Argo CD admin credentials:"
    echo "  Username: admin"
    echo "  Password: $ADMIN_PASSWORD"
    echo
    print_warning "Please save this password and change it after first login!"

    # Save password to file for convenience
    echo "$ADMIN_PASSWORD" > argocd-admin-password.txt
    chmod 600 argocd-admin-password.txt
    print_status "Password saved to argocd-admin-password.txt"
}

# Verify installation
verify_installation() {
    print_step "Verifying Argo CD installation..."

    # Check all Argo CD pods
    print_status "Checking Argo CD pods..."
    kubectl get pods -n argocd

    # Check services
    print_status "Checking Argo CD services..."
    kubectl get svc -n argocd

    # Check deployments and statefulsets
    print_status "Checking Argo CD deployments..."
    kubectl get deployments -n argocd
    print_status "Checking Argo CD statefulsets..."
    kubectl get statefulset -n argocd

    print_status "Argo CD installation verification completed!"
}

# Show next steps
show_next_steps() {
    print_status "Argo CD installation completed successfully!"
    echo
    echo "Next steps:"
    echo "1. Access Argo CD UI:"
    echo "   URL: http://localhost:30080"
    echo "   Username: admin"
    echo "   Password: $(cat argocd-admin-password.txt 2>/dev/null || echo '<see above>')"
    echo
    echo "2. Install Argo CD CLI (optional):"
    echo "   curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
    echo "   sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd"
    echo "   rm argocd-linux-amd64"
    echo
    echo "3. Login to Argo CD via CLI:"
    echo "   argocd login localhost:30080"
    echo
    echo "4. Create Kafka Topics application:"
    echo "   kubectl apply -f argocd/application.yaml"
    echo
    echo "5. Configure Git repository:"
    echo "   - Update repoURL in argocd/application.yaml to point to your Git repository"
    echo "   - Ensure your topics/ directory contains KafkaTopic YAML files"
    echo
    echo "6. Monitor synchronization:"
    echo "   kubectl get application kafka-topics -n argocd -w"
    echo
}

# Install argocd CLI function
install_argocd_cli() {
    print_step "Installing Argo CD CLI..."

    # Detect OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        arm64)
            ARCH="arm64"
            ;;
        *)
            print_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac

    # Download and install argocd CLI
    VERSION=$(curl --silent "https://api.github.com/repos/argoproj/argo-cd/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 2-)

    print_status "Downloading Argo CD CLI version ${VERSION} for ${OS}-${ARCH}..."

    curl -sSL -o "argocd-${OS}-${ARCH}" "https://github.com/argoproj/argo-cd/releases/download/v${VERSION}/argocd-${OS}-${ARCH}"

    if [ $? -eq 0 ]; then
        chmod +x "argocd-${OS}-${ARCH}"
        sudo mv "argocd-${OS}-${ARCH}" /usr/local/bin/argocd
        print_status "Argo CD CLI installed successfully!"
        argocd version --client
    else
        print_warning "Failed to install Argo CD CLI. You can install it manually."
    fi
}

# Main execution
main() {
    print_status "Starting Argo CD installation for Kafka Topics GitOps..."
    echo

    check_prerequisites
    install_argocd
    create_network_policy
    wait_for_argocd
    configure_access
    get_admin_password
    verify_installation

    # Optional: Install CLI
    read -p "Do you want to install Argo CD CLI? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_argocd_cli
    fi

    show_next_steps

    echo
    print_status "🎉 Argo CD is ready for Kafka Topics GitOps!"
}
# Run main function
main "$@"
