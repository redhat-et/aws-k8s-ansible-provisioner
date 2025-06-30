#!/bin/bash
set -ex

CLUSTER_NAME="$1"
GPU_INDICES="$2"
BRIDGE_NETWORK_NAME="minikube-multi-cluster"

# Warn if running as root but continue (Ansible handles user switching)
if [ "$EUID" -eq 0 ]; then
    echo "Warning: Running as root. Minikube should typically run as a regular user."
    echo "Continuing anyway as this may be controlled by Ansible..."
fi

# Clean up any existing temporary files that might cause conflicts
echo "Cleaning up any existing temporary files for cluster '$CLUSTER_NAME'..."
sudo rm -rf /tmp/juju-mk* 2>/dev/null || true
sudo rm -rf /tmp/minikube* 2>/dev/null || true

# Test Docker access
if ! docker ps >/dev/null 2>&1; then
    echo "Error: Cannot access Docker. Please ensure Docker is running and user has permissions."
    exit 1
fi

# Create custom Docker bridge network if it doesn't exist
echo "Creating custom Docker bridge network '$BRIDGE_NETWORK_NAME' if it doesn't exist..."
docker network inspect $BRIDGE_NETWORK_NAME >/dev/null 2>&1 || \
docker network create --driver bridge \
  --subnet=172.30.0.0/16 \
  --ip-range=172.30.0.0/24 \
  --gateway=172.30.0.1 \
  $BRIDGE_NETWORK_NAME

echo "Custom bridge network '$BRIDGE_NETWORK_NAME' is ready"

# Get all GPU UUIDs
mapfile -t ALL_UUIDS < <(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null || true)

# If no GPUs were found, start without GPU support
if [ ${#ALL_UUIDS[@]} -eq 0 ]; then
  echo "No GPUs found. Starting cluster '$CLUSTER_NAME' without GPU support."
  minikube start --profile="$CLUSTER_NAME" --driver=docker \
    --extra-config=kubelet.max-open-files=1000000 \
    --extra-config=apiserver.max-requests-inflight=1000 \
    --cpus=16 --memory=65536
  
  # Connect to bridge network after creation
  echo "Connecting cluster '$CLUSTER_NAME' to bridge network..."
  docker network connect $BRIDGE_NETWORK_NAME $CLUSTER_NAME 2>/dev/null || echo "Already connected to bridge network"
  exit 0
fi

# Resolve GPU indices to UUIDs for Docker
GPU_UUID_LIST=""
IFS=',' read -ra GPU_INDICES_ARRAY <<< "$GPU_INDICES"

for i in "${GPU_INDICES_ARRAY[@]}"; do
  # Check if the index is valid
  if [ "$i" -ge "${#ALL_UUIDS[@]}" ]; then
      echo "Error: GPU index $i is out of bounds. Available GPUs: ${#ALL_UUIDS[@]}"
      exit 1
  fi

  if [ -n "$GPU_UUID_LIST" ]; then
    GPU_UUID_LIST="$GPU_UUID_LIST,"
  fi
  GPU_UUID_LIST="$GPU_UUID_LIST${ALL_UUIDS[$i]}"
done

echo "Attempting to create cluster '$CLUSTER_NAME' with GPUs: $GPU_UUID_LIST"

# Clean up any remaining temporary files before starting
sudo rm -rf /tmp/juju-mk* 2>/dev/null || true

echo "Starting minikube cluster '$CLUSTER_NAME' with docker driver..."
# Use docker driver which supports multiple profiles
# Pass GPU devices to the Docker container
# Connect to our custom bridge network AFTER creation to avoid Docker service conflicts
minikube start --profile="$CLUSTER_NAME" --driver=docker \
  --extra-config=kubelet.max-open-files=1000000 \
  --extra-config=apiserver.max-requests-inflight=1000 \
  --gpus=all \
  --cpus=16 --memory=65536

# Connect to bridge network after creation (this is the key fix)
echo "Connecting cluster '$CLUSTER_NAME' to bridge network..."
docker network connect $BRIDGE_NETWORK_NAME $CLUSTER_NAME 2>/dev/null || echo "Already connected to bridge network"

# Wait for the cluster to be ready
echo "Waiting for cluster '$CLUSTER_NAME' to be ready..."
sleep 15

# Get and display the container IP on the bridge network
CLUSTER_IP=$(docker inspect $CLUSTER_NAME --format='{{range .NetworkSettings.Networks}}{{if eq .NetworkID "'$(docker network inspect $BRIDGE_NETWORK_NAME --format='{{.Id}}')'"}}}{{.IPAddress}}{{end}}{{end}}')
echo "Cluster '$CLUSTER_NAME' IP on bridge network: $CLUSTER_IP"

# Create NVIDIA device plugin for GPU support
echo "Setting up GPU support for cluster '$CLUSTER_NAME'..."
minikube kubectl --profile="$CLUSTER_NAME" -- apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml || echo "GPU device plugin setup failed, but cluster is running"

# Wait a bit more for GPU plugin to initialize
sleep 10

# Verify GPU resources in the cluster
echo "Verifying GPU nodes in cluster '$CLUSTER_NAME'"
minikube kubectl --profile="$CLUSTER_NAME" -- get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu' || echo "GPU verification failed, but cluster is running"

# Show cluster status
echo "Cluster '$CLUSTER_NAME' setup complete!"
echo "Bridge Network IP: $CLUSTER_IP"
minikube status -p "$CLUSTER_NAME" 