#!/bin/bash

# validate-yaml.sh - Validate YAML syntax for all configuration files
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_header() {
    echo -e "${BLUE}[VALIDATE]${NC} $1"
}

# Check if yq is installed
check_yq() {
    if ! command -v yq &> /dev/null; then
        print_error "yq is not installed. Please install it first:"
        echo "  brew install yq"
        echo "  or visit: https://github.com/mikefarah/yq"
        exit 1
    fi
}

# Validate single YAML file
validate_file() {
    local file="$1"
    print_header "Validating: $file"

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    # Check if file is empty
    if [[ ! -s "$file" ]]; then
        print_error "File is empty: $file"
        return 1
    fi

    # Validate YAML syntax using yq
    if yq eval '.' "$file" > /dev/null 2>&1; then
        print_status "✅ YAML syntax is valid"

        # Extract key information
        local api_version=$(yq eval '.apiVersion' "$file" 2>/dev/null || echo "N/A")
        local kind=$(yq eval '.kind' "$file" 2>/dev/null || echo "N/A")
        local name=$(yq eval '.metadata.name' "$file" 2>/dev/null || echo "N/A")
        local namespace=$(yq eval '.metadata.namespace' "$file" 2>/dev/null || echo "N/A")

        echo "  API Version: $api_version"
        echo "  Kind: $kind"
        echo "  Name: $name"
        echo "  Namespace: $namespace"

        # Specific validations for different types
        case "$kind" in
            "Kafka")
                validate_kafka "$file"
                ;;
            "KafkaTopic")
                validate_kafka_topic "$file"
                ;;
            "Application")
                validate_argocd_app "$file"
                ;;
        esac

        return 0
    else
        print_error "❌ YAML syntax error in $file"
        echo "Error details:"
        yq eval '.' "$file" 2>&1 | head -10
        return 1
    fi
}

# Validate Kafka cluster configuration
validate_kafka() {
    local file="$1"
    print_status "Validating Kafka cluster configuration..."

    # Check required fields
    local kafka_version=$(yq eval '.spec.kafka.version' "$file" 2>/dev/null)
    local replicas=$(yq eval '.spec.kafka.replicas' "$file" 2>/dev/null)

    if [[ -z "$kafka_version" ]]; then
        print_warning "Kafka version not specified"
    fi

    if [[ -z "$replicas" ]]; then
        print_warning "Kafka replicas not specified"
    elif [[ "$replicas" -lt 3 ]]; then
        print_warning "Kafka replicas < 3 (recommended minimum for production)"
    fi

    # Check storage configuration
    local storage_type=$(yq eval '.spec.kafka.storage.type' "$file" 2>/dev/null)
    if [[ "$storage_type" == "jbod" ]]; then
        local volumes=$(yq eval '.spec.kafka.storage.volumes | length' "$file" 2>/dev/null)
        if [[ "$volumes" -eq 0 ]]; then
            print_error "No storage volumes defined for JBOD"
        fi
    fi
}

# Validate KafkaTopic configuration
validate_kafka_topic() {
    local file="$1"
    print_status "Validating KafkaTopic configuration..."

    # Check required fields
    local partitions=$(yq eval '.spec.partitions' "$file" 2>/dev/null)
    local replicas=$(yq eval '.spec.replicas' "$file" 2>/dev/null)
    local cluster_label=$(yq eval '.metadata.labels."strimzi.io/cluster"' "$file" 2>/dev/null)

    if [[ -z "$partitions" ]]; then
        print_error "Partitions not specified"
    elif [[ "$partitions" -lt 1 ]]; then
        print_error "Partitions must be >= 1"
    fi

    if [[ -z "$replicas" ]]; then
        print_error "Replicas not specified"
    elif [[ "$replicas" -lt 1 ]]; then
        print_error "Replicas must be >= 1"
    elif [[ "$replicas" -gt 3 ]]; then
        print_warning "Replicas > 3 (exceeds typical cluster size)"
    fi

    if [[ -z "$cluster_label" ]]; then
        print_error "Strimzi cluster label is required"
    fi

    # Check configuration
    local retention_ms=$(yq eval '.spec.config."retention.ms"' "$file" 2>/dev/null)
    if [[ -n "$retention_ms" && "$retention_ms" -lt 0 ]]; then
        print_warning "Negative retention.ms (unlimited retention)"
    fi
}

# Validate Argo CD Application
validate_argocd_app() {
    local file="$1"
    print_status "Validating Argo CD Application..."

    # Check required fields
    local repo_url=$(yq eval '.spec.source.repoURL' "$file" 2>/dev/null)
    local path=$(yq eval '.spec.source.path' "$file" 2>/dev/null)
    local destination_server=$(yq eval '.spec.destination.server' "$file" 2>/dev/null)

    if [[ -z "$repo_url" ]]; then
        print_error "Repository URL not specified"
    elif [[ ! "$repo_url" =~ ^https?:// ]]; then
        print_warning "Repository URL should use HTTPS"
    fi

    if [[ -z "$path" ]]; then
        print_warning "Source path not specified (using root)"
    fi

    if [[ -z "$destination_server" ]]; then
        print_error "Destination server not specified"
    fi

    # Check sync policy
    local automated=$(yq eval '.spec.syncPolicy.automated' "$file" 2>/dev/null)
    if [[ -n "$automated" ]]; then
        local prune=$(yq eval '.spec.syncPolicy.automated.prune' "$file" 2>/dev/null)
        local self_heal=$(yq eval '.spec.syncPolicy.automated.selfHeal' "$file" 2>/dev/null)

        if [[ "$prune" == "true" ]]; then
            print_status "Prune enabled - resources will be deleted when removed from Git"
        fi

        if [[ "$self_heal" == "true" ]]; then
            print_status "Self-heal enabled - manual changes will be reverted"
        fi
    fi
}

# Find and validate all YAML files
validate_all_yaml() {
    local total_files=0
    local valid_files=0
    local invalid_files=0

    print_header "Starting comprehensive YAML validation..."
    echo

    # Find all YAML files
    local yaml_files=(
        "$PROJECT_DIR/kafka/*.yaml"
        "$PROJECT_DIR/topics/*.yaml"
        "$PROJECT_DIR/argocd/*.yaml"
        "$PROJECT_DIR/scripts/kind-config.yaml"
    )

    for pattern in "${yaml_files[@]}"; do
        for file in $pattern; do
            if [[ -f "$file" ]]; then
                total_files=$((total_files + 1))
                echo
                echo "─────────────────────────────────────────────────────────────"

                if validate_file "$file"; then
                    valid_files=$((valid_files + 1))
                else
                    invalid_files=$((invalid_files + 1))
                fi
            fi
        done
    done

    echo
    echo "─────────────────────────────────────────────────────────────"
    print_header "Validation Summary:"
    echo "  Total files: $total_files"
    echo -e "  Valid files: ${GREEN}$valid_files${NC}"
    if [[ $invalid_files -gt 0 ]]; then
        echo -e "  Invalid files: ${RED}$invalid_files${NC}"
    fi
    echo

    if [[ $invalid_files -eq 0 ]]; then
        echo -e "${GREEN}🎉 All YAML files are valid!${NC}"
        return 0
    else
        echo -e "${RED}❌ Some YAML files have errors. Please fix them before proceeding.${NC}"
        return 1
    fi
}

# Main execution
main() {
    print_header "YAML Validation for Declarative Kafka Topics POC"
    echo

    check_yq

    if [[ $# -eq 0 ]]; then
        validate_all_yaml
    else
        # Validate specific file
        for file in "$@"; do
            validate_file "$file"
            echo
        done
    fi
}

# Show usage
usage() {
    echo "Usage: $0 [file1.yaml] [file2.yaml] ..."
    echo "If no files are specified, all YAML files in the project will be validated."
    echo
    echo "Examples:"
    echo "  $0                                    # Validate all files"
    echo "  $0 topics/orders-events.yaml        # Validate specific file"
    echo "  $0 kafka/*.yaml topics/*.yaml       # Validate multiple files"
}

# Handle help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

# Run main function
main "$@"
