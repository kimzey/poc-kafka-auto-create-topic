#!/bin/bash

# test-topics.sh
# Comprehensive testing script for Kafka Topics declarative management

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="strimzi"
CLUSTER_NAME="my-cluster"
TOPICS_DIR="topics"
BOOTSTRAP_SERVER="localhost:9092"

# Resolve Kafka broker pod name (works with NodePools)
get_kafka_broker_pod() {
    # Prefer deriving from StatefulSet to be robust with NodePools
    local sts
    sts=$(kubectl -n "$NAMESPACE" get sts -l strimzi.io/cluster="$CLUSTER_NAME" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)
    if [[ -n "$sts" ]]; then
        echo "${sts}-0"
        return 0
    fi

    # Fallback: list pods and pick the first broker/controller pod
    kubectl -n "$NAMESPACE" get pods \
      -l strimzi.io/cluster="$CLUSTER_NAME" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -Ev '(entity-operator|kafka-exporter|cruise-control|connect|bridge|mm2|zookeeper)' \
    | grep -E -- '-[0-9]+$' \
    | head -n1
}

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TEST_RESULTS=()

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

print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_RESULTS+=("PASS: $1")
}

print_failure() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_RESULTS+=("FAIL: $1")
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."

    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Check if Kafka cluster is ready
    if ! kubectl get kafka $CLUSTER_NAME -n $NAMESPACE &> /dev/null; then
        print_error "Kafka cluster '$CLUSTER_NAME' not found in namespace '$NAMESPACE'"
        exit 1
    fi

    KAFKA_STATUS=$(kubectl get kafka $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [[ "$KAFKA_STATUS" != "True" ]]; then
        print_error "Kafka cluster is not ready. Status: $KAFKA_STATUS"
        exit 1
    fi

    # Discover broker pod
    BROKER_POD=$(get_kafka_broker_pod)
    if [[ -z "$BROKER_POD" ]]; then
        print_error "Cannot find Kafka broker pod in namespace '$NAMESPACE'"
        kubectl -n "$NAMESPACE" get pods -l strimzi.io/cluster="$CLUSTER_NAME"
        exit 1
    fi

    print_status "Prerequisites check passed! Broker pod: $BROKER_POD"
}

# Test 1: Topic creation via YAML
test_topic_creation() {
    print_test "Testing topic creation via YAML..."

    # Create a test topic
    kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-topic-creation
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: "$CLUSTER_NAME"
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: 3600000
EOF

    # Wait for topic to be created
    sleep 5

    # Check if KafkaTopic resource exists
    if kubectl get kafkatopic test-topic-creation -n $NAMESPACE &> /dev/null; then
        # Check topic status
        TOPIC_STATUS=$(kubectl get kafkatopic test-topic-creation -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        if [[ "$TOPIC_STATUS" == "True" ]]; then
            print_success "Topic created successfully via YAML"
        else
            print_failure "Topic creation failed. Status: $TOPIC_STATUS"
            return 1
        fi
    else
        print_failure "KafkaTopic resource not found"
        return 1
    fi

    # Verify topic exists in Kafka
    if kubectl exec "$BROKER_POD" -n "$NAMESPACE" -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic test-topic-creation &> /dev/null; then
        print_success "Topic verified in Kafka cluster"
    else
        print_failure "Topic not found in Kafka cluster"
        return 1
    fi
}

# Test 2: Topic configuration update
test_topic_config_update() {
    print_test "Testing topic configuration update..."

    # Update topic partitions using merge patch (supported by Strimzi CRD)
    kubectl patch kafkatopic test-topic-creation -n $NAMESPACE \
        --type=merge \
        -p '{"spec":{"partitions":6}}'

    sleep 10

    # Check if partitions increased (parse PartitionCount from describe)
    PARTITIONS=$(kubectl exec "$BROKER_POD" -n "$NAMESPACE" -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic test-topic-creation \
        | sed -nE 's/.*PartitionCount: ([0-9]+).*/\1/p' | head -n1)

    if [[ "$PARTITIONS" == "6" ]]; then
        print_success "Topic partitions updated successfully (6 partitions)"
    else
        print_failure "Partition update failed. Expected: 6, Got: $PARTITIONS"
        return 1
    fi
}

# Test 3: Message production and consumption
test_message_flow() {
    print_test "Testing message production and consumption..."

    # Produce test message
    TEST_MESSAGE="test-message-$(date +%s)"

    echo "$TEST_MESSAGE" | kubectl exec -i "$BROKER_POD" -n "$NAMESPACE" -- /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic test-topic-creation &> /dev/null

    sleep 2

    # Consume message
    CONSUMED_MESSAGE=$(kubectl exec "$BROKER_POD" -n "$NAMESPACE" -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test-topic-creation --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null | tr -d '\n')

    if [[ "$CONSUMED_MESSAGE" == "$TEST_MESSAGE" ]]; then
        print_success "Message production and consumption successful"
    else
        print_failure "Message flow failed. Sent: '$TEST_MESSAGE', Received: '$CONSUMED_MESSAGE'"
        return 1
    fi
}

# Test 4: Topic deletion
test_topic_deletion() {
    print_test "Testing topic deletion..."

    # Delete KafkaTopic resource
    kubectl delete kafkatopic test-topic-creation -n $NAMESPACE

    sleep 10

    # Check if topic is deleted from Kafka
    if ! kubectl exec "$BROKER_POD" -n "$NAMESPACE" -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic test-topic-creation &> /dev/null; then
        print_success "Topic deleted successfully"
    else
        print_failure "Topic still exists in Kafka cluster"
        return 1
    fi
}

# Test 5: Idempotent operations
test_idempotent_operations() {
    print_test "Testing idempotent operations..."

    # Apply same topic definition twice
    kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-idempotent
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: "$CLUSTER_NAME"
spec:
  partitions: 2
  replicas: 1
  config:
    retention.ms: 1800000
EOF

    sleep 5

    # Apply again (should not fail)
    if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-idempotent
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: "$CLUSTER_NAME"
spec:
  partitions: 2
  replicas: 1
  config:
    retention.ms: 1800000
EOF
    then
        print_success "Idempotent operations working correctly"
    else
        print_failure "Idempotent operations failed"
        return 1
    fi

    # Cleanup
    kubectl delete kafkatopic test-idempotent -n $NAMESPACE
}

# Test 6: Argo CD synchronization
test_argocd_sync() {
    print_test "Testing Argo CD synchronization..."

    # Check if Argo CD is installed
    if ! kubectl get namespace argocd &> /dev/null; then
        print_warning "Argo CD not installed, skipping sync test"
        return 0
    fi

    # Check if application exists
    if kubectl get application kafka-topics -n argocd &> /dev/null; then
        APP_STATUS=$(kubectl get application kafka-topics -n argocd -o jsonpath='{.status.health.status}')
        SYNC_STATUS=$(kubectl get application kafka-topics -n argocd -o jsonpath='{.status.sync.status}')

        if [[ "$APP_STATUS" == "Healthy" && "$SYNC_STATUS" == "Synced" ]]; then
            print_success "Argo CD application is healthy and synced"
        else
            print_warning "Argo CD application status - Health: $APP_STATUS, Sync: $SYNC_STATUS"
        fi
    else
        print_warning "Argo CD application 'kafka-topics' not found"
    fi
}

# Test 7: Multiple topic creation from directory
test_batch_topic_creation() {
    print_test "Testing batch topic creation from directory..."

    if [[ ! -d "$TOPICS_DIR" ]]; then
        print_warning "Topics directory '$TOPICS_DIR' not found, skipping batch test"
        return 0
    fi

    TOPIC_COUNT=0
    SUCCESS_COUNT=0

    # Apply all topic files in directory
    for topic_file in $TOPICS_DIR/*.yaml; do
        if [[ -f "$topic_file" ]]; then
            TOPIC_COUNT=$((TOPIC_COUNT + 1))
            TOPIC_NAME=$(basename "$topic_file" .yaml)

            if kubectl apply -f "$topic_file" &> /dev/null; then
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                print_status "Applied: $TOPIC_NAME"
            else
                print_error "Failed to apply: $TOPIC_NAME"
            fi
        fi
    done

    if [[ $SUCCESS_COUNT -eq $TOPIC_COUNT && $TOPIC_COUNT -gt 0 ]]; then
        print_success "Batch creation successful ($SUCCESS_COUNT/$TOPIC_COUNT topics)"
    elif [[ $TOPIC_COUNT -gt 0 ]]; then
        print_failure "Batch creation partially successful ($SUCCESS_COUNT/$TOPIC_COUNT topics)"
        return 1
    else
        print_warning "No topic files found in directory"
    fi
}

# Test 8: Configuration validation
test_config_validation() {
    print_test "Testing configuration validation..."

    # Test invalid configuration (should fail)
    if kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-validation
  namespace: $NAMESPACE
  labels:
    strimzi.io/cluster: "$CLUSTER_NAME"
spec:
  partitions: 1
  replicas: 5  # More replicas than brokers (should fail)
  config:
    retention.ms: -1000  # Invalid retention
EOF
    then
        print_failure "Invalid configuration was accepted"
        return 1
    else
        print_success "Configuration validation working (invalid config rejected)"
    fi
}

# Generate test report
generate_report() {
    print_status "Generating test report..."

    echo
    echo "=============================================="
    echo "           TEST EXECUTION REPORT            "
    echo "=============================================="
    echo

    # Summary
    TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
    echo "Summary:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo "  Passed: $TESTS_PASSED"
    echo "  Failed: $TESTS_FAILED"
    echo "  Success Rate: $(( (TESTS_PASSED * 100) / TOTAL_TESTS ))%"
    echo

    # Detailed results
    echo "Detailed Results:"
    for result in "${TEST_RESULTS[@]}"; do
        echo "  $result"
    done
    echo

    # Cluster status
    echo "Cluster Status:"
    kubectl get kafka $CLUSTER_NAME -n $NAMESPACE -o jsonpath='Name: {.metadata.name}, Status: {.status.conditions[?(@.type=="Ready")].status}'
    echo
    echo

    # Topic count
    TOPIC_COUNT=$(kubectl get kafkatopic -n $NAMESPACE --no-headers | wc -l)
    echo "Current Topics: $TOPIC_COUNT"
    echo

    # Overall status
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC}"
        return 0
    else
        echo -e "${RED}❌ SOME TESTS FAILED!${NC}"
        return 1
    fi
}

# Cleanup function
cleanup() {
    print_status "Cleaning up test resources..."

    # Remove test topics
    kubectl delete kafkatopic test-topic-creation -n $NAMESPACE --ignore-not-found=true
    kubectl delete kafkatopic test-idempotent -n $NAMESPACE --ignore-not-found=true
    kubectl delete kafkatopic test-validation -n $NAMESPACE --ignore-not-found=true

    print_status "Cleanup completed"
}

# Main execution
main() {
    print_status "Starting Kafka Topics comprehensive testing..."
    echo

    # Trap cleanup on exit
    trap cleanup EXIT

    # Run all tests
    check_prerequisites
    test_topic_creation
    test_topic_config_update
    test_message_flow
    test_topic_deletion
    test_idempotent_operations
    test_argocd_sync
    test_batch_topic_creation
    test_config_validation

    echo
    generate_report
}

# Handle script interruption
trap 'print_error "Test interrupted"; exit 1' INT TERM

# Run main function
main "$@"
