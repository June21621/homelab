terraform {
  required_version = "~> 1.16.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "= 6.13.0"
    }
  }
}

# 토큰은 GITHUB_TOKEN 환경 변수로 (scripts/tf-github.sh가 입력받는다). 파일에 두지 않는다
provider "github" {
  owner = "June21621"
}
