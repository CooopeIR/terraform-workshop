# Specifies the required Terraform providers and version constraints
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}

# Configures the AWS provider and sets the region for deployment
provider "aws" {
  region = "us-east-1"
}

# Provides resource to create an EC2 instance
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

# Uses the default vpc from AWS account
# # data "aws_vpc" "default" {
# #   default = true
# # }

# Creates a Virtual Private Cloud (VPC) to host network resources
resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "vpc_tf_workshop" # Tag to identify the VPC
  }
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "Allow HTTP and SSH inbound traffic"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "allow_http"
  }
}

resource "aws_vpc_security_group_ingress_rule" "allow_http_ipv4" {
  security_group_id = aws_security_group.allow_http.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ipv4" {
  security_group_id = aws_security_group.allow_http.id
  cidr_ipv4         = aws_vpc.main.cidr_block
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "allow_all_traffic_ipv4" {
  security_group_id = aws_security_group.allow_http.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}


# Creates an internet gateway to allow internet access for resources in the VPC
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "igw_tf_workshop"
  }
}

# Creates a route table for managing routes in the VPC
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "rt_tf_workshop"
  }
}

# Creates a subnet within the VPC
resource "aws_subnet" "public_a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24" # Subnet in the VPC

  availability_zone = "us-east-1a" # Choose an availability zone in your region

  map_public_ip_on_launch = true # Automatically assigns a public IP to instances

  tags = {
    Name = "subnet_tf_workshop_a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24" # Subnet in the VPC

  availability_zone = "us-east-1b" # Choose an availability zone in your region

  map_public_ip_on_launch = true # Automatically assigns a public IP to instances

  tags = {
    Name = "subnet_tf_workshop_b"
  }
}

resource "aws_route_table_association" "subnet_a_association" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "subnet_b_association" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_lb_target_group" "apache_target_group" {
  name     = "apache-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path     = "/"
    port     = "80"
    protocol = "HTTP"
  }

  tags = {
    Name = "apache_target_group"
  }
}

resource "aws_lb_target_group_attachment" "apache_target_group_attachment" {
  count            = length(aws_instance.apache_web_server)
  target_group_arn = aws_lb_target_group.apache_target_group.arn
  target_id        = aws_instance.apache_web_server[count.index].id
  port             = 80
}

resource "aws_lb" "apache_load_balancer" {
  name               = "apache-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_http.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "apache_load_balancer"
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.apache_load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.apache_target_group.arn
  }
}

# Provisions aws EC2 instance using ubuntu AWS_AMI data
resource "aws_instance" "apache_web_server" {
  count                       = 2 # Number of instances to create
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.micro"
  associate_public_ip_address = true
  subnet_id                   = element([aws_subnet.public_a.id, aws_subnet.public_b.id], count.index)
  vpc_security_group_ids      = [aws_security_group.allow_http.id]
  user_data                   = <<-EOF
        #!/bin/bash
        sudo apt-get update
        sudo apt-get install -y apache2
        sudo systemctl start apache2
        sudo systemctl enable apache2
        echo "<h1>Hello World</h1>" | sudo tee /var/www/html/index.html
    EOF

  tags = {
    Name = "apache_web_server_${count.index + 1}"
  }
}

# Print the instances DNS address
output "instance_public_dns" {
  description = "The public DNS address of the EC2 instance."
  value       = [for instance in aws_instance.apache_web_server : instance.public_dns]
}

# Print the instances public IP-address
output "instance_public_ip" {
  description = "The public IP address of the EC2 instance."
  value       = [for instance in aws_instance.apache_web_server : instance.public_ip]
}

# # Output the Elastic IP (EIP) of the instance
# output "elastic_ip" {
#   description = "The Elastic IP attached to the EC2 instance."
#   value       = aws_eip.main.public_ip
# }

output "load_balancer_dns" {
  description = "The DNS address of the load balancer."
  value       = aws_lb.apache_load_balancer.dns_name
}
