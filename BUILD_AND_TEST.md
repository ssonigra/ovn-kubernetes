# Building and Testing OCPBUGS-86018 Fix

This guide helps you build a container image with the OCPBUGS-86018 fix and test it in your OpenShift cluster.

## Prerequisites

- Podman or Docker installed
- Access to push to a container registry (quay.io, docker.io, or internal registry)
- OpenShift cluster with OVN-Kubernetes
- `oc` CLI tool

## Option 1: Build Using OpenShift Base Images (Recommended for OpenShift)

This builds the full OpenShift ovn-kubernetes image:

```bash
# Set your registry details
export IMAGE_NAME="quay.io/YOUR_USERNAME/ovn-kubernetes"
export IMAGE_TAG="ocpbugs-86018-fix"

# Build the image
./build-test-image.sh

# Push to your registry
podman login quay.io  # Login first
podman push ${IMAGE_NAME}:${IMAGE_TAG}
```

**Note**: This requires access to `registry.ci.openshift.org`. If you don't have access, use Option 2.

## Option 2: Build Minimal Test Image (Works Anywhere)

This builds just the binaries without requiring OpenShift base images:

```bash
# Build locally
./build-local-image.sh

# Tag for your registry
podman tag localhost/ovn-kubernetes-test:ocpbugs-86018 quay.io/YOUR_USERNAME/ovn-kubernetes:ocpbugs-86018

# Push to registry
podman login quay.io
podman push quay.io/YOUR_USERNAME/ovn-kubernetes:ocpbugs-86018
```

## Option 3: Manual Build Steps

If you prefer manual control:

```bash
# Ensure you're on the fix branch
git checkout fix-OCPBUGS-86018-clean

# Build the binaries
cd go-controller
make clean
CGO_ENABLED=1 make

# The binaries will be in: go-controller/_output/go/bin/
# - ovnkube
# - ovn-k8s-cni-overlay
# - ovnkube-trace
# - etc.
```

## Deploying to OpenShift Cluster

### Method 1: Update DaemonSets (Recommended)

```bash
# Set your image
export TEST_IMAGE="quay.io/YOUR_USERNAME/ovn-kubernetes:ocpbugs-86018-fix"

# Update ovnkube-node daemonset
oc set image ds/ovnkube-node -n openshift-ovn-kubernetes \
  ovnkube-node=${TEST_IMAGE}

# Update ovnkube-master daemonset  
oc set image ds/ovnkube-master -n openshift-ovn-kubernetes \
  ovnkube-master=${TEST_IMAGE}

# Watch the rollout
oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes
oc rollout status ds/ovnkube-master -n openshift-ovn-kubernetes
```

### Method 2: Patch ClusterNetworkOperator (Alternative)

```bash
# This tells CNO to use your custom image
oc patch network.operator.openshift.io cluster --type=merge \
  --patch '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":false}}}}}'

# Then manually update the daemonsets as shown in Method 1
```

## Testing the Fix

### Step 1: Create Test Service

```bash
# Create a test namespace
oc new-project test-allocate-lb-nodeports

# Create a deployment
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: test-allocate-lb-nodeports
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:latest
        ports:
        - containerPort: 8080
EOF

# Create LoadBalancer service WITH NodePort (allocateLoadBalancerNodePorts defaults to true)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: test-allocate-lb-nodeports
spec:
  type: LoadBalancer
  selector:
    app: test-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
EOF
```

### Step 2: Verify NodePort Exists

```bash
# Get the assigned NodePort
NODEPORT=$(oc get svc test-service -n test-allocate-lb-nodeports -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODEPORT"

# Pick a node
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
echo "Testing on node: $NODE"

# Test that NodePort is accessible (should work)
oc debug node/$NODE -- chroot /host curl -v http://localhost:$NODEPORT
```

**Expected**: Connection should succeed (you should see nginx response)

### Step 3: Disable allocateLoadBalancerNodePorts

```bash
# Update service to disable NodePort allocation
oc patch svc test-service -n test-allocate-lb-nodeports --type=merge \
  -p '{"spec":{"allocateLoadBalancerNodePorts":false}}'

# Remove the NodePort from spec (Kubernetes requirement)
oc patch svc test-service -n test-allocate-lb-nodeports --type=json \
  -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'

# Verify the service no longer has NodePort
oc get svc test-service -n test-allocate-lb-nodeports -o yaml | grep -A2 "allocateLoadBalancerNodePorts\|nodePort"
```

**Expected output**: You should see `allocateLoadBalancerNodePorts: false` and no `nodePort` field

### Step 4: Verify NodePort Listener is Removed (THE FIX)

```bash
# Wait a few seconds for reconciliation
sleep 5

# Try to connect to the same NodePort (should fail now)
oc debug node/$NODE -- chroot /host curl -v --max-time 5 http://localhost:$NODEPORT
```

**Expected with the fix**: Connection should fail (Connection refused or timeout)

**Without the fix (bug)**: Connection would still succeed, proving the NodePort listener wasn't cleaned up

### Step 5: Verify Service Still Works via ClusterIP

```bash
# Get ClusterIP
CLUSTER_IP=$(oc get svc test-service -n test-allocate-lb-nodeports -o jsonpath='{.spec.clusterIP}')

# Test ClusterIP access (should still work)
oc run curl-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -v http://$CLUSTER_IP:80
```

**Expected**: Connection should succeed - ClusterIP functionality is unaffected

## Verification Checklist

- [x] NodePort is accessible when `allocateLoadBalancerNodePorts=true` (or unset)
- [x] NodePort listener is removed when changed to `allocateLoadBalancerNodePorts=false`
- [x] ClusterIP continues to work after disabling NodePort allocation
- [x] No errors in ovn-kubernetes controller logs

## Checking Logs

```bash
# Check ovnkube-master logs for any errors
oc logs -n openshift-ovn-kubernetes ds/ovnkube-master -c ovnkube-master | tail -100

# Check ovnkube-node logs
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node -c ovnkube-node | tail -100

# Look for service reconciliation messages
oc logs -n openshift-ovn-kubernetes ds/ovnkube-master -c ovnkube-master | \
  grep "test-service"
```

## Cleanup

```bash
# Delete test resources
oc delete project test-allocate-lb-nodeports

# Revert to original image (if needed)
oc set image ds/ovnkube-node -n openshift-ovn-kubernetes \
  ovnkube-node=registry.ci.openshift.org/ocp/4.22:ovn-kubernetes

oc set image ds/ovnkube-master -n openshift-ovn-kubernetes \
  ovnkube-master=registry.ci.openshift.org/ocp/4.22:ovn-kubernetes
```

## Troubleshooting

### Build fails with "permission denied"

```bash
# Use podman instead of docker
alias docker=podman

# Or run with sudo if necessary
sudo ./build-test-image.sh
```

### Cannot access OpenShift registry

Use Option 2 (build-local-image.sh) which uses public base images.

### Image push fails

```bash
# Login to your registry first
podman login quay.io
# or
podman login docker.io

# Make sure the repository exists and is public or you have push access
```

### Pods not updating after image change

```bash
# Force delete the pods to trigger recreation
oc delete pods -n openshift-ovn-kubernetes -l app=ovnkube-node
oc delete pods -n openshift-ovn-kubernetes -l app=ovnkube-master
```

## References

- JIRA Issue: https://redhat.atlassian.net/browse/OCPBUGS-86018
- Pull Request: https://github.com/openshift/ovn-kubernetes/pull/3261
- Implementation Plan: `.work/jira/solve/spec-OCPBUGS-86018.md`
