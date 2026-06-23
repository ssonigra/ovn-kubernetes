#!/bin/bash
set -e

# Alternative build script that creates a minimal test image
# This is useful if you don't have access to OpenShift registry base images

IMAGE_NAME="${IMAGE_NAME:-localhost/ovn-kubernetes-test}"
IMAGE_TAG="${IMAGE_TAG:-ocpbugs-86018}"

echo "Building minimal ovn-kubernetes test image with OCPBUGS-86018 fix..."
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""

# Create a simple Dockerfile that just builds the binaries
cat > Dockerfile.test <<'EOF'
FROM golang:1.25 AS builder

WORKDIR /workspace
COPY . .

# Build the ovn-kubernetes binaries
RUN cd go-controller && \
    CGO_ENABLED=1 make && \
    ls -la _output/go/bin/

# Create a minimal runtime image
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Copy the built binaries
COPY --from=builder /workspace/go-controller/_output/go/bin/* /usr/bin/

# The binaries are now available in /usr/bin/
# You can extract them or run them in the container
CMD ["/bin/bash"]
EOF

# Build the image
podman build -f Dockerfile.test -t "${IMAGE_NAME}:${IMAGE_TAG}" .

echo ""
echo "✅ Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "The image contains the ovn-kubernetes binaries in /usr/bin/"
echo ""
echo "To extract the binaries:"
echo "  container_id=\$(podman create ${IMAGE_NAME}:${IMAGE_TAG})"
echo "  podman cp \$container_id:/usr/bin/ovnkube ./ovnkube"
echo "  podman rm \$container_id"
echo ""
echo "To push to quay.io (replace with your registry):"
echo "  podman tag ${IMAGE_NAME}:${IMAGE_TAG} quay.io/YOUR_USERNAME/ovn-kubernetes:${IMAGE_TAG}"
echo "  podman push quay.io/YOUR_USERNAME/ovn-kubernetes:${IMAGE_TAG}"
echo ""

# Clean up temporary Dockerfile
rm -f Dockerfile.test
