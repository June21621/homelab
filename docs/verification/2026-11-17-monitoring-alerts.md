# 검증: 내부 모니터링 알림 경로와 감시자 감시

- 날짜: 2026-11-17 (시각은 KST, 쿠버네티스·Alertmanager 출력의 UTC는 괄호에)
- 대상: `monitoring` 앱(kube-prometheus-stack 92.17.0), Alertmanager → Discord, Watchdog → healthchecks.io
- 관련: 설계 `docs/superpowers/specs/2026-11-16-step6-monitoring-design.md`, ADR 0010,
  `scripts/alert-test.sh`(`make alert-test`), 규칙 `gitops/platform/monitoring/rules/`
- PR: 6-1 검사 도구, 6-2 monitoring 앱, 6-2b 메모리 제한, 6-3a ArgoCD 지표 Service, 6-3b ArgoCD 수집·규칙,
  6-4a Discord 짧은 형식·Grafana 한국 시간, 6-4b API 히스토그램 drop, 6-4c kubelet 중복 제거

## 목적

"알림 설정이 있다"가 아니라 **"장애가 나면 사람이 실제로 알게 된다"**를 확인한다. 두 경로를 따로 본다.

1. 클러스터 안 문제 → Prometheus 규칙 → Alertmanager → **Discord**
2. 알림 시스템 자체가 죽음 → Watchdog 핑 끊김 → healthchecks.io → **이메일** (Discord와 다른 경로)

## 1. 설치와 첫 동기화

| 시각 | 상태 |
|---|---|
| 14:29~14:34 | 6-2 병합 후 앱 없음 (ArgoCD Git 폴링 주기 최대 3분) |
| 14:34:33 | `monitoring` OutOfSync → 동기화 시작 |
| 14:34:53 | Synced / **Degraded** — 리소스 생성 완료, Grafana 실패(아래 §2) |
| 14:36 무렵 | healthchecks.io 첫 핑 → check "new" → "up" |

- CRD 순서 문제로 첫 동기화가 실패하지 않았다(`SkipDryRunOnMissingResource`, `ServerSideApply`)
- 수집 대상 9종(apiserver·kubelet·coredns·node-exporter·kube-state-metrics 등) 모두 up. k3s 구조 때문에 down인 대상 없음
- S3 스냅샷 지표: 최신 S3 스냅샷 12:00:02, 실제 스냅샷 시각과 같음(KSM이 `ETCDSnapshotFile.status.creationTime`을 시각 값으로 변환)

## 2. 실제 장애: 첫 설치 OOM과 ArgoCD controller 교착 (예정에 없던 검증)

### 재현(우연)
- 메모리 limits 시작값: Grafana 256Mi, 사이드카 2개 64Mi, ArgoCD application-controller 512Mi(5단계 값)

### 실제 결과
| 시각 | 일어난 일 | 알림 |
|---|---|---|
| 14:35 (05:35Z) | Grafana 본체·사이드카 2개 OOMKilled, CrashLoop. 시작 직후 약 250Mi | Discord `ContainerOOMKilled` |
| 14:35:22 (05:35:22Z) | ArgoCD controller OOMKilled — monitoring 앱(CRD·규칙·대시보드 수백 개) 첫 동기화 중 | Discord `ContainerOOMKilled` |
| 14:37 이후 | 재시작 반복 | Discord `PodRestartBurst`(15분 5회), `KubePodCrashLooping` |
| 14:50 | 제한 상향 PR(6-2b: Grafana 512Mi, 사이드카 128Mi, controller 1Gi) 병합 | |
| 14:50~14:55 | **교착**: controller가 시작 약 8초 만에 OOM. 자기 자신의 1Gi 수정을 적용하기 전에 죽는다. Grafana 수정도 그 뒤에 막힘. `argocd`·`monitoring` 둘 다 OutOfSync, "waiting for deletion of hook" | (OOM·CrashLoop 알림 계속) |
| 14:55 | 비상 조치 1: `kubectl patch statefulset argocd-application-controller` — **Git과 같은 값**(requests 384Mi / limits 1Gi) | |
| 14:55 | StatefulSet `updateRevision`은 새것인데 파드는 옛 리비전(512Mi)으로 CrashLoopBackOff 5분 대기. RollingUpdate는 Ready가 안 되는 파드를 교체하지 않는다 | |
| 14:55:41 (05:55:41Z) | 비상 조치 2: `kubectl delete pod argocd-application-controller-0` → 새 리비전(1Gi)으로 생성 | |
| 14:56:45 | controller가 밀린 Grafana 수정 적용(512Mi) | |
| 14:57:05 | 모든 Application Synced·Healthy | Discord `[RESOLVED]` |

- 서비스(portfolio prod·lab)는 영향 없음. 막힌 것은 "새 변경 반영"뿐
- 복구 후 실측: controller 평소 **약 490Mi**(옛 limit 512Mi는 처음부터 빠듯했음), 이후 동기화 중 386Mi
- 비상 조치는 Git과 **같은 값**을 넣었으므로 ArgoCD가 살아난 뒤 되돌리거나 어긋날 것이 없었다(selfHeal 충돌 없음)

### 배운 것
- **ArgoCD가 자기 자신을 관리하면, 자신을 고치는 변경을 적용할 힘이 없을 때 교착에 빠진다.** 9단계 "ArgoCD 자기 업그레이드 실패"의 실제 사례.
  탈출은 Git과 같은 값을 kubectl로 한 번 넣고(값이 같아 drift 없음), 고장 난 StatefulSet 파드를 지우는 것. 더 큰 고장이면 `make argocd-bootstrap`(-replace)
- 큰 앱(CRD·리소스 수백 개)을 처음 넣을 때 controller 메모리가 순간적으로 오른다. 앱을 추가하기 전 controller 여유를 확인한다
- OOM → 재시작 급증 → CrashLoop 세 알림이 원인(무엇이·왜·얼마나)을 나눠 알려 줬다. 직접 만든 `ContainerOOMKilled`·`PodRestartBurst`가 실제로 동작함을 확인

## 3. 테스트 알림 (확인 기준 1)

- 재현: `make alert-test CMD=fire` — Alertmanager API로 가짜 `HomelabTestAlert`(warning, 끝나는 시각 5분 뒤)
- 기대: `group_wait` 30초 뒤 Discord FIRING, 5분 뒤 RESOLVED
- 실제: **15:49 FIRING, 15:54 RESOLVED** ✅ (클러스터 리소스는 바꾸지 않음)

## 4. Watchdog 핑과 감시자 감시 (확인 기준 3·4)

- 재현: `make alert-test CMD=silence-watchdog` — Alertmanager에 Watchdog silence 30분(모니터링이 죽은 상황을 흉내, 클러스터 리소스는 바꾸지 않음)
- 기대: 마지막 핑 + Period 5분 + Grace 10분 ≈ 15분 뒤 DOWN 이메일, silence 만료 뒤 UP 이메일

| 시각 | 일어난 일 |
|---|---|
| 15:56:13 (06:56:13Z) | silence 시작, 마지막 핑 |
| **16:11:08** | healthchecks.io **DOWN** 이메일 — 감지 약 15분 ✅ |
| 16:26:13 | silence 자동 만료 |
| **16:27:08** | **UP** 이메일 — 만료 후 1분 안("first notification"으로 즉시 전송) ✅ |

- 발견: 실제 핑 간격은 1분이 아니라 **약 2분**(14:36~15:56에 41회). `repeat_interval: 1m`을 `group_interval: 1m` 틱마다
  확인하는데, 직전 전송 후 1분이 조금 안 된 틱에서는 건너뛴다. Period 5분 안이라 감시에는 영향 없어 그대로 둔다
- 면접 답: "Prometheus·Alertmanager·노드가 죽으면 Discord와 다른 경로(이메일)로 15분 안에 안다"

## 5. 정적 검증 (PR마다 static-checks)

| 검사 | 무엇을 막나 |
|---|---|
| `check_rendered.py monitoring` | CR·컨테이너 메모리 제한 누락, k3s에서 끈 수집 대상·규칙 그룹 부활, Alertmanager 설정의 URL 리터럴(`*_file` 경로만 허용), Watchdog 1분, 보존 7d |
| `check_rendered.py argocd` | ArgoCD 차트의 ServiceMonitor(빈 클러스터 재구축 실패) |
| `check-prom-rules.sh` | 규칙 문법, severity 라벨, 단위 테스트(경계값), **테스트가 가리키는 규칙이 없을 때**(promtool은 경고만 하고 통과시킴 — 구현 중 발견) |
| `amtool check-config` | 렌더링한 Alertmanager 설정(키 이름 오타 등) |

- 규칙 기준값을 카운터의 정확한 차이로 쓴 이유: `increase()`는 15분 3회 재시작을 3.x로 외삽해 경계에서 잘못 울린다
- `ArgoCDSyncFailed`: 실패 카운터는 첫 실패 때 값 1로 **처음 생겨** `increase()`가 못 본다. "10분 전에 없던 실패 시계열"을 함께 잡고,
  그 절을 뺀 사본으로 테스트가 실패하는 것을 확인(변이 확인)

## 6. 메모리 실측

| 시점 | 노드 전체 | Prometheus | Grafana(3컨테이너) | ArgoCD controller |
|---|---|---|---|---|
| 설치 전(2026-11-16) | 2069Mi | — | — | 244Mi |
| 설치 직후 14:37 | 3265Mi | 319Mi | (OOM 반복) | (OOM) |
| 복구 후 14:57 | 3723Mi | 374Mi | 432Mi | 490Mi |
| 15:45 | 3803Mi | 396Mi | | 386Mi |

- 렌더링 기준 monitoring 상주 컴포넌트 합계: requests 약 976Mi / limits 약 2.2Gi(6-2b 반영, 설정 리로더·Grafana 사이드카 포함)
- 시계열 121,199개 중 API 서버·etcd 응답 시간 히스토그램(`*_bucket`) 7종이 약 6.3만 개 → 6-4에서 수집 단계 drop 후 전후 비교(§7)
- 24시간 뒤(11-18 16:08): 모든 앱 Healthy, 재시작 0, Watchdog 외 알림 0(오탐 없음), 노드 3,759Mi. 짝수 정각 디스크 쓰기 봉우리는
  Prometheus compaction(2시간)과 일치, 00·06·12·18시는 etcd 스냅샷과 겹침. 디스크 바쁨 최대 약 1~2%

## 7. API 히스토그램 drop과 k3s 중복 수집 제거 전후 (6-4b·6-4c)

### 계획과 실제
- 계획(6-4b): 아무 규칙도 쓰지 않는 API 서버·etcd 응답 시간 히스토그램 7종(`*_bucket`)을 apiserver 수집에서 drop.
  24시간 기준 63,444개 = 전체 120,637개의 53%
- 반영(11-18 17:55) 후 7종이 63,444 → **40,458**까지만 줄었다. 남은 것은 전부 `job="kubelet"`
- **발견: k3s는 API 서버·kubelet·etcd가 `k3s server` 한 프로세스라, kubelet 지표 주소(:10250/metrics)가 합쳐진 지표 전체를 내보낸다.**
  같은 `apiserver_*`·`etcd_*` 지표를 apiserver 수집과 kubelet 수집에서 **두 번 저장**하고 있었다(kubelet job 61,746개 중 중복 51,103개).
  설계 때 "k3s는 한 프로세스라 scheduler 등을 따로 수집할 주소가 없다"는 면만 보고, 반대로 "한 주소가 전부를 내보낸다"는 면은 놓쳤다
- 6-4c: kubelet `/metrics` 수집에서 이름이 `apiserver_`·`etcd_`로 시작하는 사본을 drop(원본은 apiserver job, API 서버 규칙은 모두 `job="apiserver"`).
  차트 기본 kubelet drop(저장소 작업 히스토그램)은 values가 목록을 대체하므로 함께 옮겼다. 검사기가 중복 drop·고유 지표 유지·기본 drop 유지를 강제
- 반영: ServiceMonitor 갱신 18:18:46 → Prometheus 설정 재로드 18:19:49 → 사본·7종 0 at 18:22:01

### 결과 (전: 11-18 16:08, 24시간 / 후: 11-19 19:16, 변경 뒤 약 20시간)

| 항목 | 전 | 후 | 변화 |
|---|---|---|---|
| 시계열(head series) | 120,637 | 46,740 | **−61%** |
| 초당 수집 샘플 | 2,102 | 871 | −59% |
| Prometheus 메모리 평균 | 401Mi | 356Mi | −11% |
| Prometheus 메모리 최대 | 550Mi | 398Mi | **−28%** |
| TSDB 디스크 | 519MiB | 506MiB | 거의 같음(아래) |
| 2시간 compaction 때 디스크 쓰기 | 0.7~1.8MiB/s | 0.34~1.3MiB/s | 감소 |
| 오탐·재시작 | 0 | 0 | — |

- 메모리 평균이 시계열만큼 줄지 않는 이유: 시계열 수와 무관한 고정 몫(최소 314Mi)이 크고, Go 런타임이 쓴 메모리를 바로 돌려주지 않는다.
  대신 compaction 때의 최대값이 크게 줄어 limits(1Gi)까지 여유가 커졌다
- 디스크는 7일 보존 안에 변경 전 블록이 남아 있어 일주일에 걸쳐 줄어든다(새로 쌓이는 양은 약 41%)
- 대가: Grafana "API server" 대시보드의 지연 시간 그래프가 빈다. 남긴 규칙(차트 기본·직접 만든 것) 중 drop한 지표를 쓰는 것은 없다(렌더링으로 확인)

## 남은 것

- 실제 케이블을 뽑는 유선 링크 알림, S3 스냅샷 중단은 9단계에서 실제로 재현(지금은 promtool 단위 테스트로만 확인)
