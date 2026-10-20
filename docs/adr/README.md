# ADR (Architecture Decision Records)

설계 결정과 그 이유를 한 장씩 남긴다. 형식: 상태 / 맥락 / 결정 / 검토한 대안 / 결과(트레이드오프).
결정을 뒤집을 때는 기존 ADR을 지우지 않고 상태를 "대체됨(NNNN)"으로 바꾼 뒤 새 ADR을 쓴다.

| 번호 | 제목 | 상태 |
|---|---|---|
| [0001](0001-exclude-personal-pc-cluster.md) | 개인 PC 워크로드 클러스터를 범위에서 제외 | 채택 |
| [0002](0002-no-loki-memory-budget.md) | 로그 스택(Loki) 미도입, 기반 컴포넌트 메모리 4GB 예산 | 채택 |
| [0003](0003-secrets-sops-age.md) | 시크릿 관리는 SOPS + age | 채택 |
| [0004](0004-tailscale-acl-for-admin-access.md) | 관리 접근의 포트 제한은 ufw가 아니라 Tailscale ACL로 | 채택 |
