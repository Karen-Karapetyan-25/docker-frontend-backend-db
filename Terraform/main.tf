########################################################################
# Terraform Configuration
########################################################################
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

########################################################################
# Providers
########################################################################
provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      Environment = "production"
      Terraform   = "true"
    }
  }
}

########################################################################
# Data Sources
########################################################################
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

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

data "http" "github_ips" {
  url = "https://api.github.com/meta"
}

########################################################################
# Locals
########################################################################
locals {
  # Filter GitHub IPs to only include IPv4 addresses
  github_ips_v4 = try([
    for ip in flatten(jsondecode(data.http.github_ips.body).actions) : 
    ip if can(regex("^\\d+\\.", ip)) # Matches IPv4 addresses only
  ], ["0.0.0.0/0"]) # Fallback if API call fails
}

########################################################################
# IAM Resources
########################################################################
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

  tags = {
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


########################################################################
# Networking - Consolidated Security Group Rules
########################################################################
resource "aws_security_group" "app_sg" {
  name        = "app-security-group"
  description = "Controls access to the application"
  vpc_id      = data.aws_vpc.default.id

  # Single combined ingress rule for HTTP/HTTPS
  ingress {
    description = "Web access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Single consolidated SSH rule for GitHub IPs
  ingress {
    description = "SSH from GitHub Actions"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.github_ips_aggregated # Uses aggregated CIDRs
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-security-group"
  }
}

locals {
  # Aggregate GitHub IPs into larger CIDR blocks where possible
  github_ips_aggregated = try([
    for ip in flatten(jsondecode(data.http.github_ips.body).actions) : 
    ip if can(regex("^\\d+\\.", ip)) && !can(regex("^52\\.", ip)) # Filter IPv4 and exclude AWS regions
  ], ["0.0.0.0/0"])
}



########################################################################
# EC2 Instance
########################################################################
resource "aws_instance" "app_host" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t2.micro"
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  subnet_id              = data.aws_subnets.default.ids[0] # Use first subnet in default VPC
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "app-host"
  }
}

########################################################################
# Outputs
########################################################################
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