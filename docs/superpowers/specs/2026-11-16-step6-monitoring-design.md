# 6단계 설계: 내부 모니터링 (kube-prometheus-stack + Alertmanager + healthchecks.io)

- 작성일: 2026-11-16 (브레인스토밍 같은 날)
- 상태: 초안 (승인 대기)
- 표기: **[사용자]** = 사용자가 정한 것, **[제안]** = 내가 정한 기본값(바꿔도 됨)
- 상위 설계: `2026-10-18-direction-change-design.md` §5 "3단계: 내부 모니터링", CLAUDE.md "진행 단계 6"

## 1. 의도

이 단계가 끝나면 **클러스터 안에서 무엇이 왜 고장 났는지** Discord로 알림이 오고,
**알림 시스템 자체가 죽으면** healthchecks.io가 이메일로 알려 준다.

관측은 비용 때문에 안과 밖으로 나눈다 **[사용자 이해·동의]**.
- 안(이 단계): Prometheus가 파드·ArgoCD·스냅샷·링크까지 수천 개 지표를 **무료로**(메모리만) 본다
- 밖(7단계): CloudWatch는 지표 1개당 월 약 $0.30이라 호스트 생존 여부 10개 이하만 본다. 파드 단위 수집은 금지(월 $5 상한)
- 감시자 감시: healthchecks.io가 Watchdog 핑으로 "안"의 알림 경로가 살아 있는지 본다

취업 포트폴리오용이므로 "왜 이 규칙을 껐나"를 숫자로 남기는 것(§3.4)과 검증 기록이 동작만큼 중요하다.

### 목표
- kube-prometheus-stack을 ArgoCD Helm 앱으로, 모든 컴포넌트 requests/limits, 차트 버전 고정, 보존 7일
- Alertmanager → Discord(warning·critical), Watchdog → healthchecks.io
- 알림: OOMKilled, 재시작 급증, ArgoCD 동기화 실패·비정상, 디스크, 마지막 S3 스냅샷 7시간 초과, 유선 링크 끊김·불안정
- Grafana(대시보드) 포함 **[사용자]**, 접근은 관리 PC(WSL) 포트포워딩 **[사용자: 5단계 결정]**
- 알림 규칙 문법·동작을 PR 단계에서 검사

### 비목표
- 로그 수집(Loki 등) — ADR 0002
- 호스트 외부 감시(CloudWatch), Tailscale ACL Terraform 이관 — 7단계
- PR 프리뷰 거절 알림 — 8단계(오퍼레이터가 지표를 노출할 때)
- Grafana 상시·다기기 접속(Tailscale Operator) — 필요해지면 재검토
- 앱(portfolio) 지표 대시보드·SLO — 이번 범위 아님(ServiceMonitor만 있으면 수집은 됨)

### 반목표 (이렇게 되면 실패)
- k3s 구조 때문에 생기는 오탐이 Discord를 채워 알림을 무시하게 됨
- 비밀값(Discord 웹훅, healthchecks ping URL, Grafana 관리자 비밀번호)이 평문으로 Git·로그·대화에 남음
- 알림 라우팅 설정이 통째로 암호화돼 PR에서 무엇이 바뀌었는지 안 보임
- 모니터링이 기반 메모리 예산(4GB 안팎)을 깨뜨림
- 사람이 `kubectl apply`·`helm install`을 해야 하는 경로가 생김

## 2. 제약

- 단일 노드 N100 16GB. 2026-11-16 조회: 노드 전체 사용 2.07GiB, 디스크 13.2/466GiB
- 기반 메모리: k3s 약 0.9GiB + ArgoCD 약 0.3GiB. 모니터링 몫은 약 1.1~1.5GiB
- 클러스터 변경은 Git으로만(ArgoCD 자동 동기화 + selfHeal + prune). 사람은 조회·port-forward·Alertmanager API(테스트 알림·silence)만
- ufw는 파드 CIDR(`k3s_pod_cidr`)에서 호스트로 들어오는 연결을 허용한다 → Prometheus가 node-exporter(hostNetwork 9100)·kubelet(10250)을 수집할 수 있음.
  LAN은 22 외 차단, Tailscale은 ACL로 22·6443만 → 9100은 밖에서 안 보임
- 시크릿은 KSOPS + 클러스터 age 키, `gitops/` 아래 `*.sops.yaml`(ADR 0008). 6단계가 KSOPS 첫 실사용
- KSOPS 같은 도구와 그것을 쓰는 리소스는 PR을 나눈다(ADR 0008의 경쟁 상태)
- 커밋·검사는 WSL, push·콘솔 작업은 사용자. 커밋 전 대상 파일 목록을 먼저 보여 줌
- CLAUDE.md·`docs/runbook.md`는 변경안 승인 후 수정

## 3. 결정 사항

### 3.1 차트와 컴포넌트 **[제안: 버전·수치]**

차트 `kube-prometheus-stack` **92.17.0** (2026-10-31 릴리스, operator v0.94.2, Prometheus v3.15.1, Alertmanager v0.34.2).
최신 93.3.0(2026-11-13)은 "2주 이상 된 안정 버전" 규칙에 걸려 그 전 마지막 릴리스를 고정한다(2026-11-17 조회).
`kubeVersion >=1.25`로 k3s v1.36과 맞음. 수치는 시작값이며 설치 후 실측해 조정한다.

| 컴포넌트 | 켬/끔 | requests / limits(memory) | 비고 |
|---|---|---|---|
| Prometheus | 켬 | 400Mi / 1Gi | 보존 7일 + `retentionSize` 8GB, scrape 60초, local-path PVC 10Gi |
| Alertmanager | 켬 | 32Mi / 64Mi | 1개, 저장소 없음 |
| Grafana | 켬 | 128Mi / 256Mi | 차트 기본 대시보드만, 저장소 없음. **메모리가 빠듯하면 가장 먼저 뺄 후보** |
| prometheus-operator | 켬 | 64Mi / 128Mi | |
| kube-state-metrics | 켬 | 32Mi / 128Mi | S3 스냅샷 지표 추가(§3.5) |
| node-exporter | 켬 | 32Mi / 64Mi | 디스크·네트워크 링크 |
| config-reloader 사이드카 | 켬 | 16Mi / 32Mi | Prometheus·Alertmanager에 붙음 |
| kubeEtcd·kubeScheduler·kubeControllerManager·kubeProxy 수집 | **끔** | | k3s는 한 프로세스에 들어 있어 따로 수집할 주소가 없음 |
| 합계 | | 약 0.7Gi / 1.7Gi | 예산 안 |

- namespace `monitoring` **[제안]**
- CPU는 requests만 두고 limits는 두지 않는다(기존 ArgoCD values와 같은 방식)
- Prometheus가 우리 ServiceMonitor·PrometheusRule을 Helm release 라벨 없이도 고르도록
  `serviceMonitorSelectorNilUsesHelmValues: false`, `ruleSelectorNilUsesHelmValues: false` (podMonitor·probe도 같음)

### 3.2 앱 구조: 앱 하나, 소스 둘 (A안) **[사용자]**

`gitops/root/monitoring.yaml`의 Application `monitoring` 하나가 두 소스를 함께 배포한다.
`gitops/root/argocd.yaml`과 같은 다중 소스 패턴.

```
gitops/
├── root/monitoring.yaml                 # Application: ① 차트 ② values ref ③ 아래 Kustomize 경로
└── platform/monitoring/
    ├── values.yaml                      # 차트 values (평문, 라우팅 설정 포함)
    ├── kustomization.yaml               # KSOPS generator + 규칙
    ├── ksops-generator.yaml
    ├── secrets.sops.yaml                # Discord 웹훅·healthchecks URL·Grafana 관리자 비밀번호 (암호화)
    ├── argocd-servicemonitors.yaml      # ArgoCD 지표 수집 (§3.6, 6-3b에서 추가)
    └── rules/*.yaml                     # PrometheusRule (직접 만든 규칙)
```

- syncOptions: `CreateNamespace=true`, `ServerSideApply=true`(차트 CRD가 커서 일반 apply 한도 초과),
  `SkipDryRunOnMissingResource=true`(첫 설치 때 PrometheusRule CRD가 아직 없음)
- 자동 동기화 + prune + selfHeal
- **`resources-finalizer`를 달지 않는다 [제안·검토 반영]**. 이 앱은 prometheus-operator CRD와 Prometheus PVC를 가진다.
  finalizer가 있으면 `monitoring.yaml`을 지우거나 이름을 바꾸는 순간 CRD가 지워지고, 그에 딸린 모든 ServiceMonitor·PrometheusRule과
  지표 데이터까지 사라진다. 플랫폼 앱(`argocd.yaml`·`root.yaml`)과 같은 방식이고, 앱을 일부러 없앨 때는 정리 절차를 runbook에 둔다
- 검토한 대안
  - B. 앱 둘(`monitoring` + `monitoring-config`): 규칙 오류가 차트 쪽 상태에 번지지 않음. 그러나 앱이 늘고, A의 약점은 PR 검사(§3.7)가 병합 전에 막아 줌
  - C. Alertmanager 설정 전체를 SOPS Secret으로(`useExistingSecret`): 라우팅까지 암호화돼 PR에서 안 보임 → 반목표 위반
  - Kustomize `helmCharts`로 차트를 펼치기: ArgoCD 빌드 옵션(`--enable-helm`)을 또 바꿔야 하고 기존 패턴과 다름

### 3.3 비밀값 전달: 파일로 마운트 **[제안]**

- `secrets.sops.yaml`의 Secret 하나(예: `alertmanager-urls`)를 `alertmanager.alertmanagerSpec.secrets`로 마운트
  → `/etc/alertmanager/secrets/<secret>/<key>`
- Alertmanager 설정은 URL 대신 파일 경로만 쓴다: Discord `webhook_url_file`, healthchecks `webhook_configs[].url_file`
  (Alertmanager v0.34.2 — 구현 첫 작업에서 공식 설정 문서와 `amtool check-config`로 재확인)
- Grafana 관리자 비밀번호도 같은 파일의 별도 Secret으로, `grafana.admin.existingSecret`이 읽는다
  (차트 기본 비밀번호를 쓰지 않기 위함) **[제안]**
- 값 입력은 사용자가 WSL에서 `sops`로 직접 한다. 어떤 명령도 값을 화면에 출력하지 않는다

### 3.4 기본 규칙: k3s에 안 맞는 것만 끈다 (B안) **[사용자]**

`defaultRules.rules`에서 끄는 그룹과 이유:

| 그룹 | 이유 |
|---|---|
| `etcd`, `kubeControllerManager`, `kubeProxy`, `kubeSchedulerAlerting`, `kubeSchedulerRecording` | k3s는 이것들을 `k3s server` 한 프로세스에 넣음. 수집 대상이 없어 "Down" 규칙이 항상 울림(오탐) |
| `windows` | 해당 없음 |
| `kubeApiserverBurnrate`, `kubeApiserverHistogram`, `kubeApiserverSlos` | 다수 사용자용 API SLO(오류 예산 소진 속도). 가장 큰 지표를 여러 시간 창으로 재계산해 무겁고, 여기서 API 사용자는 ArgoCD와 관리자뿐. API 다운은 유지하는 `kubernetesSystem`의 `KubeAPIDown`이 잡음 |
| `kubeApiserverAvailability` | 같은 SLO 묶음의 30일 가용성 계산. 보존이 7일이라 값 자체가 성립하지 않음 [검토 반영] |

나머지 그룹(노드·kubelet·파드·스토리지·Prometheus·Alertmanager 자체 등)은 유지한다.

**k3s가 죽었을 때 감지 경로** (9단계 검증 항목):

| 상황 | 감지 |
|---|---|
| `k3s server`만 죽음(컨테이너는 계속 돎) | `KubeAPIDown`·`KubeletDown` → Discord |
| 컨테이너 런타임·노드 멈춤 | Watchdog 핑 끊김 → healthchecks.io 이메일 |
| 전원 차단 | healthchecks.io (+ 7단계 CloudWatch) |

**API 지표 줄이기 측정 [제안]**: 규칙만 끄면 원본 지표(`apiserver_request_duration_seconds_bucket`)는 계속 수집된다.
설치 후 하루 동안 `prometheus_tsdb_head_series`와 Prometheus 메모리를 잰 뒤, 이 지표를 수집 단계에서 버리는
PR(metricRelabelings drop)을 넣고 다시 잰다. 전후 숫자를 ADR과 검증 기록에 남긴다.

### 3.5 직접 만드는 규칙 **[사용자: 목록] [제안: 기준값]**

| 알림 | 조건(초안) | for | 등급 |
|---|---|---|---|
| `ContainerOOMKilled` | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`이고 10분 안에 재시작 수 증가 | 0 | warning |
| `PodRestartBurst` | 15분 재시작 증가 > 3 (기본 `KubePodCrashLooping`과 별개) | 0 | warning |
| `ArgoCDSyncFailed` | `argocd_app_sync_total{phase=~"Error\|Failed"}` 증가 | 0 | warning |
| `ArgoCDAppDegraded` | `argocd_app_info{health_status="Degraded"}` | 10m | warning |
| `ArgoCDAppOutOfSync` | `argocd_app_info{sync_status="OutOfSync"}` | 15m | warning |
| 디스크 | 기본 `NodeFilesystemSpaceFillingUp`·`AlmostOutOfSpace` 그대로 | | 기본 |
| `EtcdS3SnapshotStale` | `time() - max(S3 스냅샷 생성 시각) > 7h`, 지표가 아예 없어도 울림(`absent`) | 0 | **critical** |
| `WiredLinkDown` | `node_network_carrier{device="enp3s0"} == 0` | 2m | warning |
| `WiredLinkFlapping` | `changes(node_network_carrier_changes_total{device="enp3s0"}[1h]) > 3` | 0 | warning |

- 유선이 끊겨도 Wi-Fi 예비 경로(metric 600)로 Discord까지 나갈 수 있어 링크 알림이 실제로 전달된다
- **S3 스냅샷 지표 출처**: k3s는 스냅샷마다 `ETCDSnapshotFile`(k3s.cattle.io/v1) 리소스를 만들고
  `spec.location`(s3://…)과 `status.creationTime`을 기록한다(2026-11-16 조회로 확인). kube-state-metrics의
  CustomResourceState 기능으로 이를 지표로 만든다(RBAC에 `etcdsnapshotfiles` get/list/watch 추가).
  호스트 스크립트가 필요 없다
  - **위험**: KSM이 `creationTime` 문자열을 시각 값으로 바꿀 수 있는지 구현 첫 작업에서 확인한다.
    안 되면 대안: 호스트의 node-exporter textfile(Ansible 타이머가 `.prom` 파일 기록). 이 경우 node-exporter
    hostPath 마운트가 필요해 설계를 사용자와 다시 맞춘다
- ArgoCD 규칙은 ArgoCD 지표 수집(§3.6)이 들어간 뒤에 넣는다

### 3.6 ArgoCD 지표 수집 **[제안]**

- `gitops/platform/argocd/values.yaml`에서는 controller(와 server·repoServer)의 **`metrics.enabled`만** 켠다.
  이것은 지표용 Service만 만들고 CRD가 필요 없다
- **ServiceMonitor는 ArgoCD 차트로 만들지 않는다** (`serviceMonitor.enabled`는 끈 채로) [제안·검토 반영].
  대신 `gitops/platform/monitoring/argocd-servicemonitors.yaml`(평문 매니페스트)로 monitoring 앱의 Kustomize 경로에 둔다
  - 이유: Terraform `argocd-bootstrap`은 같은 values 파일을 **빈 클러스터**에 설치한다(`file()`로 한 벌 읽음).
    거기서 `serviceMonitor.enabled`를 켜면 CRD가 없어 첫 `terraform apply`가 실패하고, "명령 하나로 재구축"과
    9단계 "클러스터 삭제 후 재구축"·"`terraform apply -replace` 비상 재설치"가 깨진다.
    Terraform에서만 값을 덮어쓰는 방법은 "values 한 벌" 원칙을 깨서 버렸다
  - ServiceMonitor가 CRD와 같은 앱에 있으니 첫 설치도 `SkipDryRunOnMissingResource`로 한 번에 된다
- 순서: `metrics.enabled`(ArgoCD values) PR → ServiceMonitor + ArgoCD 규칙 PR. 둘 다 모니터링 설치(6-2) 뒤

### 3.7 알림 라우팅 **[사용자: Discord·healthchecks] [제안: 수치]**

- 기본 receiver: Discord. `severity=~"warning|critical"`만, 해결 알림도 보냄
- `group_by: [alertname, namespace]`, `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`
- `Watchdog` → healthchecks.io: `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 1m`
  (`group_interval`을 같이 줄이지 않으면 상위 기본값 5분 때문에 핑이 5분마다만 나간다 [검토 반영])
- `severity="info"`와 `InfoInhibitor` → null receiver(버림)
- 차트 기본 inhibit 규칙 유지(critical이 울리면 같은 대상의 warning 억제)
- healthchecks.io check: Period 5분, Grace 10분, 알림 채널 **이메일**(Discord로 받으면 Discord 장애와 겹칠 때 같이 조용해짐)

### 3.8 PR 단계 검사 **[제안]**

`static-checks`(PR 쪽 코드로 실행, 비밀값 없음)에 추가:
- `promtool check rules`: `gitops/platform/monitoring/rules/`의 PrometheusRule에서 `spec`을 꺼내 문법 검사
- `promtool test rules`: 직접 만든 규칙마다 "이 지표가 이렇게 되면 울린다/안 울린다" 단위 테스트
  (특히 `EtcdS3SnapshotStale`의 7시간 경계와 `absent`)
- `scripts/check_rendered.py`를 monitoring 차트에도 적용: 지금은 Deployment·StatefulSet·DaemonSet·Job만 보는데,
  Prometheus·Alertmanager는 CR(`Prometheus`, `Alertmanager`)이므로 그 `spec.resources`(와 reloader)도 검사하도록 확장
- CI에는 age 키·ksops가 없으므로 Kustomize(KSOPS generator)를 렌더링하지 않는다. 차트는 `helm template`으로,
  규칙 폴더는 파일을 직접 읽어 검사한다. Secret이 암호화돼 있는지는 기존 `check-sops-encrypted.sh`가 본다 [검토 반영]
- promtool은 Prometheus 릴리스 바이너리를 버전·체크섬 고정으로 받는다(관리 PC도 `bootstrap-workstation.sh`에 같은 버전)

## 4. 진행 순서와 확인 기준 **[제안]**

| PR | 내용 | 확인 |
|---|---|---|
| 6-1 | 검사 도구: promtool 설치(워크플로·관리 PC), `check_rendered.py` CR 확장, 규칙 검사 단계 | 빈 규칙 폴더에서 통과, 일부러 깨뜨린 규칙은 실패 |
| 6-2 | `monitoring` 앱: values, KSOPS Secret, 직접 만든 규칙(ArgoCD 것 제외)+테스트, root Application | ArgoCD Synced·Healthy, 모든 타깃 up(Prometheus `/targets`), 오탐 알림 없음, Grafana 로그인 |
| 6-3a | ArgoCD values `metrics.enabled` (지표 Service만) | ArgoCD Synced, 지표 Service 생김 |
| 6-3b | monitoring 앱에 ArgoCD ServiceMonitor + ArgoCD 규칙·테스트 | `argocd_app_info` 수집 |
| 6-4 | API 히스토그램 drop (하루 측정 후) | 시계열 수·메모리 전후 기록 |
| 6-5 | 문서: ADR 0010, 검증 기록, 설계 §4 메모리 표 갱신, CLAUDE.md·runbook 변경안(승인 후) | |

**6단계 확인 기준** (검증 기록 `docs/verification/YYYY-MM-DD-monitoring-alerts.md`):
1. 테스트 알림: Alertmanager API(port-forward + `amtool alert add`)로 가짜 warning → Discord 수신, 해결 알림 수신
2. 실제 알림: `portfolio-lab`의 `POST /chaos/memory`로 OOM 유발 → `ContainerOOMKilled` Discord 수신(감지 시간 기록)
3. Watchdog 핑: healthchecks.io에 1분마다 핑 기록
4. 감시자 감시: `amtool silence add alertname=Watchdog`(만료 30분) → 핑 끊김 → healthchecks.io 이메일 수신(시간 기록) → silence 해제 후 복구.
   클러스터 리소스를 바꾸지 않는 방법
5. 메모리 실측: `kubectl top pods -n monitoring`, 상위 설계 §4 표와 ADR 0002 결과 갱신
6. 유선 링크·스냅샷 규칙은 promtool 단위 테스트로 확인(실제 케이블 뽑기·스냅샷 중단은 9단계)

ADR: **0010 관측을 안(Prometheus)과 밖(CloudWatch)으로 나누고 Watchdog으로 감시자를 감시한다 + k3s에 맞춘 기본 규칙 정리**.
(상위 설계는 "0009"라 적었지만 0009는 ArgoCD 자기 관리가 이미 사용 중)

## 5. 사용자 준비·수동 작업 (runbook에 기록)

- Discord: 본인 서버 → 알림 채널 → 웹후크 생성. URL은 대화에 붙이지 않고 WSL에서 `sops`로 입력
- healthchecks.io: 무료 계정, check 1개(Period 5분, Grace 10분), 알림 이메일. Ping URL도 비밀값
- Grafana 관리자 비밀번호: WSL에서 생성해 `sops`로 입력, 원본 Bitwarden **[제안]**
- push, 테스트 알림·silence 명령 실행(port-forward 필요)

## 6. 구현자에게 맡기는 것

- values의 세부 키 이름과 차트 기본값과의 차이(렌더링으로 확인)
- KSM CustomResourceState 설정 문법과 지표 이름
- Helm hook(admission webhook 인증서 Job)이 ArgoCD에서 OutOfSync를 반복하면 그 처리 방식(차트 옵션 또는 ignoreDifferences)
- 규칙 기준값의 소폭 조정(바꾸면 이유를 커밋 메시지에)
- Grafana 기본 대시보드 중 k3s에서 비는 것(etcd·scheduler 등) 끄기
- promtool 버전(차트의 Prometheus 버전과 같은 줄)

## 7. 기타

- 차트 업그레이드는 `targetRevision`을 바꾸는 PR. CRD는 ServerSideApply로 함께 갱신된다
- 메모리가 예산을 넘으면 빼는 순서: Grafana → 수집 주기 늘리기 → 보존 기간 줄이기
