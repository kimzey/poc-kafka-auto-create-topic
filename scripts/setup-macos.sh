#!/bin/bash

# setup-macos.sh - One-click setup for macOS users
# Complete setup script for Declarative Kafka Topics POC

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="kafka-poc"

# Function to print colored output
print_header() {
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         Declarative Kafka Topics POC - macOS Setup          ║"
    echo "║                    Strimzi + Argo CD                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

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

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_logo() {
    echo -e "${CYAN}"
    cat << "EOF"
    _____ _____ _____ _____    _____ _     _       _   _
   |   __| __  |   __|  |  |  |   __|_|___| |_ ___|_|_| |_ ___ ___
   |__   |    -|   __|  |__|__|   __| |   |  _| .'| | |  _| -_|  _|
   |_____|__|__|_____|_____|  |_____|_|_|_|_| |__,|_|_|_| |___|_|

   GitOps-powered Kafka Topic Management
EOF
    echo -e "${NC}"
}

# Check macOS requirements
check_macos_requirements() {
    print_step "Checking macOS requirements..."

    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        print_error "This script is designed for macOS only"
        exit 1
    fi

    # Check macOS version
    MACOS_VERSION=$(sw_vers -productVersion)
    print_status "macOS version: $MACOS_VERSION"

    # Check if running on Intel or Apple Silicon
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
        print_status "Architecture: Apple Silicon (M1/M2/M3)"
        BREW_PREFIX="/opt/homebrew"
    else
        print_status "Architecture: Intel"
        BREW_PREFIX="/usr/local"
    fi

    # Check available memory
    MEMORY_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    if [[ $MEMORY_GB -lt 8 ]]; then
        print_warning "System has less than 8GB RAM ($MEMORY_GB GB). POC may run slowly."
    else
        print_status "Available RAM: $MEMORY_GB GB"
    fi

    # Check available disk space
    DISK_FREE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ ${DISK_FREE%.*} -lt 10 ]]; then
        print_warning "Low disk space (${DISK_FREE}GB free). Recommend at least 10GB."
    else
        print_status "Available disk space: ${DISK_FREE}GB"
    fi
}

# Install Homebrew if not present
install_homebrew() {
    print_step "Checking Homebrew installation..."

    if ! command -v brew &> /dev/null; then
        print_status "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add Homebrew to PATH
        if [[ "$ARCH" == "arm64" ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zshrc
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        print_success "Homebrew installed successfully"
    else
        print_status "Homebrew is already installed"
        brew update
    fi
}

# Install required tools
install_tools() {
    print_step "Installing required tools..."

    local tools=("kind" "kubectl" "helm" "git")

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            print_status "Installing $tool..."
            brew install "$tool"
        else
            print_status "$tool is already installed"
        fi
    done

    # Check Docker Desktop
    if ! docker info &> /dev/null; then
        print_error "Docker Desktop is not running. Please start Docker Desktop and try again."
        exit 1
    fi

    print_success "All required tools are installed and running"
}

# Verify Docker Desktop installation
verify_docker() {
    print_step "Verifying Docker Desktop..."

    if docker info &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        print_status "Docker is running: $DOCKER_VERSION"

        # Check available memory for Docker
        DOCKER_MEMORY=$(docker system df --format "{{.Size}}" | head -1 | sed 's/[^0-9.]//g' | cut -d'.' -f1)
        print_status "Docker memory allocation detected"
    else
        print_error "Docker Desktop is not running or not properly configured"
        print_status "Please ensure Docker Desktop is started and has at least 4GB memory allocated"
        exit 1
    fi
}

# Setup project structure
setup_project() {
    print_step "Setting up project structure..."

    cd "$PROJECT_DIR"

    # Make scripts executable
    chmod +x scripts/*.sh

    print_status "Scripts made executable"

    # Create necessary directories
    mkdir -p logs
    mkdir -p backups

    print_success "Project structure setup completed"
}

# Run kind setup
run_kind_setup() {
    print_step "Setting up kind cluster..."

    cd "$PROJECT_DIR"

    if ./scripts/setup-kind.sh 2>&1 | tee logs/setup-kind.log; then
        print_success "Kind cluster setup completed"
    else
        print_error "Kind cluster setup failed. Check logs/setup-kind.log"
        exit 1
    fi
}

# Run Strimzi installation
run_strimzi_setup() {
    print_step "Installing Strimzi Kafka Operator..."

    cd "$PROJECT_DIR"

    if ./scripts/install-strimzi.sh 2>&1 | tee logs/install-strimzi.log; then
        print_success "Strimzi installation completed"
    else
        print_error "Strimzi installation failed. Check logs/install-strimzi.log"
        exit 1
    fi
}

# Run Argo CD installation
run_argocd_setup() {
    print_step "Installing Argo CD..."

    cd "$PROJECT_DIR"

    if ./scripts/install-argocd.sh 2>&1 | tee logs/install-argocd.log; then
        print_success "Argo CD installation completed"
    else
        print_error "Argo CD installation failed. Check logs/install-argocd.log"
        exit 1
    fi
}

# Deploy Kafka cluster
deploy_kafka() {
    print_step "Deploying Kafka cluster..."

    cd "$PROJECT_DIR"

    # Apply Kafka cluster configuration
    kubectl apply -f kafka/kafka-cluster.yaml

    print_status "Waiting for Kafka cluster to be ready..."

    # Wait for Kafka to be ready
    if kubectl wait kafka/my-cluster --for=condition=Ready --timeout=600s -n strimzi; then
        print_success "Kafka cluster is ready"
    else
        print_error "Kafka cluster failed to become ready"
        exit 1
    fi

    # Wait for all pods to be ready
    kubectl wait --for=condition=Ready pod \
        --selector=strimzi.io/kind=Kafka \
        --timeout=300s \
        -n strimzi
}

# Setup Argo CD application
setup_argocd_app() {
    print_step "Setting up Argo CD application..."

    cd "$PROJECT_DIR"

    # Create a placeholder repository URL
    REPO_URL=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/your-org/poc-kafka-topics.git")

    # Update the Argo CD application with the current repository URL
    sed -i '' "s|https://github.com/your-org/poc-kafka-topics.git|$REPO_URL|" argocd/application.yaml

    # Apply Argo CD application
    kubectl apply -f argocd/application.yaml

    print_status "Argo CD application configured with repository: $REPO_URL"

    # Wait for Argo CD to sync
    sleep 10

    # Check sync status
    if kubectl get application kafka-topics -n argocd &> /dev/null; then
        SYNC_STATUS=$(kubectl get application kafka-topics -n argocd -o jsonpath='{.status.sync.status}')
        print_status "Argo CD sync status: $SYNC_STATUS"
    else
        print_warning "Argo CD application not found - manual configuration may be needed"
    fi
}

# Run comprehensive tests
run_tests() {
    print_step "Running comprehensive tests..."

    cd "$PROJECT_DIR"

    if ./scripts/test-topics.sh 2>&1 | tee logs/test-topics.log; then
        print_success "All tests passed successfully"
    else
        print_warning "Some tests failed. Check logs/test-topics.log for details"
    fi
}

# Display final information
show_final_info() {
    print_success "🎉 POC setup completed successfully!"
    echo
    echo -e "${PURPLE}Access Information:${NC}"
    echo "─────────────────────────────────────────────────────────────"
    echo
    echo -e "${CYAN}Argo CD UI:${NC}"
    echo "  URL:      http://localhost:30080"
    echo "  Username: admin"
    echo "  Password: $(cat argocd-admin-password.txt 2>/dev/null || echo 'See installation logs')"
    echo
    echo -e "${CYAN}Kafka Cluster:${NC}"
    echo "  Bootstrap Server: localhost:9092 (internal)"
    echo "  External Access:  localhost:30092"
    echo "  Namespace:       strimzi"
    echo
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  # Check Kafka status"
    echo "  kubectl get kafka my-cluster -n strimzi"
    echo
    echo "  # List topics"
    echo "  kubectl get kafkatopic -n strimzi"
    echo
    echo "  # Check Argo CD status"
    echo "  kubectl get application kafka-topics -n argocd"
    echo
    echo "  # Run tests again"
    echo "  ./scripts/test-topics.sh"
    echo
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Access Argo CD UI to verify topics"
    echo "  2. Try creating new topics in the topics/ directory"
    echo "  3. Push changes to Git repository"
    echo "  4. Monitor Argo CD synchronization"
    echo "  5. Test topic operations (produce/consume)"
    echo
    echo -e "${GREEN}Documentation:${NC} POC_Plan_Declarative_Kafka_Topics.md"
    echo
}

# Cleanup function
cleanup_on_error() {
    print_error "Setup failed. Cleaning up..."

    # Optional: Ask user if they want to keep the cluster
    echo
    read -p "Do you want to keep the kind cluster for debugging? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name $CLUSTER_NAME
        print_status "Kind cluster deleted"
    fi

    exit 1
}

# Main execution
main() {
    print_header
    print_logo
    echo

    # Trap errors for cleanup
    trap cleanup_on_error ERR

    check_macos_requirements
    install_homebrew
    install_tools
    verify_docker
    setup_project
    run_kind_setup
    run_strimzi_setup
    run_argocd_setup
    deploy_kafka
    setup_argocd_app
    run_tests
    show_final_info
}

# Check if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
