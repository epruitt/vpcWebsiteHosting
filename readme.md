# Secure Web Hosting Infrastructure

A multi-phase secure web hosting infrastructure on AWS, built with Terraform and organized as a root module with a VPC child module. The project hosts the Omnifood static website and includes security, infrastructure-as-code, observability, and CI/CD as first-class concerns.

## Project Structure

```
vpcWebsiteHosting/
├── c1-versions.tf          # Terraform + provider config, S3 remote backend
├── c2-variables.tf         # Root-level variables
├── c3-vpc.tf                # Calls the vpc module
├── c4-outputs.tf            # Root-level outputs
├── c5-private-ec2.tf         # Private EC2 instance + ALB target group attachment
├── c6-monitoring.tf          # CloudWatch alarms, SNS, dashboard
├── c7-github-oidc.tf         # GitHub Actions OIDC provider, deploy/plan IAM roles
├── agent-config.json         # CloudWatch Agent configuration
└── modules/
    └── vpc/
        ├── main.tf                    # VPC, subnets, NAT, security groups
        ├── alb.tf                     # Application Load Balancer
        ├── ec2-iam-role.tf            # Least-privilege IAM role for EC2
        ├── s3-website-assets.tf       # S3 bucket for static assets
        ├── website-content.tf         # Uploads website files to S3
        ├── datasources-and-locals.tf  # AZ discovery, subnet CIDR calculation
        ├── variables.tf               # Module input variables
        ├── outputs.tf                 # Module outputs
        └── website/                   # Static site source files (HTML/CSS/JS)
```

## Region

All infrastructure is deployed to `us-east-2`.

## Roadmap

### Phase 1 — Secure Private Web Hosting
- EC2 instance in a private subnet, with no public IP and no SSH access
- Traffic reaches the instance only through an Application Load Balancer
- Static website assets sourced from S3 and synced onto the instance at boot
- Least-privilege IAM role scoped to the specific S3 bucket
- Access for operators via AWS Systems Manager (SSM) Session Manager only
- IMDSv2 enforced, root EBS volume encrypted

### Phase 2 — Observability
- CloudWatch Agent installed on the EC2 instance for custom OS-level metrics (memory, disk)
- CloudWatch alarms covering EC2 status checks, CPU, memory, disk, and ALB health/errors
- SNS topic with email subscription for real-time alerting
- Consolidated CloudWatch dashboard for EC2 and ALB performance


### Phase 3 — CI/CD (in progress)
- ✅ GitHub OIDC provider and IAM roles implemented (`c7-github-oidc.tf`): separate least-privilege roles for read-only PR plans vs. production deploys, trust policies scoped to specific repo/branch/environment claims
- ✅  GitHub Actions workflow files (`terraform-pr-check.yml`, `terraform-deploy.yml`) 
- ⬜ `production` GitHub Environment with manual approval gate not yet configured
- ⬜ Post-deploy smoke-test job not yet implemented
- ⬜ Git-tag-based rollback (`last-known-good`) not yet implemented; S3 state versioning is available as a safety net

## Validation Approach

All infrastructure validation is done via the AWS CLI and SSM Session Manager — no browser or AWS Console steps required. Typical checks include `terraform plan`/`apply`, `curl` against the ALB DNS name, and `aws ssm start-session` for on-instance diagnostics (e.g. `/var/log/user-data.log`, `systemctl status nginx`).

## Status

Phases 1 and 2 are implemented and Phase 3's IAM/OIDC foundation is in place, but the GitHub Actions workflow files, approval gate, and rollback mechanism are still pending. 

---
*This README is a temporary working draft and will be revised as the project progresses.*