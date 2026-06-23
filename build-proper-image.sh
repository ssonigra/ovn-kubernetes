#!/bin/bash
set -e

# Build a proper ovn-kubernetes image with all dependencies
# Uses OpenShift's ovn-kubernetes base image

IMAGE_NAME="${IMAGE_NAME:-quay.io/ssonigra/ovn-kubernetes}"
IMAGE_TAG="${IMAGE_TAG:-ocpbugs-86018}"

echo "Building proper ovn-kubernetes image with OCPBUGS-86018 fix..."
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""

# Create Dockerfile that uses OpenShift's ovn-kubernetes base
cat > Dockerfile.proper <<'EOF'
# Stage 1: Build the binaries
FROM golang:1.25 AS builder

WORKDIR /workspace
COPY . .

# Build ovn-kubernetes binaries with the fix
RUN cd go-controller && \
    CGO_ENABLED=1 make clean && \
    CGO_ENABLED=1 make

# Stage 2: Runtime image based on OpenShift's ovn-kubernetes
# This already has OVN/OVS tools installed
FROM quay.io/openshift/origin-ovn-kubernetes:4.18

# Replace only the ovnkube binary with our fixed version
# Keep all other binaries and dependencies from the base image
COPY --from=builder /workspace/go-controller/_output/go/bin/ovnkube /usr/bin/ovnkube
COPY --from=builder /workspace/go-controller/_output/go/bin/ovn-k8s-cni-overlay /usr/bin/ovn-k8s-cni-overlay
COPY --from=builder /workspace/go-controller/_output/go/bin/ovnkube-trace /usr/bin/ovnkube-trace

# The base image already has the correct entrypoint and all OVN/OVS dependencies
EOF

# Build the image
echo "Building image..."
podman build -f Dockerfile.proper -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo ""
echo "✅ Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "To push to quay.io:"
echo "  podman push ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""

# Clean up
rm -f Dockerfile.proper
