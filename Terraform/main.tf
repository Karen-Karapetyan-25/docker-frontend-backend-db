########################################################################
# Terraform state backend
########################################################################
terraform {
  backend "s3" {
    bucket = "kkarapetyans-bucket"
    region = "eu-west-1"
    key    = "terraform.tfstate"   # ← the “some key” it needs
  }
}

########################################################################
# Providers
########################################################################
provider "aws" {
  region = "eu-west-1"
}

########################################################################
# IAM — allow the EC2 instance to pull from ECR (read-only)
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
}

resource "aws_iam_role_policy_attachment" "attach_ecr_readonly" {
  role       = aws_iam_role.ec2_ecr_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-ecr-readonly-profile"
  role = aws_iam_role.ec2_ecr_readonly.name
}

########################################################################
# AMI lookup — latest Ubuntu 22.04 LTS (Jammy) x86-64 for eu-west-1
########################################################################
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical

  filter { name = "name"                values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "architecture"        values = ["x86_64"] }
  filter { name = "virtualization-type" values = ["hvm"] }
}

########################################################################
# EC2 instance
########################################################################
resource "aws_instance" "app_host" {
  ami                  = data.aws_ami.ubuntu_22_04.id
  instance_type        = "t2.micro"
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "app-host"
  }
}
