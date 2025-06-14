terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket  = "kkarapetyans-bucket"
    region  = "eu-west-1"
    key     = "terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}


provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      Environment = "production"
      Terraform   = "true"
    }
  }
}


data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


data "aws_vpc" "default" { 
  default = true 
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}


data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}


resource "aws_iam_role" "ec2_ecr_readonly" {
  name               = "ec2-ecr-readonly-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "Allows EC2 instances to pull images from ECR"
  tags               = { 
    Service = "ecr-readonly" 
  }
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2_ecr_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-ecr-readonly-profile"
  role = aws_iam_role.ec2_ecr_readonly.name
}


data "aws_ec2_managed_prefix_list" "github_actions" {
  # this is the AWS-provided list of all GitHub Actions IPv4 CIDRs
  name = "com.amazonaws.global.cloudprefixlist/github-ipv4"
}


# Fetch GitHub Actions IP ranges
data "http" "github_meta" {
  url = "https://api.github.com/meta"
}

# Parse only the IPv4 CIDRs out of the “actions” list
locals {
  github_actions_ipv4 = try([
    for cidr in jsondecode(data.http.github_meta.response_body).actions :
    cidr if can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+\\/\\d+$", cidr))
  ], ["0.0.0.0/0"])
}

# Your security group now dynamically creates one SSH rule per CIDR
resource "aws_security_group" "app_sg" {
  name        = "app-sg"
  description = "Allow SSH from GitHub Actions & HTTP from anywhere"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = local.github_actions_ipv4
    content {
      description = "SSH from GitHub Actions"
      protocol    = "tcp"
      from_port   = 22
      to_port     = 22
      cidr_blocks = [ingress.value]
    }
  }

  # Static HTTP rule
  ingress {
    description = "HTTP from anywhere"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound
  egress {
    description = "All outbound"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-sg"
  }
}



resource "aws_instance" "app_host" {
  ami                         = data.aws_ami.ubuntu_22_04.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = "app-host" }
}


output "ec2_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.app_host.public_ip
}

output "ec2_instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.app_host.id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.app_sg.id
}
