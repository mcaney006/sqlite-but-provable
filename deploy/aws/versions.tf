terraform {
  # 1.11 for write-only arguments and ephemeral resources: the generated
  # token is never written to the plan or the state.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.73, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.9, < 4.0"
    }
  }
}
