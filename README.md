# AWS Kubernetes Ansible Provisioner

Make sure the ssh key is added to the AWS account. We use the key `router-team-us-east2.pem` for the instance.

## Deploy a New Cluster

```bash
./deploy-k8s-cluster.sh deploy
```

## Cleanup Resources

```bash
./deploy-k8s-cluster.sh cleanup
```

## Auto-Shutdown Feature

The deployment includes an auto-shutdown service that monitors instance activity and automatically stops the instance when idle to save costs.

### How it works:
- Monitors SSH connections, system load, network activity, GPU utilization, and Kubernetes workloads
- Default idle time: 60 minutes (configurable)
- Checks every 5 minutes (configurable)
- Automatically shuts down the instance when all criteria indicate inactivity

### Managing Auto-Shutdown:
```bash
# Check status
sudo /usr/local/bin/auto-shutdown.sh status

# Disable temporarily (until reboot)
sudo /usr/local/bin/auto-shutdown.sh disable

# Re-enable
sudo /usr/local/bin/auto-shutdown.sh enable

# View activity logs
sudo tail -f /var/log/auto-shutdown.log

# Stop the service
sudo systemctl stop auto-shutdown

# Start the service
sudo systemctl start auto-shutdown
```

### Customizing Settings:
Edit `/etc/systemd/system/auto-shutdown.service` to change:
- `IDLE_TIME_MINUTES` - Minutes of inactivity before shutdown
- `CHECK_INTERVAL_MINUTES` - How often to check for activity

After changes, restart the service:
```bash
sudo systemctl daemon-reload
sudo systemctl restart auto-shutdown
```

## Configuration

### AWS Settings (in launch-instance.yaml)
- **Region**: us-east-2
- **Instance Type**: g6.4xlarge (1 L4 GPU)
- **AMI**: Ubuntu 22.04 with NVIDIA drivers
- **Storage**: 500GB GP3 EBS volume
- **SSH Key**: router-team-us-east2.pem
- **Security Group**: Pre-existing security group with ports 22, 6443, 10250 - 10259, 2379 - 2380 open.

### Kubernetes Settings (in kubernetes-single-node.yaml)
- **Runtime**: CRI-O 1.33
- **Version**: Kubernetes 1.33
- **CNI**: Flannel
- **Storage**: Local Path Provisioner

### LLM-D Settings
- **Model**: Qwen/Qwen3-0.6B
- **Storage**: Local Path Provisioner
- **HuggingFace Token**: Add to ~/.cache/huggingface/token

### SSH Connection
```bash
ssh -i ~/.ssh/router-team-us-east2.pem ubuntu@<instance-ip>
```
