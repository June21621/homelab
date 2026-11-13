# ADR (Architecture Decision Records)

설계 결정과 그 이유를 한 장씩 남긴다. 형식: 상태 / 맥락 / 결정 / 검토한 대안 / 결과(트레이드오프).
결정을 뒤집을 때는 기존 ADR을 지우지 않고 상태를 "대체됨(NNNN)"으로 바꾼 뒤 새 ADR을 쓴다.

| 번호 | 제목 | 상태 |
|---|---|---|
| [0001](0001-exclude-personal-pc-cluster.md) | 개인 PC 워크로드 클러스터를 범위에서 제외 | 채택 |
| [0002](0002-no-loki-memory-budget.md) | 로그 스택(Loki) 미도입, 기반 컴포넌트 메모리 4GB 예산 | 채택 |
| [0003](0003-secrets-sops-age.md) | 시크릿 관리는 SOPS + age | 채택 |
| [0004](0004-tailscale-acl-for-admin-access.md) | 관리 접근의 포트 제한은 ufw가 아니라 Tailscale ACL로 | 채택 |
| [0005](0005-ci-github-actions.md) | CI는 GitHub Actions 호스티드 러너 + homelab의 재사용 워크플로 | 채택 |
| [0006](0006-pull-based-deploy.md) | 배포는 CI가 밀어 넣지 않고 클러스터 안 ArgoCD가 가져간다 | 채택 |
| [0007](0007-gitops-location-and-tag-path.md) | gitops는 homelab 안에, 배포 태그는 봇 PR + 검사 통과 시 자동 병합 | 채택 |
| [0008](0008-ksops-cluster-age-key.md) | 클러스터 시크릿은 KSOPS + 클러스터 전용 age 키 | 채택 |
| [0009](0009-argocd-self-management.md) | ArgoCD는 Terraform으로 한 번 설치하고, 이후엔 자기 자신을 Git으로 관리 | 채택 |
