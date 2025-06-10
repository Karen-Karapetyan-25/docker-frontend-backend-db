terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "eu-central-1"
}


# ----- IAM role allowing EC2 to pull from ECR (read‑only) -----
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
}

resource "aws_iam_role_policy_attachment" "attach_ecr_readonly" {
  role       = aws_iam_role.ec2_ecr_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-ecr-readonly-profile"
  role = aws_iam_role.ec2_ecr_readonly.name
}

# ----- Latest Amazon Linux 2023 AMI (x86_64) -----
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ----- EC2 instance -----
resource "aws_instance" "app_host" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t2.micro"
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "app-host"
  }
}
