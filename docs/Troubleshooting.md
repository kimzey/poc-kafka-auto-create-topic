# Troubleshooting Guide for Declarative Kafka Topics POC

## 🚨 Common Issues and Solutions

### 1. Installation Issues

#### Issue: Kind cluster creation fails
**Symptoms:**
- `ERROR: failed to create cluster: failed to init kubernetes`
- Docker connection errors

**Solutions:**
```bash
# Check Docker Desktop is running
docker info

# Reset Docker state
docker system prune -f

# Restart Docker Desktop
# Recreate cluster with explicit configuration
kind delete cluster --name kafka-poc
kind create cluster --name kafka-poc --config scripts/kind-config.yaml
```

#### Issue: Port conflicts on macOS
**Symptoms:**
- `Error: listen tcp :9092: bind: address already in use`
- Services fail to start

**Solutions:**
```bash
# Check what's using the ports
lsof -i :9092
lsof -i :30080

# Kill processes if needed
kill -9 <PID>

# Or modify kind-config.yaml to use different ports
```

#### Issue: Homebrew installation fails on Apple Silicon
**Symptoms:**
- Command not found: brew
- Permission denied errors

**Solutions:**
```bash
# Install Homebrew for Apple Silicon
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add to shell profile
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
source ~/.zshrc
```

### 2. Strimzi Operator Issues

#### Issue: Strimzi pods stuck in CrashLoopBackOff
**Symptoms:**
- `kubectl get pods -n strimzi` shows restarting pods
- Operator logs show permission errors

**Solutions:**
```bash
# Check operator logs
kubectl logs -n strimzi deployment/strimzi-kafka-operator

# Check RBAC permissions
kubectl get clusterrole strimzi-kafka-operator -o yaml

# Restart operator
kubectl rollout restart deployment/strimzi-kafka-operator -n strimzi

# Reinstall if necessary
helm uninstall strimzi-kafka-operator -n strimzi
helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator -n strimzi
```

#### Issue: Kafka cluster never becomes Ready
**Symptoms:**
- `kubectl get kafka my-cluster -n strimzi` shows status not Ready
- Pods are pending or crash

**Solutions:**
```bash
# Check Kafka status details
kubectl describe kafka my-cluster -n strimzi

# Check individual pod status
kubectl get pods -n strimzi -l strimzi.io/kind=kafka

# Check pod logs
kubectl logs -n strimzi -l strimzi.io/kind=kafka

# Check resource constraints
kubectl describe node
kubectl top nodes

# Increase resource limits if needed
kubectl patch kafka my-cluster -n strimzi --type='merge' -p='{"spec":{"kafka":{"resources":{"limits":{"memory":"8Gi"}}}}}'
```

#### Issue: Topic creation fails with error
**Symptoms:**
- `kubectl apply` succeeds but topic doesn't appear
- KafkaTopic resource shows error status

**Solutions:**
```bash
# Check KafkaTopic status
kubectl get kafkatopic <topic-name> -n strimzi -o yaml

# Check topic operator logs
kubectl logs -n strimzi -l strimzi.io/kind=topic-operator

# Verify cluster label
kubectl get kafkatopic <topic-name> -n strimzi -o jsonpath='{.metadata.labels.strimzi\.io/cluster}'

# Ensure cluster exists and is ready
kubectl get kafka my-cluster -n strimzi

# Check broker availability
kubectl exec my-cluster-kafka-0 -n strimzi -- kafka-broker-api-versions.sh --bootstrap-server localhost:9092
```

### 3. Argo CD Issues

#### Issue: Argo CD application not syncing
**Symptoms:**
- Application shows "OutOfSync" status
- No automatic synchronization

**Solutions:**
```bash
# Check application status
kubectl get application kafka-topics -n argocd -o yaml

# Check Argo CD server logs
kubectl logs -n argocd deployment/argocd-server

# Check repository connectivity
argocd repo list

# Force manual sync
argocd app sync kafka-topics

# Check webhook configuration (if using GitHub)
kubectl get application kafka-topics -n argocd -o jsonpath='{.spec.source.repoURL}'
```

#### Issue: Cannot access Argo CD UI
**Symptoms:**
- Connection refused errors
- HTTP 502 Bad Gateway

**Solutions:**
```bash
# Check service configuration
kubectl get svc argocd-server -n argocd

# Check port mappings
kubectl describe svc argocd-server -n argocd

# Check NodePort configuration
kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[*].nodePort}'

# For local access, try port-forwarding
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Then access https://localhost:8080
```

#### Issue: Argo CD password not working
**Symptoms:**
- Invalid credentials error
- Cannot retrieve initial password

**Solutions:**
```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Reset password if needed
kubectl -n argocd patch secret argocd-secret \
  -p '{"data":{"admin.password":"'$(echo -n 'newpassword' | base64)'"}}'

# Restart Argo CD server
kubectl rollout restart deployment/argocd-server -n argocd
```

### 4. Topic Management Issues

#### Issue: Cannot increase partitions
**Symptoms:**
- Partition update fails
- Error about decreasing partitions

**Solutions:**
```bash
# Current partitions can only increase
kubectl get kafkatopic <topic-name> -n strimzi -o jsonpath='{.spec.partitions}'

# Patch with higher number
kubectl patch kafkatopic <topic-name> -n strimzi -p '{"spec":{"partitions":<higher-number>}}'

# Wait for update
kubectl wait kafkatopic/<topic-name> --for=condition=Ready --timeout=300s -n strimzi

# Verify in Kafka
kubectl exec my-cluster-kafka-0 -n strimzi -- kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic <topic-name>
```

#### Issue: Topic deletion not working
**Symptoms:**
- KafkaTopic deleted but topic remains in Kafka
- Argo CD keeps recreating topic

**Solutions:**
```bash
# Ensure topic deletion is enabled in Kafka config
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.spec.kafka.config.delete.topic.enable}'

# Enable topic deletion if needed
kubectl patch kafka my-cluster -n strimzi --type='merge' -p='{"spec":{"kafka":{"config":{"delete.topic.enable":"true"}}}}'

# Delete topic manually if operator fails
kubectl exec my-cluster-kafka-0 -n strimzi -- kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic <topic-name>

# Check topic operator for stuck operations
kubectl logs -n strimzi -l strimzi.io/kind=topic-operator | grep -i error
```

#### Issue: Configuration validation failures
**Symptoms:**
- Valid configs rejected
- Unexpected validation errors

**Solutions:**
```bash
# Check Kafka version compatibility
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.spec.kafka.version}'

# Review Strimzi documentation for valid config keys
# https://strimzi.io/docs/operators/latest/full/using.html#kafka-topic-configuration

# Test with minimal config first
kubectl apply -f - <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: test-minimal
  namespace: strimzi
  labels:
    strimzi.io/cluster: "my-cluster"
spec:
  partitions: 1
  replicas: 1
EOF
```

### 5. Performance Issues

#### Issue: Slow topic creation
**Symptoms:**
- Topic creation takes > 5 minutes
- Timeouts during operations

**Solutions:**
```bash
# Check cluster resource utilization
kubectl top pods -n strimzi -l strimzi.io/kind=kafka
kubectl top nodes

# Check disk I/O
kubectl exec my-cluster-kafka-0 -n strimzi -- iostat -x 1 5

# Check broker logs for slow operations
kubectl logs -n strimzi -l strimzi.io/kind=kafka | grep -i slow

# Increase broker resources
kubectl patch kafka my-cluster -n strimzi --type='merge' -p='{"spec":{"kafka":{"resources":{"limits":{"cpu":"4000m","memory":"8Gi"}}}}}'
```

#### Issue: High memory usage
**Symptoms:**
- Pods OOMKilled
- Constant memory growth

**Solutions:**
```bash
# Check current memory usage
kubectl exec my-cluster-kafka-0 -n strimzi -- free -h

# Check JVM settings
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.spec.kafka.jvmOptions}'

# Optimize heap size
kubectl patch kafka my-cluster -n strimzi --type='merge' -p='{"spec":{"kafka":{"jvmOptions":{"-Xmx":"6g","-Xms":"6g"}}}}'

# Check for memory leaks in logs
kubectl logs -n strimzi -l strimzi.io/kind=kafka | grep -i "OutOfMemoryError"
```

### 6. Network and Connectivity Issues

#### Issue: Cannot connect to Kafka from outside cluster
**Symptoms:**
- Connection refused from external clients
- DNS resolution failures

**Solutions:**
```bash
# Check external listener configuration
kubectl get kafka my-cluster -n strimzi -o jsonpath='{.spec.kafka.listeners}'

# Check NodePort services
kubectl get svc -n strimzi -l strimzi.io/kind=kafka

# For kind, check port forwarding
kubectl port-forward svc/my-cluster-kafka-bootstrap 9092:9092 -n strimzi

# Test connection from pod
kubectl exec -it my-cluster-kafka-0 -n strimzi -- telnet localhost 9092
```

#### Issue: Inter-broker communication failures
**Symptoms:**
- Brokers cannot see each other
- Controller election failures

**Solutions:**
```bash
# Check broker network connectivity
kubectl exec -it my-cluster-kafka-0 -n strimzi -- ping my-cluster-kafka-1.kafka.strimzi.svc

# Check DNS resolution
kubectl exec -it my-cluster-kafka-0 -n strimzi -- nslookup my-cluster-kafka-brokers.kafka.strimzi.svc

# Check service endpoints
kubectl get endpoints -n strimzi -l strimzi.io/kind=kafka

# Restart broker network
kubectl rollout restart statefulset/my-cluster-kafka -n strimzi
```

### 7. Debugging Commands

#### Comprehensive Status Check
```bash
#!/bin/bash
# debug-poc.sh - Comprehensive debugging script

echo "=== Cluster Status ==="
kubectl get nodes
echo

echo "=== Namespace Status ==="
kubectl get ns
echo

echo "=== Strimzi Status ==="
kubectl get pods -n strimzi
kubectl get kafka -n strimzi
kubectl get kafkatopic -n strimzi
echo

echo "=== Argo CD Status ==="
kubectl get pods -n argocd
kubectl get application -n argocd
echo

echo "=== Recent Events ==="
kubectl get events --sort-by='.lastTimestamp' | tail -20
echo

echo "=== Resource Usage ==="
kubectl top nodes
kubectl top pods -n strimzi
echo
```

#### Log Collection
```bash
# Collect all relevant logs
mkdir -p debug-logs
kubectl logs -n strimzi deployment/strimzi-kafka-operator > debug-logs/operator.log
kubectl logs -n strimzi -l strimzi.io/kind=kafka > debug-logs/kafka.log
kubectl logs -n argocd deployment/argocd-server > debug-logs/argocd.log
kubectl logs -n argocd deployment/argocd-application-controller > debug-logs/argocd-controller.log
```

### 8. Recovery Procedures

#### Complete Environment Reset
```bash
#!/bin/bash
# reset-environment.sh

echo "Resetting POC environment..."

# Delete Argo CD application
kubectl delete application kafka-topics -n argocd --ignore-not-found=true

# Delete Kafka cluster
kubectl delete kafka my-cluster -n strimzi --ignore-not-found=true

# Delete Strimzi
helm uninstall strimzi-kafka-operator -n strimzi --ignore-not-found=true

# Delete Argo CD
kubectl delete namespace argocd --ignore-not-found=true
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found=true

# Delete kind cluster
kind delete cluster --name kafka-poc

echo "Environment reset complete. Run setup scripts to recreate."
```

#### State Recovery from Git
```bash
# Recover topic configurations from Git
git checkout HEAD -- topics/

# Reapply all topics
kubectl apply -f topics/

# Wait for all topics to be ready
for topic in $(kubectl get kafkatopic -n strimzi -o jsonpath='{.items[*].metadata.name}'); do
  echo "Waiting for topic: $topic"
  kubectl wait kafkatopic/$topic --for=condition=Ready --timeout=300s -n strimzi
done
```

## 📞 Getting Help

### Useful Resources
- [Strimzi Documentation](https://strimzi.io/docs/)
- [Argo CD Documentation](https://argo-cd.readthedocs.io/)
- [Kafka Documentation](https://kafka.apache.org/documentation/)
- [Kind Documentation](https://kind.sigs.k8s.io/)

### Community Support
- Strimzi Slack: #strimzi on CNCF Slack
- Argo CD Slack: #argo-cd on CNCF Slack
- GitHub Issues: Create issues in respective repositories

### Log Analysis Tips
- Look for `ERROR` and `WARN` patterns
- Check timestamp correlations between components
- Use `kubectl logs --since=1h` for recent issues
- Filter by namespace: `-n strimzi` or `-n argocd`

This troubleshooting guide should help resolve most common issues encountered during the POC implementation.