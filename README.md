# AWS Kubernetes Ansible Provisioner

## Description

AWS Kubernetes Ansible Provisioner launches an AWS instance, and then installs
Kubernetes and llm-d on the instance with one command.

## Setup Instructions

### 1. Get AWS credentials and `router-team-us-east2.pem` file from a team member.

### 2. Create AWS Credentials File

Create a file at `~/.aws/credentials` with the following content:

```ini
[default]
aws_access_key_id = <aws_access_key_id>
aws_secret_access_key = <aws_secret_access_key>
```

### 3. Set Up SSH Key

Save `router-team-us-east2.pem` in your `~/.ssh/` directory and run:

```bash
chmod 400 ~/.ssh/router-team-us-east2.pem
```

### 4. Create Hugging Face Token File

1. Get your token from: [https://huggingface.co/docs/hub/en/security-tokens](https://huggingface.co/docs/hub/en/security-tokens)
2. Save it to:

```bash
mkdir -p ~/.cache/huggingface
echo "<your_token>" > ~/.cache/huggingface/token
```

### 5. Install Ansible

## Usage

### 1. Run Deployment Script

From the project directory, run:

```bash
./deploy-k8s-cluster.sh deploy
```

### 2. Get Public IP Address

Look for a log like the following:

```
Instance launched successfully!
Instance ID: i-xxxxxxxxxxxxxxxxx
Public IP: xxx.xxx.xxx.xxx
```

or get info from the `instance-*-details.txt` file that gets created.

### 3. SSH Into the Instance

Use the public IP:

```bash
ssh -i ~/.ssh/router-team-us-east2.pem ubuntu@xxx.xxx.xxx.xxx
```

## Cleanup Resources

When done, don't forget to delete your instance -- it costs $'s.

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
