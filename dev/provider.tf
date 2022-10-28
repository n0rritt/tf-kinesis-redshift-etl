provider "aws" {
  region = "eu-central-1"
  assume_role {
    role_arn = "arn:aws:iam::${var.aws_account_id}:role/terraform"
  }
}

