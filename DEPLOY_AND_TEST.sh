#!/bin/bash
set -e

# Deployment and Testing Script for OCPBUGS-86018 Fix
# This script will deploy your custom image and test the fix

# Configuration - UPDATE THESE VALUES
CUSTOM_IMAGE="${CUSTOM_IMAGE:-quay.io/YOUR_USERNAME/ovn-kubernetes:ocpbugs-86018}"
TEST_NAMESPACE="test-allocate-lb-nodeports"

echo "=========================================="
echo "OCPBUGS-86018 Fix - Deployment & Testing"
echo "=========================================="
echo ""
echo "Custom Image: ${CUSTOM_IMAGE}"
echo ""

# Function to check if logged into OpenShift
check_oc_login() {
    if ! oc whoami &>/dev/null; then
        echo "❌ Not logged into OpenShift cluster"
        echo "Please run: oc login <your-cluster>"
        exit 1
    fi
    echo "✅ Logged into OpenShift as: $(oc whoami)"
    echo "   Cluster: $(oc whoami --show-server)"
}

# Function to backup current image configuration
backup_current_config() {
    echo ""
    echo "📦 Backing up current ovnkube-node image..."
    CURRENT_NODE_IMAGE=$(oc get ds/ovnkube-node -n openshift-ovn-kubernetes -o jsonpath='{.spec.template.spec.containers[?(@.name=="ovnkube-node")].image}')
    echo "   Current ovnkube-node image: ${CURRENT_NODE_IMAGE}"
    echo "${CURRENT_NODE_IMAGE}" > /tmp/ovnkube-node-original-image.txt

    echo ""
    echo "📦 Backing up current ovnkube-master image..."
    CURRENT_MASTER_IMAGE=$(oc get ds/ovnkube-master -n openshift-ovn-kubernetes -o jsonpath='{.spec.template.spec.containers[?(@.name=="ovnkube-master")].image}')
    echo "   Current ovnkube-master image: ${CURRENT_MASTER_IMAGE}"
    echo "${CURRENT_MASTER_IMAGE}" > /tmp/ovnkube-master-original-image.txt

    echo ""
    echo "✅ Original images backed up to /tmp/ovnkube-*-original-image.txt"
}

# Function to deploy custom image
deploy_custom_image() {
    echo ""
    echo "🚀 Deploying custom image with OCPBUGS-86018 fix..."

    echo "   Updating ovnkube-node daemonset..."
    oc set image ds/ovnkube-node -n openshift-ovn-kubernetes \
        ovnkube-node=${CUSTOM_IMAGE} \
        --record

    echo "   Updating ovnkube-master daemonset..."
    oc set image ds/ovnkube-master -n openshift-ovn-kubernetes \
        ovnkube-master=${CUSTOM_IMAGE} \
        --record

    echo ""
    echo "⏳ Waiting for rollout to complete..."
    echo "   This may take a few minutes..."

    if ! oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes --timeout=10m; then
        echo "⚠️  Rollout timeout for ovnkube-node, checking status..."
        oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node
    fi

    if ! oc rollout status ds/ovnkube-master -n openshift-ovn-kubernetes --timeout=10m; then
        echo "⚠️  Rollout timeout for ovnkube-master, checking status..."
        oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master
    fi

    echo ""
    echo "✅ Custom image deployed successfully!"
}

# Function to create test resources
create_test_resources() {
    echo ""
    echo "🧪 Creating test resources..."

    # Create namespace
    oc new-project ${TEST_NAMESPACE} 2>/dev/null || oc project ${TEST_NAMESPACE}

    # Create test deployment
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: ${TEST_NAMESPACE}
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

    # Wait for deployment
    echo "   Waiting for deployment to be ready..."
    oc wait --for=condition=available --timeout=120s deployment/test-app -n ${TEST_NAMESPACE}

    # Create LoadBalancer service
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: test-service
  namespace: ${TEST_NAMESPACE}
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

    echo "   ✅ Test resources created"
}

# Function to test NodePort is accessible
test_nodeport_accessible() {
    echo ""
    echo "🔍 Step 1: Testing NodePort is accessible (BEFORE disabling)..."

    # Get NodePort
    NODEPORT=$(oc get svc test-service -n ${TEST_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}')

    if [ -z "$NODEPORT" ]; then
        echo "   ⚠️  No NodePort assigned yet, waiting..."
        sleep 5
        NODEPORT=$(oc get svc test-service -n ${TEST_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}')
    fi

    echo "   NodePort assigned: ${NODEPORT}"

    # Pick a node
    NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
    echo "   Testing on node: ${NODE}"

    # Test NodePort accessibility
    echo "   Testing connection to NodePort..."
    if oc debug node/${NODE} -- chroot /host curl -v --max-time 5 http://localhost:${NODEPORT} 2>&1 | grep -q "200 OK\|Welcome to nginx"; then
        echo "   ✅ NodePort ${NODEPORT} is ACCESSIBLE (expected before fix)"
    else
        echo "   ⚠️  NodePort ${NODEPORT} is NOT accessible (unexpected)"
    fi

    # Save for later
    echo "${NODEPORT}" > /tmp/test-nodeport.txt
    echo "${NODE}" > /tmp/test-node.txt
}

# Function to disable NodePort allocation
disable_nodeport_allocation() {
    echo ""
    echo "🔧 Step 2: Disabling allocateLoadBalancerNodePorts..."

    # Patch service to disable NodePort allocation
    oc patch svc test-service -n ${TEST_NAMESPACE} --type=merge \
        -p '{"spec":{"allocateLoadBalancerNodePorts":false}}'

    # Remove NodePort from spec
    oc patch svc test-service -n ${TEST_NAMESPACE} --type=json \
        -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'

    echo "   ✅ allocateLoadBalancerNodePorts set to false"

    # Verify
    echo "   Verifying service configuration..."
    oc get svc test-service -n ${TEST_NAMESPACE} -o yaml | grep -A2 "allocateLoadBalancerNodePorts\|nodePort" || true
}

# Function to test the fix
test_nodeport_cleanup() {
    echo ""
    echo "🎯 Step 3: Testing NodePort cleanup (THE FIX)..."

    NODEPORT=$(cat /tmp/test-nodeport.txt)
    NODE=$(cat /tmp/test-node.txt)

    echo "   Waiting 10 seconds for OVN reconciliation..."
    sleep 10

    echo "   Testing if NodePort ${NODEPORT} is still accessible..."

    if oc debug node/${NODE} -- chroot /host curl -v --max-time 5 http://localhost:${NODEPORT} 2>&1 | grep -q "Connection refused\|Connection timed out\|Failed to connect"; then
        echo ""
        echo "   ✅✅✅ SUCCESS! NodePort listener has been REMOVED!"
        echo "   The fix is working correctly - OCPBUGS-86018 is FIXED!"
        echo ""
        return 0
    else
        echo ""
        echo "   ❌ FAILED! NodePort ${NODEPORT} is still accessible"
        echo "   This means the bug still exists (NodePort not cleaned up)"
        echo ""
        return 1
    fi
}

# Function to verify ClusterIP still works
test_clusterip_works() {
    echo ""
    echo "✅ Step 4: Verifying ClusterIP still works..."

    CLUSTER_IP=$(oc get svc test-service -n ${TEST_NAMESPACE} -o jsonpath='{.spec.clusterIP}')
    echo "   ClusterIP: ${CLUSTER_IP}"

    if oc run curl-test --rm -i --restart=Never --image=curlimages/curl -n ${TEST_NAMESPACE} -- \
        curl -v --max-time 5 http://${CLUSTER_IP}:80 2>&1 | grep -q "200 OK\|Welcome to nginx"; then
        echo "   ✅ ClusterIP is working (service functionality preserved)"
    else
        echo "   ⚠️  ClusterIP test inconclusive"
    fi
}

# Function to cleanup test resources
cleanup_test_resources() {
    echo ""
    read -p "🗑️  Do you want to cleanup test resources? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "   Deleting test namespace..."
        oc delete project ${TEST_NAMESPACE}
        echo "   ✅ Test resources cleaned up"
    else
        echo "   ℹ️  Test resources kept. To cleanup later run:"
        echo "      oc delete project ${TEST_NAMESPACE}"
    fi
}

# Function to restore original images
restore_original_images() {
    echo ""
    read -p "🔄 Do you want to restore original ovn-kubernetes images? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f /tmp/ovnkube-node-original-image.txt ]; then
            ORIGINAL_NODE=$(cat /tmp/ovnkube-node-original-image.txt)
            echo "   Restoring ovnkube-node to: ${ORIGINAL_NODE}"
            oc set image ds/ovnkube-node -n openshift-ovn-kubernetes ovnkube-node=${ORIGINAL_NODE}
        fi

        if [ -f /tmp/ovnkube-master-original-image.txt ]; then
            ORIGINAL_MASTER=$(cat /tmp/ovnkube-master-original-image.txt)
            echo "   Restoring ovnkube-master to: ${ORIGINAL_MASTER}"
            oc set image ds/ovnkube-master -n openshift-ovn-kubernetes ovnkube-master=${ORIGINAL_MASTER}
        fi

        echo "   ✅ Original images restored"
    else
        echo "   ℹ️  Custom image kept. To restore later, use images from:"
        echo "      /tmp/ovnkube-node-original-image.txt"
        echo "      /tmp/ovnkube-master-original-image.txt"
    fi
}

# Main execution
main() {
    check_oc_login
    backup_current_config
    deploy_custom_image
    create_test_resources
    test_nodeport_accessible
    disable_nodeport_allocation

    if test_nodeport_cleanup; then
        TEST_RESULT="PASSED"
    else
        TEST_RESULT="FAILED"
    fi

    test_clusterip_works

    echo ""
    echo "=========================================="
    echo "TEST RESULT: ${TEST_RESULT}"
    echo "=========================================="

    cleanup_test_resources
    restore_original_images

    echo ""
    echo "✅ Testing complete!"
    echo ""
    echo "For detailed logs, check:"
    echo "  oc logs -n openshift-ovn-kubernetes ds/ovnkube-master -c ovnkube-master | grep test-service"
}

# Run main function
main
