variable "kubeconfig_path" {
  description = "관리 PC의 kubeconfig (make kubeconfig로 만든 파일)"
  type        = string
  default     = "~/.kube/homelab.yaml"
}

variable "kube_context" {
  description = "kubeconfig 안의 context 이름"
  type        = string
  default     = "homelab"
}

variable "cluster_age_key_path" {
  description = "클러스터 전용 age 개인키 파일 (repo 밖, 백업은 Bitwarden \"homelab-cluster-age\")"
  type        = string
  default     = "~/.config/sops/age/homelab-cluster.txt"
}
