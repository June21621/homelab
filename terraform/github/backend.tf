terraform {
  backend "s3" {
    bucket       = "june21621-homelab-tfstate"
    key          = "github/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "homelab-tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
