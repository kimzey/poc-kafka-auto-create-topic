# Testing Guide for Declarative Kafka Topics POC

## 🧪 Overview

This guide provides comprehensive testing procedures for validating the Declarative Kafka Topics implementation using Strimzi and Argo CD. The testing strategy covers functionality, performance, reliability, and edge cases.

## 📋 Test Categories

### 1. Functional Tests

#### 1.1 Topic Lifecycle Management
```bash
# Test Topic Creation
kubectl apply -f topics/orders-events.yaml
kubectl wait kafkatopic/orders-events --for=condition=Ready --timeout=300s -n strimzi

# Verify Topic in Kafka
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders-events

# Test Topic Update
kubectl patch kafkatopic orders-events -n strimzi -p '{"spec":{"partitions":16}}'
kubectl wait kafkatopic/orders-events --for=condition=Ready --timeout=300s -n strimzi

# Test Topic Deletion
kubectl delete kafkatopic orders-events -n strimzi
```

#### 1.2 Configuration Validation
```bash
# Test Valid Configuration
kubectl apply -f topics/user-profile.yaml
kubectl get kafkatopic user-profile -n strimzi -o yaml

# Test Invalid Configuration (should fail)
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: invalid-test
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 1
  replicas: 5  # More than available brokers
EOF

# Verify rejection
echo "Exit code: $?"  # Should be non-zero
```

#### 1.3 Idempotency Tests
```bash
# Apply Same Configuration Multiple Times
for i in {1..3}; do
  echo "Attempt $i:"
  kubectl apply -f topics/orders-events.yaml
  sleep 2
done

# Verify No Duplicates
kubectl get kafkatopic orders-events -n strimzi -o jsonpath='{.spec.partitions}'
```

### 2. GitOps Integration Tests

#### 2.1 Argo CD Synchronization
```bash
# Check Argo CD Application Status
kubectl get application kafka-topics -n argocd -o wide

# Monitor Sync Status
watch kubectl get application kafka-topics -n argocd

# Force Manual Sync (if needed)
argocd app sync kafka-topics

# Check Sync History
argocd app history kafka-topics
```

#### 2.2 Git Workflow Tests
```bash
# Create New Topic in Git
cat > topics/new-test-topic.yaml <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: new-test-topic
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 3
  replicas: 3
  config:
    retention.ms: 3600000
EOF

# Git Add, Commit, Push
git add topics/new-test-topic.yaml
git commit -m "Add new test topic"
git push origin main

# Wait for Sync and Verify
sleep 30
kubectl get kafkatopic new-test-topic -n strimzi
```

#### 2.3 Rollback Tests
```bash
# Save Current State
kubectl get kafkatopic -n strimzi -o yaml > backup-topics.yaml

# Make Changes
kubectl patch kafkatopic orders-events -n strimzi -p '{"spec":{"config":{"retention.ms":"7200000"}}}'

# Rollback via Git
git reset --hard HEAD~1
git push --force origin main

# Wait for Rollback Sync
sleep 30
kubectl get kafkatopic orders-events -n strimzi -o jsonpath='{.spec.config.retention.ms}'
```

### 3. Data Integrity Tests

#### 3.1 Message Production/Consumption
```bash
# Producer Test
TEST_MESSAGE="test-$(date +%s)"
echo "$TEST_MESSAGE" | kubectl exec -i my-cluster-kafka-0 -n strimzi -- \
  kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events

# Consumer Test
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders-events --from-beginning --max-messages 1 --timeout-ms 5000

# Batch Message Test
for i in {1..100}; do
  echo "message-$i" | kubectl exec -i my-cluster-kafka-0 -n strimzi -- \
    kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events
done
```

#### 3.2 Partition Resize Data Safety
```bash
# Produce Messages to All Partitions
for i in {1..50}; do
  echo "message-$i" | kubectl exec -i my-cluster-kafka-0 -n strimzi -- \
    kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events --partition $((i % 12))
done

# Resize Partitions
kubectl patch kafkatopic orders-events -n strimzi -p '{"spec":{"partitions":24}}'
kubectl wait kafkatopic/orders-events --for=condition=Ready --timeout=300s -n strimzi

# Verify Data Integrity
MESSAGE_COUNT=$(kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 --topic orders-events | awk -F: '{sum+=$3} END {print sum}')

echo "Total messages after resize: $MESSAGE_COUNT"
```

### 4. Performance Tests

#### 4.1 Throughput Testing
```bash
# Producer Performance Test
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-producer-perf-test.sh \
  --topic orders-events \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 10000 \
  --producer-props bootstrap.servers=localhost:9092

# Consumer Performance Test
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-consumer-perf-test.sh \
  --topic orders-events \
  --messages 100000 \
  --bootstrap-server localhost:9092
```

#### 4.2 Latency Testing
```bash
# End-to-End Latency Test
START_TIME=$(date +%s%N)
echo "latency-test" | kubectl exec -i my-cluster-kafka-0 -n strimzi -- \
  kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events

RECEIVED_TIME=$(kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders-events --from-beginning --max-messages 1 --timeout-ms 10000 | \
  xargs -I {} date +%s%N)

LATENCY_MS=$(( (RECEIVED_TIME - START_TIME) / 1000000 ))
echo "End-to-end latency: ${LATENCY_MS}ms"
```

#### 4.3 Resource Utilization
```bash
# Monitor Resource Usage During Load
kubectl top pods -n strimzi -l strimzi.io/kind=kafka --no-headers | \
  awk '{cpu+=$2; memory+=$3} END {print "CPU:", cpu, "Memory:", memory}'

# Monitor Disk Usage
kubectl exec my-cluster-kafka-0 -n strimzi -- df -h /var/lib/kafka/data
```

### 5. Reliability Tests

#### 5.1 Failure Scenarios
```bash
# Simulate Broker Failure
kubectl scale deployment my-cluster-kafka --replicas=2 -n strimzi
sleep 30

# Verify Cluster Health
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Restore Broker
kubectl scale deployment my-cluster-kafka --replicas=3 -n strimzi
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=600s -n strimzi

# Verify Data Integrity
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders-events
```

#### 5.2 Operator Failure Tests
```bash
# Stop Strimzi Operator
kubectl scale deployment strimzi-kafka-operator --replicas=0 -n strimzi

# Make Topic Changes (should queue)
kubectl apply -f topics/new-topic-during-outage.yaml

# Restart Operator
kubectl scale deployment strimzi-kafka-operator --replicas=1 -n strimzi
kubectl wait deployment/strimzi-kafka-operator --for=condition=Available -n strimzi

# Verify Changes Applied
kubectl get kafkatopic new-topic-during-outage -n strimzi
```

### 6. Edge Cases and Boundary Tests

#### 6.1 Large Configuration Tests
```bash
# Create Topic with Maximum Partitions
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: max-partitions-test
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 100
  replicas: 3
  config:
    retention.ms: 86400000
EOF

# Create Topic with Large Message Size
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: large-message-test
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 3
  replicas: 3
  config:
    max.message.bytes: 10485760  # 10MB
EOF
```

#### 6.2 Special Characters and Encoding
```bash
# Test with Special Characters in Topic Name
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-with-dashes_and_underscores
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 3
  replicas: 3
EOF

# Test Unicode in Messages
echo "测试消息" | kubectl exec -i my-cluster-kafka-0 -n strimzi -- \
  kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events

# Verify Unicode Preservation
kubectl exec my-cluster-kafka-0 -n strimzi -- \
  kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders-events --from-beginning --max-messages 1 --timeout-ms 5000
```

## 📊 Test Automation

### Automated Test Suite
```bash
#!/bin/bash
# comprehensive-test.sh

set -e

# Configuration
NAMESPACE="strimzi"
CLUSTER_NAME="my-cluster"
TEST_RESULTS_FILE="test-results-$(date +%Y%m%d-%H%M%S).log"

# Test Results Tracking
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo "Running: $test_name" | tee -a "$TEST_RESULTS_FILE"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if eval "$test_command" >> "$TEST_RESULTS_FILE" 2>&1; then
        echo "✅ PASS: $test_name" | tee -a "$TEST_RESULTS_FILE"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❌ FAIL: $test_name" | tee -a "$TEST_RESULTS_FILE"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    echo "---" | tee -a "$TEST_RESULTS_FILE"
}

# Run All Tests
run_test "Topic Creation" "kubectl apply -f topics/orders-events.yaml"
run_test "Topic Readiness" "kubectl wait kafkatopic/orders-events --for=condition=Ready --timeout=300s -n strimzi"
run_test "Message Production" "echo 'test' | kubectl exec -i my-cluster-kafka-0 -n strimzi -- kafka-console-producer.sh --broker-list localhost:9092 --topic orders-events"
run_test "Message Consumption" "kubectl exec my-cluster-kafka-0 -n strimzi -- kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders-events --from-beginning --max-messages 1 --timeout-ms 5000"

# Generate Report
echo "Test Summary:" | tee -a "$TEST_RESULTS_FILE"
echo "Total: $TESTS_TOTAL" | tee -a "$TEST_RESULTS_FILE"
echo "Passed: $TESTS_PASSED" | tee -a "$TEST_RESULTS_FILE"
echo "Failed: $TESTS_FAILED" | tee -a "$TEST_RESULTS_FILE"
echo "Success Rate: $(( (TESTS_PASSED * 100) / TESTS_TOTAL ))%" | tee -a "$TEST_RESULTS_FILE"

exit $TESTS_FAILED
```

## 🔍 Test Monitoring and Observability

### Monitoring Commands
```bash
# Real-time Topic Monitoring
watch "kubectl get kafkatopic -n strimzi && echo '---' && kubectl get pods -n strimzi -l strimzi.io/kind=kafka"

# Argo CD Sync Monitoring
watch "kubectl get application kafka-topics -n argocd -o jsonpath='{.status.sync.status}' && echo '---' && argocd app list"

# Kafka Cluster Health
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.status.conditions[*].type} {..status}'

# Resource Utilization
kubectl top pods -n strimzi -l strimzi.io/kind=kafka
kubectl top nodes
```

### Log Analysis
```bash
# Strimzi Operator Logs
kubectl logs -n strimzi deployment/strimzi-kafka-operator --tail=100 -f

# Kafka Broker Logs
kubectl logs -n strimzi -l strimzi.io/kind=kafka --tail=100 -f

# Argo CD Controller Logs
kubectl logs -n argocd deployment/argocd-application-controller --tail=100 -f

# Topic Operator Logs
kubectl logs -n strimzi -l strimzi.io/kind=topic-operator --tail=100 -f
```

## 🎯 Success Criteria

### Functional Success
- [ ] All topic CRUD operations work correctly
- [ ] Argo CD synchronization is reliable
- [ ] Configuration validation prevents invalid states
- [ ] Idempotent operations work as expected

### Performance Success
- [ ] Topic creation < 30 seconds
- [ ] Configuration updates < 60 seconds
- [ ] Message throughput > 10,000 msg/sec
- [ ] End-to-end latency < 100ms

### Reliability Success
- [ ] 99.9% operation success rate
- [ ] Zero data loss during failures
- [ ] Automatic recovery from transient failures
- [ ] Consistent behavior across restarts

## 📝 Test Report Template

```
=== Kafka Topics Declarative Management Test Report ===
Date: $(date)
Environment: kind/k3s/cluster-name
Strimzi Version: v0.35.1
Argo CD Version: v2.8.3

Test Results:
- Functional Tests: XX/XX passed
- Performance Tests: XX/XX passed
- Reliability Tests: XX/XX passed
- Edge Cases: XX/XX passed

Issues Found:
1. [Issue Description]
   Severity: High/Medium/Low
   Steps to Reproduce: [...]
   Expected Behavior: [...]
   Actual Behavior: [...]

Recommendations:
1. [Recommendation 1]
2. [Recommendation 2]

Conclusion:
[Overall assessment and go/no-go recommendation]
```

## 🚀 Continuous Testing

### CI/CD Integration
```yaml
# .github/workflows/test.yml
name: Kafka Topics POC Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    - name: Setup kind cluster
      run: ./scripts/setup-kind.sh
    - name: Install Strimzi
      run: ./scripts/install-strimzi.sh
    - name: Install Argo CD
      run: ./scripts/install-argocd.sh
    - name: Run Tests
      run: ./scripts/test-topics.sh
    - name: Upload Test Results
      uses: actions/upload-artifact@v2
      with:
        name: test-results
        path: test-results-*.log
```

This comprehensive testing guide ensures thorough validation of the Declarative Kafka Topics implementation across all dimensions of functionality, performance, and reliability.