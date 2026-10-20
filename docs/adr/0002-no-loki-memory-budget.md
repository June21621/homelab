# 0002. 로그 스택(Loki) 미도입, 기반 컴포넌트 메모리 4GB 예산

- 상태: 채택 (2026-10-18)

## 맥락

미니 PC는 RAM 16GB 단일 노드다. 이제 서비스와 PR 프리뷰도 여기서 돌아가므로, 관리용 컴포넌트가 메모리를
얼마나 가져가느냐가 곧 서비스 자리를 결정한다. 기존 계획에는 kube-prometheus-stack에 더해 Loki + Alloy
(로그 수집·저장)가 있었다.

## 결정

- 기반 컴포넌트(k3s, ArgoCD, PR 프리뷰 오퍼레이터, 경량 Prometheus/Grafana/Alertmanager, cloudflared) 합계를
  **4GB 안팎**으로 유지한다. 모든 Helm 차트에 requests/limits를 지정한다
- **Loki·Alloy는 도입하지 않는다.** 로그는 `kubectl logs`로 본다
- 알림은 로그가 아니라 지표 기반으로 한다(OOMKilled, 재시작, ArgoCD 동기화 실패 등은 kube-state-metrics로 충분)

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| Loki + Alloy (기존 계획) | 로그 검색·보존, 장애 후 분석 | 단일 바이너리 모드도 수백 MB. 7일 보존에 디스크 I/O까지 더해짐 |
| CloudWatch Logs로 컨테이너 로그 전송 | 노드가 죽어도 로그가 남음 | 수집량에 비례한 비용. 월 $5 목표와 충돌 |
| 예산 없이 필요할 때 추가 | 당장 편함 | 단일 노드에서 관리 도구가 서비스 자리를 잠식하는 걸 늦게 알아챔 |

## 결과

- 1단계 실측(2026-10-20): k3s 기반이 약 0.9GiB(k3s-server 659Mi, containerd 164Mi, 내장 파드 ~64Mi)로
  추정(~800Mi)과 비슷하다. 남은 예산 약 3GB를 ArgoCD와 모니터링이 쓴다
- 지나간 로그 검색이 안 된다. 파드가 재시작되면 이전 로그는 `kubectl logs --previous`로 한 번만 볼 수 있다
- 장애 원인 분석이 로그에 크게 의존하게 되면 Loki를 단일 바이너리 + 짧은 보존으로 다시 검토한다
