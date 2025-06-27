#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [deploy|cleanup] [options]"
    echo ""
    echo "Commands:"
    echo "  deploy              Deploy a new K8s cluster on AWS GPU instance"
    echo "  cleanup             Cleanup AWS instances found in inventory files"
    exit 1
}

# Function to deploy cluster
deploy_cluster() {
    echo "=== Deploying K8s Cluster on AWS GPU Instance ==="

    echo "Launching AWS GPU instance..."
    ansible-playbook launch-instance.yaml

    echo "Finding generated inventory file..."
    INVENTORY_FILE=$(ls -rt gpu-inventory-*.ini | tail -1)

    if [ -z "$INVENTORY_FILE" ]; then
        echo "Error: No inventory file found!"
        exit 1
    fi

    echo "Using inventory file: $INVENTORY_FILE"

    echo "Configuring Kubernetes cluster..."
    ansible-playbook -i "$INVENTORY_FILE" kubernetes-single-node.yaml

    echo "Deployment complete!"

    echo "Deploying LLM-D..."
    ansible-playbook -i "$INVENTORY_FILE" llm-d-deploy.yaml

    echo "Testing LLM-D..."
    ansible-playbook -i "$INVENTORY_FILE" llm-d-test.yaml
    
    echo "Deploying OpenTelemetry Observability Stack..."
    ansible-playbook -i "$INVENTORY_FILE" otel-observability-setup.yaml

    echo ""
    echo "=== Instance Information ==="
    
    # Find the most recent instance details file
    DETAILS_FILE=$(ls -rt instance-*-details.txt | tail -1)
    
    if [ -n "$DETAILS_FILE" ]; then
        # Extract key information from the details file
        INSTANCE_ID=$(grep "Instance ID:" "$DETAILS_FILE" | cut -d' ' -f3)
        INSTANCE_NAME=$(grep "Instance Name:" "$DETAILS_FILE" | cut -d' ' -f3)
        PUBLIC_IP=$(grep "Public IP:" "$DETAILS_FILE" | cut -d' ' -f3)
        PRIVATE_IP=$(grep "Private IP:" "$DETAILS_FILE" | cut -d' ' -f3)
        INSTANCE_TYPE=$(grep "Instance Type:" "$DETAILS_FILE" | cut -d' ' -f3)
        SSH_COMMAND=$(grep "ssh -i" "$DETAILS_FILE")
        
        echo "Instance ID: $INSTANCE_ID"
        echo "Instance Name: $INSTANCE_NAME"
        echo "Instance Type: $INSTANCE_TYPE"
        echo "Public IP: $PUBLIC_IP"
        echo "Private IP: $PRIVATE_IP"
        echo ""
        echo "SSH Access:"
        echo "$SSH_COMMAND"
        echo ""
        echo "Full details saved to: $DETAILS_FILE"
    else
        echo "Warning: Could not find instance details file"
        echo "Check the instance details file for SSH access information."
    fi 
}

cleanup_instances() {
    echo "=== Cleaning up AWS GPU instances ==="

    # Check if there are any inventory files
    if ! ls gpu-inventory-*.ini 1> /dev/null 2>&1; then
        echo "No inventory files found. Nothing to cleanup."
        exit 0
    fi

    echo "Found inventory files. Running cleanup playbook..."
    ansible-playbook cleanup-instance.yaml

    echo "Cleanup complete!"
}

# Main script logic
case "${1:-}" in
    deploy)
        shift
        if [ $# -ne 0 ]; then
            echo "Deploy command doesn't accept additional arguments"
            usage
        fi
        deploy_cluster
        ;;
    cleanup)
        shift
        cleanup_instances "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        # Default behavior - deploy
        deploy_cluster
        ;;
    *)
        echo "Unknown command: $1"
        usage
        ;;
esac 