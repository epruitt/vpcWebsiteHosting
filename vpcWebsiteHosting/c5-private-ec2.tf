# This data source retrieves the latest Amazon Linux 2 AMI ID for use in EC2 instances.
data "aws_ami" "latest_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "private_ec2" {
  ami                    = data.aws_ami.latest_amazon_linux.id
  instance_type          = "t2.micro"
  subnet_id              = element(module.vpc.private_subnet_ids, 0)
  vpc_security_group_ids = [module.vpc.ec2_security_group_id]
  iam_instance_profile = module.vpc.iam_instance_profile_name

  depends_on = [module.vpc]

user_data = <<-EOF
              #!/bin/bash
              set -uo pipefail

              # Log everything to a dedicated file in addition to cloud-init-output.log
              exec > >(tee /var/log/user-data.log) 2>&1

              echo "=== Starting bootstrap: $(date) ==="

              # Update packages
              yum update -y

              # Install Web Server (nginx)
              amazon-linux-extras install -y nginx1

              # Start nginx immediately with whatever default content exists,
              # so the ALB health check has something to hit even if the
              # S3 sync below has a transient failure.
              systemctl enable nginx
              systemctl start nginx
              echo "nginx started: $(systemctl is-active nginx)"

              # Install AWS CLI (usually preinstalled, ensuring latest)
              yum install -y awscli

              # Sync S3 content with retries.
              # IAM instance-profile credentials can take a few seconds to
              # become available via IMDS right after launch, so a single
              # attempt can fail here even though the role is correctly attached.
              echo "Syncing website content from S3..."
              max_attempts=5
              attempt=1
              until aws s3 sync s3://"${module.vpc.omnifood_website_bucket_name}"/ /usr/share/nginx/html/; do
                if [ $attempt -ge $max_attempts ]; then
                  echo "WARNING: S3 sync failed after $max_attempts attempts. Continuing with nginx default page."
                  break
                fi
                echo "S3 sync attempt $attempt failed, retrying in 10s..."
                attempt=$((attempt + 1))
                sleep 10
              done

              # Reload nginx in case new content was synced in
              systemctl reload nginx || systemctl restart nginx

              # Install CloudWatch Agent
              yum install -y amazon-cloudwatch-agent

              # Fetch config from SSM and start the agent.
              # Don't let a failure here take down the rest of the script -
              # nginx is already serving traffic at this point regardless.
              if ! /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
                -a fetch-config \
                -m ec2 \
                -c ssm:${aws_ssm_parameter.cloudwatch_agent_config.name} \
                -s; then
                echo "WARNING: CloudWatch Agent failed to start. Check SSM parameter and IAM policy."
              fi

              # Verify status (optional, checks logs)
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

              echo "=== Bootstrap finished: $(date) ==="
              EOF

  tags = {
    Name        = "${var.environment_name}-private-ec2"
    Environment = var.environment_name
  }

  # Enable IMDSv2 and require tokens for metadata access
  metadata_options {
    http_tokens = "required"
  }

  # Enable EBS encryption for the root volume
  root_block_device{
    encrypted = true
  }
}

resource "aws_lb_target_group_attachment" "web_server" {
  target_group_arn = module.vpc.alb_target_group_arn
  target_id        = aws_instance.private_ec2.id
  port             = 80

}