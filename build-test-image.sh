#!/bin/bash
set -e

# Script to build ovn-kubernetes test image with OCPBUGS-86018 fix
# This creates a local image you can push to your registry for testing

IMAGE_NAME="${IMAGE_NAME:-quay.io/ssonigra/ovn-kubernetes}"
IMAGE_TAG="${IMAGE_TAG:-ocpbugs-86018-fix}"

echo "Building ovn-kubernetes image with OCPBUGS-86018 fix..."
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""

# Build using the standard Dockerfile
# Note: This uses the OpenShift registry base images
podman build -f Dockerfile -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo ""
echo "✅ Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "To push to your registry:"
echo "  podman push ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "To use in your cluster, update the daemonset:"
echo "  oc set image ds/ovnkube-node -n openshift-ovn-kubernetes ovnkube-node=${IMAGE_NAME}:${IMAGE_TAG}"
echo "  oc set image ds/ovnkube-master -n openshift-ovn-kubernetes ovnkube-master=${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
