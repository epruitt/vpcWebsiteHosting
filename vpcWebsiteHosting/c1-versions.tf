terraform {
  required_version = ">=1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"

    }

    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }

  #Remote Backend
  backend "s3" {
    bucket       = "tfstate-dev-us-east-2-x6n4tn"
    key          = "websiteHosting/dev/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true

  }

}



provider "aws" {
  region = var.aws_region
}# trigger
# retest
