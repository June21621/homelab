# 6단계: 내부 모니터링 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kube-prometheus-stack을 ArgoCD 앱 `monitoring`으로 올려 Discord(warning·critical)와 healthchecks.io(Watchdog)로 알림이 가게 하고, 규칙·렌더링을 PR 단계에서 검사한다.

**Architecture:** Application `monitoring` 하나가 ① 차트 ② `$values` ref ③ `gitops/platform/monitoring/`(Kustomize: KSOPS Secret·직접 만든 PrometheusRule·ArgoCD ServiceMonitor)를 함께 배포한다. Alertmanager 설정은 values에 평문으로 두고 URL은 Secret 파일 경로(`*_file`)로만 참조한다. static-checks가 차트를 `helm template`으로 렌더링해 `check_rendered.py monitoring`으로 검사하고, 규칙은 promtool로 문법·단위 테스트한다.

**Tech Stack:** kube-prometheus-stack 92.17.0, Prometheus/promtool v3.15.1, Alertmanager/amtool v0.34.2, KSOPS(기존), SOPS 3.13.3, Helm 3.22.1, kubectl 1.36.5, Python + uv 0.12.23(pyyaml 6.0.3), GitHub Actions

**Spec:** `docs/superpowers/specs/2026-11-16-step6-monitoring-design.md`

## Global Constraints

- 차트·이미지·바이너리 버전 고정, `latest` 금지, 2주 이상 된 안정 버전. 차트 `kube-prometheus-stack` **92.17.0**(repo `https://prometheus-community.github.io/helm-charts`), promtool **3.15.1**, amtool **0.34.2**. 바이너리는 릴리스 `sha256sums.txt`로 체크섬 검증
- 서드파티 GitHub Action은 커밋 SHA 고정. 새 Action을 들이지 않고 `run:`에서 curl + 체크섬으로 설치
- 모든 컨테이너에 requests.memory·limits.memory. CPU는 requests만. 시작값은 spec §3.1 표 그대로
- namespace `monitoring`. Application 이름 `monitoring`, **`resources-finalizer` 없음**
- Secret 이름·키: `alertmanager-receivers`(`discord-webhook-url`, `healthchecks-ping-url`), `grafana-admin`(`admin-user`, `admin-password`). 파일 `gitops/platform/monitoring/secrets.sops.yaml` 하나에 두 Secret
- Alertmanager 안 경로: `/etc/alertmanager/secrets/alertmanager-receivers/discord-webhook-url`, `…/healthchecks-ping-url`
- 라우팅 수치: 기본 `group_by: [alertname, namespace]`, `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`, Discord는 `severity=~"warning|critical"`, `send_resolved: true`. Watchdog: `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 1m`. info·`InfoInhibitor` → `null`
- 끄는 기본 규칙 그룹: `etcd`, `kubeControllerManager`, `kubeProxy`, `kubeSchedulerAlerting`, `kubeSchedulerRecording`, `windows`, `kubeApiserverBurnrate`, `kubeApiserverHistogram`, `kubeApiserverSlos`, `kubeApiserverAvailability`. 끄는 수집: `kubeEtcd`, `kubeScheduler`, `kubeControllerManager`, `kubeProxy`
- Prometheus: `retention: 7d`, `retentionSize: 8GB`, `scrapeInterval: 60s`, local-path PVC 10Gi, `*SelectorNilUsesHelmValues: false`(serviceMonitor·podMonitor·rule·probe)
- 커밋·검사·sops는 WSL. WSL 명령은 스크립트 파일로 만들어 `wsl.exe -d Ubuntu-24.04 -- bash <path>`(PowerShell 도구). push·PR 병합·콘솔 작업은 사용자
- **커밋 전 커밋 대상 파일 목록을 사용자에게 보여 줄 것.** 브랜치는 PR마다 `step6-<n>-<이름>`
- 비밀값을 화면·로그·대화·Actions 로그에 출력하지 않는다. 비밀값 다루는 명령 뒤 `clear` 안내
- 클러스터 변경은 Git으로만. 사람은 get·describe·logs·top·port-forward, Alertmanager API(테스트 알림·silence)만
- 셸 `set -euo pipefail` + shellcheck, 로직은 Python(uv 스크립트, pyyaml 고정)
- CLAUDE.md·`docs/runbook.md`는 변경안 승인 후에만 수정(Task 6)
- 학습용 설명: 매 Task 끝에 "무슨 파일에 무엇을 → 어떤 동작 → 결과"를 사용자에게 설명

## Review Focus

1. **values에 URL을 직접 적거나 `*_file` 경로 오타** → 기대: 렌더링된 Alertmanager 설정에 `discord.com`·`hc-ping.com`·`https://` 리터럴이 없고, `*_file` 경로가 Global Constraints 경로와 정확히 같음 → Task 1 `check_monitoring` 테스트 `test_alertmanager_urls_only_from_files`
2. **S3 스냅샷 지표가 아예 없음**(KSM 설정 오류·RBAC 누락) → 기대: 오래된 경우와 똑같이 critical → Task 2 promtool 테스트 `absent`
3. **링크 신호가 아주 짧게 끊겼다 붙음**(2분 미만) → 기대: `WiredLinkDown`은 안 울리고, 1시간에 4번 넘게 바뀌면 `WiredLinkFlapping` → Task 2 promtool 테스트
4. **monitoring Application에 finalizer가 붙음**(복붙) → 기대: `check_rendered.py apps`가 거부 → Task 1 `PROTECTED_APPS`에 `monitoring` 추가 + 테스트
5. **Watchdog이 5분마다만 나감**(`group_interval` 누락) → 기대: 렌더링된 Watchdog route의 `group_interval`·`repeat_interval`이 `1m` → Task 1 `test_watchdog_route_every_minute`

---

### Task 0: 설계·계획 커밋 (6-1 브랜치에 포함)

**Files:**
- Commit: `docs/superpowers/specs/2026-11-16-step6-monitoring-design.md`, 이 계획

- [ ] **Step 1: 브랜치 `step6-1-checks` 생성**(WSL, main에서) → `git status --short`에 두 문서만 새 파일로 보임(`AGENTS.md`는 사용자 파일이라 커밋 대상 아님)

---

### Task 1: 6-1 검사 도구 (promtool·amtool, check_rendered `monitoring`)

**Files:**
- Modify: `scripts/bootstrap-workstation.sh` — `PROMETHEUS_VERSION="3.15.1"`(promtool만 설치), `ALERTMANAGER_VERSION="0.34.2"`(amtool만 설치), 기존 sops 설치 블록과 같은 방식(릴리스 `sha256sums.txt`로 `sha256sum -c`, 버전 같으면 건너뜀)
- Create: `scripts/install-prom-tools.sh` — 위 설치 로직을 함수로 분리, 워크플로와 bootstrap이 같이 호출(버전은 이 파일 한 곳)
- Modify: `scripts/check_rendered.py` — `check_monitoring(docs)`, `CHECKS["monitoring"]`, `PROTECTED_APPS`에 `monitoring`
- Create: `scripts/test_check_rendered.py` — pytest(uv 스크립트, `pyyaml==6.0.3`, `pytest` 고정)
- Create: `scripts/check-prom-rules.sh` — PrometheusRule 파일들에서 `spec`을 꺼내 `promtool check rules` + `promtool test rules`
- Create: `scripts/extract_rules.py` — `extract(src: Path, dst_dir: Path) -> list[Path]`: 각 `kind: PrometheusRule` 문서의 `spec`을 `dst_dir/<metadata.name>.yaml`로 저장
- Modify: `scripts/verify-argocd.sh` — `--static`에 monitoring 렌더링 검사, 규칙 검사, `check_rendered` pytest 추가
- Modify: `.github/workflows/tag-pr-guard.yaml` — static-checks에 "prom 도구 설치" 단계(`bash scripts/install-prom-tools.sh`, 설치 위치 `$RUNNER_TEMP/bin`을 `GITHUB_PATH`에)

**Interfaces:**
- Produces: `check_rendered.py monitoring` — 표준 입력의 `helm template` 결과 검사, 위반 있으면 1
- Produces: `bash scripts/check-prom-rules.sh <rules_dir>` — `<rules_dir>/*.yaml` 규칙 + `<rules_dir>/tests/*.yaml` 테스트. 규칙 파일 0개면 통과. 스크립트가 추출한 규칙과 테스트 파일을 같은 임시 폴더에 두고 실행하므로, 테스트의 `rule_files`는 `[<metadata.name>.yaml]`(파일 이름만)
- Produces: `verify-argocd.sh`의 `render_monitoring()` — `gitops/root/monitoring.yaml`의 `chart: kube-prometheus-stack` targetRevision으로 `helm template monitoring kube-prometheus-stack --repo … --namespace monitoring --kube-version 1.36.5 -f gitops/platform/monitoring/values.yaml`. 파일이 아직 없으면(Task 2 전) 검사 건너뜀이 아니라 **SKIP 출력 후 통과**

- [ ] **Step 1: `check_monitoring` 테스트 먼저** (`scripts/test_check_rendered.py`, 작은 가짜 매니페스트 dict로)
  - `test_cr_resources_required`: `kind: Prometheus`/`Alertmanager`의 `spec.resources.limits.memory` 없으면 에러, `spec.containers` 안 사이드카 덮어쓰기도 같은 규칙
  - `test_disabled_scrape_targets`: 이름에 `kube-etcd`·`kube-scheduler`·`kube-controller-manager`·`kube-proxy`가 든 `Service`·`ServiceMonitor`가 있으면 에러
  - `test_disabled_rule_groups`: PrometheusRule `spec.groups[].name`이 `^(etcd|kube-scheduler|kubernetes-system-(controller-manager|scheduler|kube-proxy)|kube-apiserver-(burnrate|histogram|slos|availability)|windows)` 와 맞으면 에러 (실제 그룹 이름은 Step 4 렌더링으로 확인해 정규식 보정)
  - `test_alertmanager_urls_only_from_files`: Secret `alertmanager-monitoring-…`의 `data["alertmanager.yaml"]`(base64)을 풀어, 문자열 `discord.com`·`hc-ping.com`·`https://`가 있으면 에러, `webhook_url_file`·`url_file` 값이 Global Constraints 경로가 아니면 에러
  - `test_watchdog_route_every_minute`: 같은 설정에서 `matchers`에 `alertname="Watchdog"`인 route의 `group_interval`·`repeat_interval`이 `1m`, `group_wait`이 `0s`
  - `test_retention`: Prometheus `spec.retention == "7d"`
  - `test_monitoring_app_no_finalizer`: `check_apps`에 finalizer 달린 `monitoring` Application → 에러
- [ ] **Step 2: 실행해 실패 확인** — `uv run --script scripts/test_check_rendered.py`(파일 안 `pytest.main`) → `check_monitoring` 없음으로 FAIL
- [ ] **Step 3: `check_monitoring(docs) -> list[str]` 구현** — `check_resources(docs)` + 위 검사들. CR 컨테이너 검사는 `workloads`와 별도 함수 `custom_resources(docs)`
- [ ] **Step 4: pytest 통과**
- [ ] **Step 5: `extract_rules.py`·`check-prom-rules.sh` 작성** → 임시 폴더에 깨진 규칙(`expr: rate(`) 하나 넣고 실행 → non-zero, 지우면 0
- [ ] **Step 6: `install-prom-tools.sh`** — `promtool --version`이 3.15.1, `amtool --version`이 0.34.2면 건너뜀. 체크섬 불일치면 non-zero
- [ ] **Step 7: 워크플로·verify-argocd.sh 연결** → `bash scripts/verify-argocd.sh --static` 전부 PASS(monitoring은 SKIP), `uvx pre-commit@4.6.2 run --all-files` 통과(shellcheck·actionlint)
- [ ] **Step 8: 커밋 목록 보여 주고 커밋** → 사용자 push·PR → static-checks 녹색 → 병합

---

### Task 2: 6-2 monitoring 앱 (차트·Secret·직접 만든 규칙)

**Files:**
- Create: `gitops/root/monitoring.yaml` — `sources`: [차트 `kube-prometheus-stack` `targetRevision: 92.17.0` + `helm.releaseName: monitoring` + `valueFiles: [$values/gitops/platform/monitoring/values.yaml]`, homelab `ref: values`, homelab `path: gitops/platform/monitoring`], `syncOptions: [CreateNamespace=true, ServerSideApply=true, SkipDryRunOnMissingResource=true]`, automated prune·selfHeal, finalizer 없음
- Create: `gitops/platform/monitoring/values.yaml`
- Create: `gitops/platform/monitoring/kustomization.yaml` — `generators: [ksops-generator.yaml]`, `resources: [rules/…]`
- Create: `gitops/platform/monitoring/ksops-generator.yaml` — `apiVersion: viaduct.ai/v1`, `kind: ksops`, `files: [./secrets.sops.yaml]`
- Create: `scripts/init-monitoring-secrets.sh` — `init-host-secrets.sh`와 같은 방식: 파일 있으면 종료, `read -rsp`로 Discord·healthchecks URL 입력(`^https://discord\.com/api/webhooks/`, `^https://hc-ping\.com/` 형식 검사, 값은 출력 안 함), Grafana 비밀번호는 `openssl rand -base64 24`로 만들고 `clip.exe`로 복사(Bitwarden 저장 안내), 두 Secret을 `sops --encrypt --filename-override`로 바로 암호화
- Create: `gitops/platform/monitoring/secrets.sops.yaml` — **사용자가** Step 6에서 스크립트로 생성
- Create: `gitops/platform/monitoring/rules/node.yaml`(`WiredLinkDown`·`WiredLinkFlapping`), `rules/workloads.yaml`(`ContainerOOMKilled`·`PodRestartBurst`), `rules/backup.yaml`(`EtcdS3SnapshotStale`)
- Create: `gitops/platform/monitoring/rules/tests/{node,workloads,backup}_test.yaml`
- Create: `scripts/alert-test.sh` — 하위 명령 `fire`(가짜 `HomelabTestAlert` severity=warning을 `POST /api/v2/alerts`, `endsAt` 5분 뒤), `silence-watchdog`(`POST /api/v2/silences`, `alertname=Watchdog`, 30분), 내부에서 `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093` 를 띄우고 끝나면 정리. 응답 본문에 비밀값 없음
- Modify: `Makefile` — `grafana-ui`(port-forward 3000), `alert-test`, `.PHONY`

**Interfaces:**
- Consumes: Task 1의 `check_rendered.py monitoring`, `check-prom-rules.sh`, `PROTECTED_APPS`
- Produces: 규칙 라벨 규약 `severity: warning|critical`, 규칙 파일당 PrometheusRule 하나(`metadata.name` = 파일 이름, namespace `monitoring`)
- Produces: KSM 지표 이름 `kube_customresource_etcdsnapshotfile_created_timestamp_seconds{location=~"s3://.*"}` (Step 2에서 실제 이름 확정 → 규칙·테스트·이 줄 함께 갱신)
- Produces: ArgoCD 규칙을 위한 빈자리 없음 — Task 4가 `rules/argocd.yaml` 추가

- [ ] **Step 1: 규칙 테스트 먼저** (promtool `tests`, 수집 간격 1m)
  - backup: 마지막 S3 스냅샷 6h59m 전 → 안 울림 / 7h1m 전 → `EtcdS3SnapshotStale` firing / 지표 없음 → firing / `location`이 `file://`인 것만 최신 → firing(로컬 스냅샷은 S3 업로드 증거가 아님)
  - node: carrier 0이 1분 → 안 울림, 3분 → `WiredLinkDown` / `node_network_carrier_changes_total`이 1시간에 4번 증가 → `WiredLinkFlapping`, 3번 → 안 울림 / `device="wlp2s0"` carrier 0 → 안 울림
  - workloads: last_terminated_reason OOMKilled + 재시작 수 증가 → `ContainerOOMKilled` / 이유 OOMKilled이나 재시작 증가 없음(오래전 일) → 안 울림 / 15분에 재시작 4 → `PodRestartBurst`, 3 → 안 울림
  → `bash scripts/check-prom-rules.sh gitops/platform/monitoring/rules` FAIL(규칙 없음) 확인
- [ ] **Step 2: KSM 스냅샷 지표 확인(위험 항목)** — KSM 8.8.0 차트의 앱 버전 소스·문서에서 CustomResourceState가 RFC3339 문자열(`status.creationTime`)을 시각 값으로 바꾸는지 확인. 안 되면 **멈추고 사용자에게** spec §3.5 대안(node-exporter textfile)을 가져간다. 되면 values의 `kube-state-metrics.customResourceState`(`group: k3s.cattle.io`, `kind: ETCDSnapshotFile`, `version: v1`, 라벨 `location: [spec, location]`, 값 `[status, creationTime]`)와 `rbac.extraRules`(`etcdsnapshotfiles` get·list·watch) 작성
- [ ] **Step 3: 규칙 작성** → Step 1 테스트 PASS
- [ ] **Step 4: values 작성** — Global Constraints 수치, spec §3.1 메모리 표, `alertmanager.alertmanagerSpec.secrets: [alertmanager-receivers]`, `alertmanager.config`(receivers `discord`·`healthchecks`·`null`, route 수치), `grafana.admin.existingSecret: grafana-admin`(`userKey: admin-user`, `passwordKey: admin-password`), `grafana.persistence.enabled: false`, k3s에서 비는 기본 대시보드 끄기
- [ ] **Step 5: 정적 검사** — `bash scripts/verify-argocd.sh --static` 전부 PASS(이제 monitoring 렌더링 검사가 실제로 돎), 렌더링한 Alertmanager 설정을 임시 파일로 꺼내 `amtool check-config` 통과(검사 전용 사본에서만 `*_file` 경로를 임시 폴더의 빈 파일로 바꿔서; 이 단계도 `verify-argocd.sh --static`에 넣어 CI에서 돎), 렌더링 결과의 메모리 limits 합계를 출력해 spec 합계(약 1.7Gi)와 비교
- [ ] **Step 6: 사용자 작업** — Discord 웹훅·healthchecks.io check(Period 5분·Grace 10분·이메일) 준비 → WSL에서 `bash scripts/init-monitoring-secrets.sh` → `clear` → Grafana 비밀번호를 Bitwarden "homelab-grafana-admin"에 저장. 확인: `bash scripts/check-sops-encrypted.sh gitops/platform/monitoring/secrets.sops.yaml` 통과, `grep -c 'ENC\[' …` ≥ 4
- [ ] **Step 7: 커밋 목록 보여 주고 커밋** → 사용자 push·PR·병합
- [ ] **Step 8: 반영 확인**(조회만) — `make verify-argocd` → `monitoring` Synced·Healthy(첫 동기화가 CRD 순서로 한 번 실패하면 다음 재조정까지 기다리고 시간 기록), `kubectl -n monitoring get pods` 전부 Running, Prometheus `/api/v1/targets`에서 down 없음, `/api/v1/alerts`에 Watchdog 외 firing 없음(있으면 원인 기록 후 values·규칙으로 정리 PR), KSM 스냅샷 지표 값이 최근 S3 스냅샷 시각과 같음, `make grafana-ui` 로그인
- [ ] **Step 9: healthchecks.io에 1분마다 핑** 기록 확인(사용자 화면) → 확인 기준 3

---

### Task 3: 6-3a ArgoCD 지표 Service

**Files:**
- Modify: `gitops/platform/argocd/values.yaml` — `controller.metrics.enabled: true`, `server.metrics.enabled: true`, `repoServer.metrics.enabled: true`, 각 `serviceMonitor.enabled: false`를 명시(이유 주석: Terraform 빈 클러스터 설치, spec §3.6)
- Modify: `scripts/check_rendered.py` `check_argocd` — `kind: ServiceMonitor`가 있으면 에러 + 테스트 `test_argocd_has_no_servicemonitor`

**Interfaces:**
- Produces: Service `argocd-application-controller-metrics`(포트 이름 `http-metrics`), `argocd-server-metrics`, `argocd-repo-server-metrics` — 실제 이름·포트는 렌더링으로 확인해 Task 4에 넘김

- [ ] **Step 1: 테스트 먼저** — 가짜 매니페스트에 ServiceMonitor를 넣은 `test_argocd_has_no_servicemonitor` → 검사 추가 전 FAIL. 구현 후 PASS, 그리고 `--set controller.metrics.serviceMonitor.enabled=true`로 임시 렌더링했을 때 `check_rendered.py argocd`가 non-zero인지 확인(실제 차트 출력도 잡는지)
- [ ] **Step 2: values 수정** → `verify-argocd.sh --static` PASS
- [ ] **Step 3: 커밋 목록·커밋** → 사용자 push·PR·병합 → `kubectl -n argocd get svc | grep metrics` 3개

---

### Task 4: 6-3b ArgoCD ServiceMonitor + ArgoCD 규칙

**Files:**
- Create: `gitops/platform/monitoring/argocd-servicemonitors.yaml` — ServiceMonitor 3개(namespace `monitoring`, `namespaceSelector.matchNames: [argocd]`, Task 3 Service 라벨 선택)
- Create: `gitops/platform/monitoring/rules/argocd.yaml` — `ArgoCDSyncFailed`(`increase(argocd_app_sync_total{phase=~"Error|Failed"}[10m]) > 0`), `ArgoCDAppDegraded`(for 10m), `ArgoCDAppOutOfSync`(for 15m), 모두 warning, `name` 라벨을 설명에
- Create: `gitops/platform/monitoring/rules/tests/argocd_test.yaml`
- Modify: `gitops/platform/monitoring/kustomization.yaml`

**Interfaces:**
- Consumes: Task 3 Service 이름·라벨, Task 2 규칙 규약

- [ ] **Step 1: 테스트 먼저** — Degraded 9분 → 안 울림, 11분 → firing / OutOfSync 14분 → 안 울림, 16분 → firing / sync_total Failed 1 증가 → firing, Succeeded 증가 → 안 울림 → FAIL 확인
- [ ] **Step 2: 규칙·ServiceMonitor 작성** → 테스트·`verify-argocd.sh --static` PASS
- [ ] **Step 3: 커밋 목록·커밋** → push·PR·병합 → Prometheus targets에 argocd 3개 up, `argocd_app_info` 앱 수(5개) 확인

---

### Task 5: 6-4 API 히스토그램 drop + 전후 측정

**Files:**
- Modify: `gitops/platform/monitoring/values.yaml` — `kubeApiServer.serviceMonitor.metricRelabelings`에 `apiserver_request_duration_seconds_bucket` (+ 렌더링·실측으로 확인한 같은 계열 bucket) `action: drop`

- [ ] **Step 1: 전 측정**(Task 2 반영 후 24시간 이상) — `prometheus_tsdb_head_series`, `topk(10, count by (__name__)({__name__=~".+"}))`, `kubectl top pod -n monitoring` Prometheus 값 기록
- [ ] **Step 2: values 수정** → `verify-argocd.sh --static` PASS → 커밋 목록·커밋 → push·PR·병합
- [ ] **Step 3: 후 측정**(24시간 뒤 같은 쿼리) → 검증 기록용으로 전후 표

---

### Task 6: 6-5 검증·문서

**Files:**
- Create: `docs/verification/<날짜>-monitoring-alerts.md` — 재현·기대·실제·감지/복구 시간
- Create: `docs/adr/0010-internal-external-observability.md` — 안·밖 분리(비용), Watchdog 감시자 감시, k3s 기본 규칙 정리 + Task 5 숫자, 검토한 대안(spec §3.2·§3.4)
- Modify: `docs/adr/README.md`(목록), `docs/adr/0002-no-loki-memory-budget.md` 결과에 모니터링 실측
- Modify: `docs/superpowers/specs/2026-10-18-direction-change-design.md` §4 메모리 표 실측
- 제안만(승인 후 수정): `CLAUDE.md`(6단계 ✅·결과, 기반 메모리 실측), `docs/runbook.md`(Discord·healthchecks.io·Grafana 비밀번호 수동 작업 기록, "6단계" 남은 작업 2건 체크, monitoring 앱 일부러 지울 때 정리 절차)

- [ ] **Step 1: 테스트 알림** — `make alert-test`(fire) → Discord 수신·5분 뒤 해결 알림 수신, 시각 기록 → 확인 기준 1
- [ ] **Step 2: 실제 OOM** — `kubectl -n portfolio-lab port-forward` + `POST /chaos/memory?mb=<limit 초과>` → `ContainerOOMKilled` Discord 수신까지 시간 기록 → 확인 기준 2
- [ ] **Step 3: 감시자 감시** — `make alert-test` silence-watchdog → healthchecks.io 이메일까지 시간 기록 → silence 만료 후 핑 복구 확인 → 확인 기준 4
- [ ] **Step 4: 메모리 실측** — `kubectl top pods -n monitoring`, 노드 전체 → 확인 기준 5
- [ ] **Step 5: 문서 작성** → CLAUDE.md·runbook 변경안을 사용자에게 보여 주고 승인 후 반영
- [ ] **Step 6: 커밋 목록·커밋** → push·PR·병합
