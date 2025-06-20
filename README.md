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
