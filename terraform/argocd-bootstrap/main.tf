# ArgoCD 첫 설치. 설치가 끝나면 ArgoCD가 gitops/root/의 Application으로 자기 자신을 관리하므로
# Terraform은 이후 ArgoCD를 건드리지 않는다(ignore_changes = all). (설계 §3.2, ADR 0009)
#
# 비상 복구(ArgoCD가 스스로 못 고칠 때): 원인이 Git이면 먼저 git revert, 그다음
#   terraform apply -replace=helm_release.argocd

locals {
  # 차트 버전·values·루트 앱 정의는 gitops/에 한 벌만 두고 여기서 읽는다
  argocd_app    = yamldecode(file("${path.module}/../../gitops/root/argocd.yaml"))
  argocd_chart  = one([for s in local.argocd_app.spec.sources : s if try(s.chart, "") == "argo-cd"])
  argocd_values = file("${path.module}/../../gitops/platform/argocd/values.yaml")
  root_app      = yamldecode(file("${path.module}/../../gitops/root/root.yaml"))
}

provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig_path)
    config_context = var.kube_context
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# KSOPS(5-2)가 gitops/의 SOPS 파일을 풀 때 쓰는 클러스터 전용 age 키.
# ArgoCD가 Git을 읽기 전에 있어야 하는 "부트스트랩 시크릿"이라 Git이 아니라 여기서 넣는다
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
  data = {
    "keys.txt" = file(pathexpand(var.cluster_age_key_path))
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false
  repository       = local.argocd_chart.repoURL
  chart            = local.argocd_chart.chart
  version          = local.argocd_chart.targetRevision
  values           = [local.argocd_values]
  wait             = true
  timeout          = 600

  depends_on = [kubernetes_secret_v1.sops_age]

  lifecycle {
    ignore_changes = all
  }
}

# 루트 앱은 Application CRD가 생긴 뒤에야 만들 수 있어서 argo-cd 차트와 따로 꽂는다.
# (같은 차트의 extraObjects에 넣으면 빈 클러스터 첫 설치에서 Helm이 Application 종류를 몰라 실패)
resource "helm_release" "root_app" {
  name      = "root-app"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  chart     = "${path.module}/root-app-chart"
  values    = [yamlencode({ root = local.root_app })]

  depends_on = [helm_release.argocd]

  lifecycle {
    ignore_changes = all
  }
}
