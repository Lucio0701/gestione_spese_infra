terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- ECR Repositories ---
resource "aws_ecr_repository" "backend_repo" {
  name                 = "gestione-spese-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_repository" "frontend_repo" {
  name                 = "gestione-spese-frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# --- Security Group for EC2 ---
resource "aws_security_group" "ec2_sg" {
  name        = "gestione-spese-ec2-sg"
  description = "Allow SSH, HTTP, HTTPS, and App ports"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Backend API (internal, proxied through nginx)
  ingress {
    description = "Backend API"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "gestione-spese-sg"
  }
}

# --- SSH Key Pair ---
resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "kp" {
  key_name   = "gestione-spese-key"
  public_key = tls_private_key.pk.public_key_openssh
}

resource "local_file" "ssh_key" {
  content         = tls_private_key.pk.private_key_pem
  filename        = "${path.module}/gestione-spese-key.pem"
  file_permission = "0400"
}

# --- AMI for ARM (t4g instances) ---
data "aws_ami" "amazon_linux_2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# --- EBS Volume for PostgreSQL Data ---
resource "aws_ebs_volume" "postgres_data" {
  availability_zone = "${var.aws_region}a"
  size              = 10 # GB - sufficient for small app
  type              = "gp3"
  iops              = 3000 # gp3 baseline
  throughput        = 125  # MB/s gp3 baseline

  tags = {
    Name = "gestione-spese-postgres-data"
  }
}

# --- EC2 Instance (ARM-based for cost savings) ---
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux_2023_arm.id
  instance_type          = "t4g.micro" # ARM instance: 2 vCPU, 1GB RAM (~$6/month)
  key_name               = aws_key_pair.kp.key_name
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  availability_zone      = "${var.aws_region}a"

  # IAM Instance Profile to allow EC2 to pull from ECR
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # Root volume (OS)
  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e

              # Update system
              dnf update -y

              # Install Docker
              dnf install -y docker git
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user

              # Install Docker Compose v2
              mkdir -p /usr/local/lib/docker/cli-plugins
              curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64" \
                -o /usr/local/lib/docker/cli-plugins/docker-compose
              chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
              ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

              # Format and mount EBS volume for PostgreSQL data
              # Wait for volume to be attached
              while [ ! -e /dev/nvme1n1 ] && [ ! -e /dev/xvdf ]; do
                echo "Waiting for EBS volume..."
                sleep 5
              done

              # Determine device name
              if [ -e /dev/nvme1n1 ]; then
                DEVICE=/dev/nvme1n1
              else
                DEVICE=/dev/xvdf
              fi

              # Check if volume needs formatting
              if ! blkid $DEVICE; then
                mkfs.ext4 $DEVICE
              fi

              # Create mount point and mount
              mkdir -p /data/postgres
              echo "$DEVICE /data/postgres ext4 defaults,nofail 0 2" >> /etc/fstab
              mount -a
              chown 999:999 /data/postgres  # PostgreSQL user in container

              # Create app directory
              mkdir -p /home/ec2-user/app
              chown ec2-user:ec2-user /home/ec2-user/app

              echo "Setup complete!" > /home/ec2-user/setup-complete.txt
              EOF

  tags = {
    Name = "GestioneSpeseServer"
  }
}

# --- Attach EBS Volume to EC2 ---
resource "aws_volume_attachment" "postgres_data_att" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.postgres_data.id
  instance_id = aws_instance.app_server.id
}

# --- IAM Role for EC2 ---
resource "aws_iam_role" "ec2_role" {
  name = "gestione_spese_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "gestione_spese_bedrock_invoke"
  role = aws_iam_role.ec2_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
          "aws-marketplace:Unsubscribe"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:708175750893:inference-profile/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "gestione_spese_ec2_profile"
  role = aws_iam_role.ec2_role.name
}

# --- Elastic IP ---
resource "aws_eip" "lb" {
  instance = aws_instance.app_server.id
  domain   = "vpc"

  tags = {
    Name = "gestione-spese-eip"
  }
}
