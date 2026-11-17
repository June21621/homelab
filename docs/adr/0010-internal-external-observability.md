# 0010. 관측은 안(Prometheus)과 밖(CloudWatch)으로 나누고, Watchdog으로 감시자를 감시한다

- 상태: 채택 (2026-11-17)

## 맥락

단일 노드에서 서비스·ArgoCD·PR 프리뷰가 돈다. 알아야 할 것은 두 종류다.

- **무엇이 왜 고장 났나**: 파드 OOM·재시작, ArgoCD 동기화 실패, 디스크, etcd 스냅샷 S3 업로드, 유선 링크
- **노드나 알림 시스템이 통째로 죽었나**: 이때는 클러스터 안의 어떤 것도 알려 줄 수 없다

비용 제약: 외부 관측(CloudWatch)은 월 $5 이하. CloudWatch 사용자 지정 지표는 1개당 월 약 $0.30이라, 파드·앱 단위 지표를 보내면
파드 수 × 지표 수만큼 비용이 늘어난다. 메모리 제약: 기반 컴포넌트 합계 4GB 안팎(ADR 0002).

## 결정

- **안(클러스터 내부)**: kube-prometheus-stack(차트 버전 고정, 보존 7일, 모든 컴포넌트 requests/limits)을 ArgoCD 앱 `monitoring`으로.
  수천 개 시계열을 메모리만 들여 본다. 알림은 Alertmanager → Discord(warning·critical), Grafana는 port-forward로만
- **밖(7단계)**: CloudWatch는 호스트 생존(하트비트)과 노드 지표 10개 이하만. 파드 단위 수집은 하지 않는다
- **감시자 감시**: 항상 울리는 Watchdog을 1분마다 healthchecks.io로 보낸다. 핑이 Period 5분 + Grace 10분 동안 없으면
  healthchecks.io가 **이메일**로 알린다. Discord로 받지 않는다(Discord 장애와 겹치면 둘 다 조용해짐)
- **비밀값은 파일 경로로만**: Discord 웹훅·healthchecks URL은 KSOPS Secret을 Alertmanager에 마운트해 `*_file`로 읽는다.
  라우팅 설정은 평문으로 두어 PR에서 무엇이 바뀌었는지 보인다
- **k3s에 맞춘 기본 규칙 정리**
  - k3s는 etcd·scheduler·controller-manager·kube-proxy를 `k3s server` 한 프로세스에 넣는다. 따로 수집할 주소가 없어
    "Down" 규칙이 항상 울린다 → 수집과 규칙 그룹을 끈다. k3s가 죽으면 유지한 `KubeAPIDown`·`KubeletDown`(Discord)과
    Watchdog 끊김(이메일)이 잡는다
  - API 서버 SLO(burnrate·histogram·slos·availability) 규칙을 끈다. 다수 사용자용 오류 예산 계산이고, 여기서 API 사용자는 ArgoCD와 관리자뿐이다.
    30일 가용성은 7일 보존으로 성립하지도 않는다
- **직접 만든 규칙**은 PrometheusRule + promtool 단위 테스트로 PR에서 검사한다(경계값, 지표 없음). 카운터 경계 비교는 `increase()` 대신 정확한 차이
- **ArgoCD 지표 수집 설정(ServiceMonitor)은 ArgoCD 차트가 아니라 monitoring 앱에 둔다.** Terraform 부트스트랩이 같은 values로
  CRD 없는 빈 클러스터에 ArgoCD를 설치하기 때문이다(ADR 0009). 렌더 검사가 이를 강제한다
- `monitoring` 앱에는 삭제 finalizer를 달지 않는다(지우면 CRD와 함께 모든 규칙·수집 설정·지표가 사라짐)

## 검토한 대안

| 대안 | 장점 | 버린 이유 |
|---|---|---|
| CloudWatch만(Container Insights) | 노드가 죽어도 남음, 관리할 것 적음 | 파드 단위 지표 비용이 월 $5를 넘음. ArgoCD·스냅샷 같은 맞춤 감시가 어려움 |
| Prometheus만 | 무료, 세밀함 | 노드·Prometheus가 죽으면 같이 조용해짐 |
| Watchdog 없이 | 외부 계정 하나 줄어듦 | 호스트는 살아 있고 Prometheus·Alertmanager만 죽으면 아무도 모름(CloudWatch는 호스트가 살아 있어 조용) |
| 감시자 감시를 AWS로 직접(API Gateway·Lambda → CloudWatch 알람) | AWS·Terraform으로 통일 | 받는 엔드포인트를 직접 만들고 지켜야 함. 리소스 4~5개 |
| 알림을 카카오톡으로 | 익숙한 앱 | Alertmanager 연동 없음. 토큰이 6~12시간마다 만료돼 중계 서버를 직접 띄워야 함(고장 날 부품이 하나 늘어남). 알림톡은 사업자 필요 |
| 기본 규칙 전부 유지 | 설정 최소 | k3s 오탐이 Discord를 채워 알림을 무시하게 됨 |
| 기본 규칙 전부 끄고 직접 만든 것만 | 가장 조용 | PVC 가득 참·인증서 만료 같은 예상 못 한 장애를 놓침 |
| Alertmanager 설정 전체를 SOPS Secret으로 | 구성 단순 | 라우팅까지 암호화돼 PR 리뷰 불가 |

## 결과

- 2026-11-17 검증(`docs/verification/2026-11-17-monitoring-alerts.md`): 테스트 알림 30초 안에 Discord, Watchdog 끊김 15분 안에 이메일
- **첫 설치에서 실제 장애를 잡았다**: Grafana(256Mi)·ArgoCD controller(512Mi) OOM을 직접 만든 `ContainerOOMKilled`·`PodRestartBurst`가 알렸다
- **대가 1 — ArgoCD 자기 관리의 교착**: controller가 OOM으로 죽으면 자기 메모리를 올리는 Git 변경을 적용하지 못한다.
  탈출 절차: Git과 **같은 값**을 `kubectl patch`로 넣고(값이 같아 drift 없음), StatefulSet 파드가 옛 리비전에 멈춰 있으면 파드를 지운다.
  큰 앱을 추가하기 전 controller 메모리 여유를 확인한다. controller limits는 1Gi로 올렸다(평소 약 400~500Mi)
- **대가 2 — 메모리**: monitoring 상주 requests 약 1Gi, 노드 전체 사용 2.0 → 3.8GiB. 예산 안이지만 빠듯해지면 Grafana → 수집 주기 → 보존 기간 순으로 줄인다
- 지나간 로그는 여전히 없다(ADR 0002). 알림은 지표로만
- Watchdog 실제 핑 간격은 약 2분(Alertmanager 반복 판정 틱 경계). Period 5분 안이라 수용
