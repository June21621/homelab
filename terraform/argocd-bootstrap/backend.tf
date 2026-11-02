# state는 S3에 둔다. 클러스터 age 개인키(Secret 내용)가 state에 들어가므로
# 버킷의 암호화·퍼블릭 차단·SSO(MFA, 1시간 세션) 접근 제한에 의존한다. (설계 §3.3)
terraform {
  backend "s3" {
    bucket       = "june21621-homelab-tfstate"
    key          = "argocd-bootstrap/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "homelab-tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
