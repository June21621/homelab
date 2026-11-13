# 0009. ArgoCD는 Terraform으로 한 번 설치하고, 이후엔 자기 자신을 Git으로 관리

- 상태: 채택 (2026-11-02)

## 맥락

ArgoCD는 클러스터 안의 모든 것을 Git으로 관리하지만, ArgoCD 자신은 처음에 누군가 설치해야 한다(닭과 달걀).
설치 후 업그레이드·설정 변경을 어떻게 할지도 정해야 한다. 흔한 실패는 **첫 설치용 values와 이후 운영용 values가 따로 있어
서로 어긋나는 것**이다. 목표는 "OS 설치 + seed 이후 명령 하나로 재구축"이다.

## 결정

- `terraform/argocd-bootstrap/`이 딱 한 번 설치한다
  - `helm_release.argocd`: argo-cd 차트(버전 고정). values는 **Git의 `gitops/platform/argocd/values.yaml` 한 벌**을 `file()`로 읽는다
  - `kubernetes_secret_v1.sops_age`: 클러스터 age 키(ADR 0008)
  - `helm_release.root_app`: 루트 Application(로컬 차트 `root-app-chart`, `gitops/root/` 감시)
  - 두 `helm_release`는 `lifecycle { ignore_changes = all }`. 설치 뒤 Terraform은 ArgoCD 차트·루트 앱을 건드리지 않는다
    (네임스페이스와 age 키 Secret은 Terraform이 계속 관리한다. 키 교체는 Terraform으로 한다)
- 루트 앱이 관리하는 목록(`gitops/root/argocd.yaml`)에 **ArgoCD 자신**이 들어 있다. 이후 업그레이드·설정 변경은
  차트 버전·values를 바꾸는 PR로 한다
- 쓰지 않는 컴포넌트는 끈다: dex, notifications. applicationset은 차트에 끄는 옵션이 없어 replicas 0
- **argocd·root 앱에는 삭제 finalizer를 달지 않는다.** 서비스 앱은 반드시 단다. 렌더 검사(`check_rendered.py`의 `check_apps`)가 두 규칙을 강제한다
- 웹 UI는 외부에 노출하지 않는다. 관리 PC에서 `kubectl port-forward`로만 접속

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| Terraform이 ArgoCD를 계속 관리 | 업그레이드도 `terraform apply` 한 번 | 변경 경로가 Git PR과 Terraform 둘로 갈림. ArgoCD self-heal과 Terraform이 같은 리소스를 두고 다툼 |
| 처음부터 `kubectl apply`/`helm install` 수동 설치 | Terraform 불필요 | 재구축이 명령 하나가 안 됨. 무엇을 어떤 값으로 설치했는지 기록이 흩어짐 |
| 루트 앱을 argo-cd 차트의 `extraObjects`로 | 릴리스 하나로 끝 | 빈 클러스터의 첫 `helm install` 시점엔 Application CRD가 아직 없어 실패 |
| ArgoCD 자신은 Git 관리 밖에 두기 | 자기 업그레이드 실패 위험 없음 | 업그레이드 때마다 수동 작업. "사람이 `helm` 하는 경로"가 남음 |

## 결과

- values가 한 벌이라 첫 설치와 이후 운영이 어긋날 수 없다. 설치 직후 ArgoCD가 자기 앱을 Synced로 잡았고 Terraform 재 plan은 No changes였다
  - 정정: argocd 앱 기록의 첫 항목은 생성 3초 뒤 **자동 동기화 1회**였다. "Terraform 설치본과 Git이 처음부터 완전히 같았다"는 근거로는 부족하고,
    추적 정보(annotation) 인수인계로 추정하지만 확인하지 못했다
- 기반 메모리: ArgoCD 합계 약 0.3GiB(controller 228Mi, server 45Mi, repo-server 33Mi, redis 5Mi, 2026-11-02)
- finalizer 규칙의 이유
  - 서비스 앱: finalizer가 없으면 `gitops/root/`에서 앱을 지워도 Application만 사라지고 Deployment·Secret·Namespace가 고아로 남는다(ksops-test 정리 때 확인).
    finalizer는 클러스터의 객체에 붙어 있어야 동작하므로, **finalizer 추가 PR이 반영된 뒤에** 삭제 PR을 낸다.
    `CreateNamespace`로 만든 Namespace는 앱 리소스가 아니라 남으므로 Namespace를 매니페스트로 넣는다
  - argocd·root 앱: finalizer가 있으면 실수로 지웠을 때 **ArgoCD 자신과 모든 앱이 연쇄 삭제**된다. 없으면 Application 객체만 사라지고 돌던 것은 남는다
- **비상 복구**: ArgoCD 자기 업그레이드가 실패해 스스로 못 고치면
  1. 원인이 Git 변경이면 먼저 `git revert`(main 보호 때문에 PR로)
  2. 그래도 안 되면 관리 PC에서 `terraform apply -replace=helm_release.argocd`로 Git의 values 그대로 재설치
  - 9단계 장애 검증에서 실제로 해 본다
- ArgoCD 차트 업그레이드는 ArgoCD가 자기 자신을 재시작하며 적용한다. 그 사이 다른 앱 동기화가 잠시 멈춘다
