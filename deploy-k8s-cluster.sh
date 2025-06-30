#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [deploy|cleanup] [options]"
    echo ""
    echo "Commands:"
    echo "  deploy              Deploy a new K8s cluster on AWS GPU instance"
    echo "  cleanup             Cleanup AWS instances found in inventory files"
    echo ""
    echo "Deploy Options:"
    echo "  --disable-auto-shutdown         Disable the auto-shutdown feature (default: enabled)"
    echo "  --idle-timeout MINUTES          Set auto-shutdown idle timeout in minutes (default: 60)"
    echo ""
    echo "Examples:"
    echo "  $0 deploy                                    # Deploy with auto-shutdown enabled, 60min timeout"
    echo "  $0 deploy --disable-auto-shutdown            # Deploy with auto-shutdown disabled"
    echo "  $0 deploy --idle-timeout 30                  # Deploy with 30-minute timeout"
    echo "  $0 deploy --disable-auto-shutdown --idle-timeout 120  # Multiple options"
    exit 1
}

# Function to deploy cluster
deploy_cluster() {
    local auto_shutdown_enabled="true"
    local auto_shutdown_idle_time_minutes="60"
    
    # Parse arguments for deploy command
    while [[ $# -gt 0 ]]; do
        case $1 in
            --disable-auto-shutdown)
                auto_shutdown_enabled="false"
                shift
                ;;
            --idle-timeout)
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    auto_shutdown_idle_time_minutes="$2"
                    shift 2
                else
                    echo "Error: --idle-timeout requires a numeric value"
                    usage
                fi
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    echo "=== Deploying K8s Cluster on AWS GPU Instance ==="
    echo "Auto-shutdown enabled: $auto_shutdown_enabled"
    if [[ "$auto_shutdown_enabled" == "true" ]]; then
        echo "Auto-shutdown idle timeout: $auto_shutdown_idle_time_minutes minutes"
    fi

    echo "Launching AWS GPU instance..."
    ansible-playbook launch-instance.yaml \
        -e "auto_shutdown_enabled=$auto_shutdown_enabled" \
        -e "auto_shutdown_idle_time_minutes=$auto_shutdown_idle_time_minutes"

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
        echo ""
        echo "=== Access Services ==="
        echo "To access Grafana, Prometheus, and LLM-D services locally:"
        echo "  ./port-forward-services.sh start"
        echo ""
        echo "After running the above command, you can access:"
        echo "  Grafana:    http://127.0.0.1:3000 (admin/admin)"
        echo "  Prometheus: http://127.0.0.1:9090"
        echo "  LLM-D:      http://127.0.0.1:8080"
        echo ""
        echo "To stop port forwarding: ./port-forward-services.sh stop"
        echo "To check status:        ./port-forward-services.sh status"
    else
        echo "Warning: Could not find instance details file"
        echo "Check the instance details file for SSH access information."
        echo ""
        echo "=== Access Services ==="
        echo "To access Grafana, Prometheus, and LLM-D services locally:"
        echo "  ./port-forward-services.sh start"
        echo ""
        echo "After running the above command, you can access:"
        echo "  Grafana:    http://127.0.0.1:3000 (admin/admin)"
        echo "  Prometheus: http://127.0.0.1:9090"
        echo "  LLM-D:      http://127.0.0.1:8080"
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
        deploy_cluster "$@"
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