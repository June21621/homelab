# 홈랩 방향 전환 설계: 서비스 배포용 k3s + 내부/외부 관측

- 작성일: 2026-10-18
- 상태: 초안 (사용자 승인 전 — 승인 전에는 미니 PC에 아무것도 설치·삭제하지 않음)
- 표기: **[사용자]** = 사용자가 정한 것, **[제안]** = 내가 정한 기본값(바꿔도 됨)

## 1. 의도

미니 PC(N100, 16GB) 한 대를 "CI/CD·모니터링 전용"에서 **서비스를 실제로 돌리는 GitOps 클러스터**로 바꾼다.
취업 포트폴리오용이며, 설계 근거(ADR)와 장애 검증 기록이 결과물만큼 중요하다.

성공 기준:
- 앱 레포에 push → GitHub Actions 빌드 → GHCR → homelab 태그 갱신 PR 자동 병합 → ArgoCD가 미니 PC에 배포
- PR을 열면 프리뷰 환경이 쿼터·동시성·TTL 안에서 생기고 상태가 PR 코멘트로 보고됨
- 노드가 죽으면 외부(CloudWatch)가, 파드·프리뷰가 죽으면 내부(Alertmanager)가 알림
- 장애 시나리오 6개의 재현·기대·실제·감지/복구 시간이 문서로 남음

비목표:
- 개인 PC k3d 워크로드 클러스터 **[사용자: 범위에서 뺌]** — 커넥티드카는 필요할 때 미니 PC 서비스로 올림
- 로그 수집 스택(Loki) **[사용자: 빼기]** — 로그는 `kubectl logs`
- 멀티 노드, HA

반목표(이렇게 되면 실패):
- 인바운드 포트 개방, k3s API를 인터넷에 노출
- 기반 컴포넌트 메모리가 4GB를 크게 넘어 서비스 자리가 없어짐
- CloudWatch 비용이 월 $5 초과
- CI 토큰 하나로 ansible/·terraform/ 코드가 바뀔 수 있음

## 2. 현재 상태 (2026-10-18 확인)

- 완료: 0단계(repo·관리 PC), 1단계(하드닝), 2단계(Tailscale), 3단계(S3·IAM·Identity Center)
- **k3s 미설치, Jenkins 설치 이력 없음** → "Jenkins 제거"는 문서 정리뿐, 클러스터 쪽은 신규 설치
- 사전 조회(2026-10-18): k3s·Jenkins·Docker 흔적 없음, 메모리 733Mi 사용. 관리 PC(Wi-Fi)에서 미니 PC LAN 주소로는
  통신 불가(공유기 무선 격리 추정) — Tailscale로만 관리
- AWS Budgets 월 $10(계정 전체, 콘솔 수동 생성)이 이미 있음

## 3. 목표 아키텍처

```
[앱 레포] --push--> GitHub Actions(호스티드) --image--> GHCR
                         |
                         +--PR(태그 한 줄)--> [homelab repo / gitops/] --경로 검사 통과--> 자동 병합
                                                   ^
미니 PC (k3s 단일 노드)                            | pull
  ArgoCD ------------------------------------------+
  서비스들 / PR 프리뷰 오퍼레이터 / kube-prometheus-stack(경량) / cloudflared
  호스트: Tailscale, CloudWatch Agent + SSM Agent(하이브리드), etcd 스냅샷→S3
       |                                   |
  Alertmanager → Discord, Watchdog → healthchecks.io     CloudWatch 알람 → SNS → 이메일
외부 → Cloudflare Tunnel(아웃바운드만) → Traefik → 서비스·프리뷰
관리 PC(WSL) → Tailscale → k3s API·SSH·Grafana
```

### 결정 사항

| 영역 | 결정 |
|---|---|
| CI | GitHub Actions 호스티드 러너. homelab에 **재사용 워크플로**(`workflow_call`)를 두고 앱 레포는 호출만 [제안] |
| 태그 갱신 | Actions는 homelab에 **PR만** 연다. `gitops/apps/*/` 이미지 태그 줄만 바뀐 PR이면 경로 검사 체크 통과 → 자동 병합. main 직접 push 금지(branch protection) [사용자] |
| 쓰기 자격 증명 | PAT 대신 **GitHub App**(homelab repo만, contents·PR 쓰기) 설치 토큰 — 단기 토큰 [제안]. App 생성은 콘솔 수동 → runbook |
| CD | ArgoCD app-of-apps, 자동 동기화 + self-heal. 롤백 = git revert [제안] |
| gitops 위치 | homelab repo 안 `gitops/` [사용자] |
| 서비스 | 고정하지 않음 [사용자]. 서비스 추가 = `gitops/apps/<이름>/` + 앱 레포에서 재사용 워크플로 호출 |
| 외부 노출 | Cloudflare Tunnel [사용자]. 도메인은 새로 구매 예정 [사용자] — 4단계 전까지 필요 |
| k3s API·관리 접근 | Tailscale에서만, 공개 노출 없음. **Tailscale 트래픽은 ufw를 거치지 않으므로(ts-input이 먼저 ACCEPT) 포트 제한은 Tailscale ACL**: member→tag:server는 tcp:22·6443·icmp만 (2026-10-18, 콘솔 수동 → 4단계 Terraform) |
| 내부 관측 | kube-prometheus-stack 경량 설정, Alertmanager → Discord [사용자], Watchdog → healthchecks.io [사용자: 유지] |
| 외부 관측 | CloudWatch Agent + SSM 하이브리드 활성화, 노드 지표 10개 이하, 하트비트 알람(TreatMissingData=breaching) → SNS 이메일 |
| 백업 | etcd 스냅샷 → S3 + 복원 1회 실제 수행 [사용자: 유지]. restic은 보류(DB가 생기면 다시 검토) |
| 클러스터 시크릿 | SOPS + age [사용자: 확정, Vault+ESO·Sealed Secrets·Ansible Vault·AWS SM 비교 후], ArgoCD repo-server에 **KSOPS** 플러그인 [제안] |
| 호스트 시크릿 | SOPS + age를 Ansible에서 먼저 사용(백업 키·SSM 활성화 코드 전달) |
| 외부 리소스 | Terraform: AWS(IAM 역할·SSM 활성화·SNS·알람·Budgets), GitHub(branch protection·ruleset), Cloudflare(Tunnel·DNS), ArgoCD 부트스트랩 |
| Terraform 구조 | 루트 모듈을 대상별로 분리(`terraform/aws-observability`, `github`, `cloudflare`, `argocd-bootstrap`), state 키 분리 [제안] |

### 호스트 vs k3s 배치 (기존 원칙 유지)
"k3s가 통째로 죽어도 있어야 하나?" → 호스트: Tailscale, CloudWatch Agent, SSM Agent, etcd 스냅샷. 나머지는 k3s.

## 4. 메모리 예산 (기반 컴포넌트 4GB 안팎)

추정치이며 1·3단계 끝에 실측해 이 표를 갱신한다. k3s 줄은 1단계 실측(2026-10-20, 설치 2일 후).

| 컴포넌트 | 추정 | 비고 |
|---|---|---|
| k3s(server+containerd+Traefik+CoreDNS+metrics-server) | **실측 ~0.9Gi** | k3s-server 659Mi, containerd 164Mi, 내장 파드 4개 ~64Mi. 호스트 전체 사용 733Mi → 1,373Mi |
| ArgoCD(server, repo-server+KSOPS, application-controller, redis) | ~700Mi | dex·notifications·applicationset 끔 [제안] |
| Prometheus | ~800Mi limit | 보존 7일, scrape 60초 |
| Grafana / Alertmanager / prometheus-operator / kube-state-metrics / node-exporter | ~350Mi | |
| cloudflared | ~50Mi | |
| PR 프리뷰 오퍼레이터 | ~100Mi | |
| **합계** | **~2.9GB** | 여유분을 둬도 4GB 이내 목표 |
| 호스트 에이전트(Tailscale, CW Agent, SSM) | ~150Mi | k3s 밖 |

나머지 약 11GB가 서비스와 프리뷰 몫이다. 프리뷰 전역 상한은 이 숫자에서 역산한다(5단계).

## 5. 단계별 계획

각 단계는 "확인" 기준을 통과해야 다음으로 간다. 미니 PC에 적용하는 명령(`make host`, `terraform apply`)은 사용자가 WSL에서 실행한다(sudo·SSO·키 passphrase).

### 1단계: k3s 설치 + Jenkins 계획 정리
- 사전 조회(읽기 전용): 메모리, 설치된 패키지, 열린 포트, 남은 Docker/컨테이너 런타임
- 문서: CLAUDE.md에서 Jenkins·개인 PC 클러스터·Loki 관련 항목 제거안 제시(승인 후 반영)
- Ansible: `sops`(age) 도입, `k3s` 역할 — 버전 고정, `--cluster-init`, `--secrets-encryption`, etcd 스냅샷 S3 업로드, Traefik 유지, API는 tailscale0에서만 허용(ufw)
- kubeconfig는 관리 PC로만 가져옴(Tailscale 주소, `.gitignore`에 이미 있음)
- 확인: 노드 Ready / S3에 스냅샷 생김 / **스냅샷 복원 1회** / 기반 메모리 실측 / 재실행 시 changed=0
- ADR: 0001 개인 PC 클러스터 제외, 0002 Loki 미도입·메모리 예산, 0003 시크릿 SOPS+age, 0004 관리 접근 제어는 Tailscale ACL
- 결과(2026-10-20): 확인 기준 모두 통과. 복원 리허설 기록 `docs/verification/2026-10-20-etcd-restore.md`

### 2단계: ArgoCD GitOps + GitHub Actions
- Terraform `argocd-bootstrap`: ArgoCD Helm 차트(버전 고정, 경량 values) + 루트 Application. 이후 `kubectl apply`/`helm install` 직접 사용 금지
- KSOPS로 SOPS 시크릿 복호화, age 키는 부트스트랩 시 1회 주입(원본 Bitwarden)
- Terraform `github`: branch protection(main 직접 push 금지, 경로 검사 체크 필수, 자동 병합 허용)
- homelab `.github/workflows/`: 재사용 빌드 워크플로(빌드·테스트·GHCR push·태그 PR), 경로 검사 워크플로
- 첫 서비스로 파이프라인 확인 (어떤 서비스로 할지는 §8)
- 확인: 앱 push → 몇 분 안에 새 파드가 뜨고, 태그 외 줄을 바꾼 PR은 자동 병합이 거부됨
- ADR: 0005 CI를 GitHub Actions로, 0006 push 대신 pull 배포, 0007 gitops 위치와 태그 갱신 경로, 0008 KSOPS

### 3단계: 내부 모니터링
- kube-prometheus-stack(버전 고정, 모든 컴포넌트 requests/limits), 보존 7일
- Alertmanager → Discord 웹훅(SOPS), Watchdog → healthchecks.io
- 기본 규칙 + 직접 추가: OOMKilled, 재시작 급증, ArgoCD 동기화 실패·Degraded, 노드 디스크, **마지막 S3 etcd 스냅샷이 7시간 넘게 없음**(업로드 실패는 지금 k3s 로그에만 남음), (5단계에서) 프리뷰 거절
- Grafana는 Tailscale에서만 접근
- 확인: Discord 테스트 알림 수신, healthchecks.io 핑 수신, Watchdog을 끊으면 healthchecks.io가 알림, 메모리 실측 갱신
- ADR: 0009 모니터링을 내부/외부로 나눈 이유

### 4단계: CloudWatch + Terraform(AWS) + Cloudflare Tunnel
- AWS 권한: 지금 SSO 프로필 `homelab-tfstate`는 tfstate만 가능 → Terraform용 권한 세트 추가 필요(§8)
- Terraform `aws-observability`(서울):
  - SSM 하이브리드용 IAM 역할(`AmazonSSMManagedInstanceCore` + `CloudWatchAgentServerPolicy`), `aws_ssm_activation`(등록 1회, 만료 짧게)
  - SNS 토픽 + 이메일 구독, 알람: 하트비트(지표 SampleCount, 60초×3, `TreatMissingData=breaching`), CPU, 메모리, 루트 디스크
  - AWS Budgets: CloudWatch 서비스 필터 월 $5 알림 [제안: 기존 계정 전체 $10 예산은 그대로 둠]
- Ansible `aws_observability` 역할(호스트): SSM Agent 설치·하이브리드 등록(활성화 코드는 SOPS 또는 실행 시 입력), CloudWatch Agent(버전 고정·서명 확인) + 설정 템플릿
  - 지표: cpu_usage_active, mem_used_percent, disk_used_percent(/), swap_used_percent, load(1m)… 10개 이하, 차원은 호스트 하나, 60초 간격
  - 로그: 처음엔 보내지 않음 [제안]. 보낼 경우 호스트 로그 파일 1~2개, retention 7일
- 비용 추정: 지표 10개 × $0.30 = $3.00, 알람 4개 × $0.10 = $0.40, SNS 이메일 무료 → 약 $3.4/월
- Terraform `cloudflare`: Tunnel + DNS(`*.preview.<도메인>`, 서비스 호스트), cloudflared는 gitops로 배포(토큰은 SOPS)
- 확인: CloudWatch 콘솔에 지표 도착, 에이전트를 멈추면 하트비트 알람 이메일 수신, Budgets 알림 설정 확인, 외부에서 서비스 URL 접속(인바운드 포트 0 확인)
- ADR: 0010 SSM 하이브리드로 인증한 이유(장기 키 없음), 0011 Cloudflare Tunnel

### 5단계: PR 프리뷰 오퍼레이터 (별도 repo `pr-preview-operator`, Python·kopf)
- 이벤트 수신: 인바운드가 없으므로 **GitHub API polling**(ETag로 rate limit 절약) [제안]
- CRD [제안]:
  - `PreviewProject`: 대상 repo, 매니페스트 경로, 프로젝트별 상한, TTL, 쿼터·LimitRange 템플릿
  - `PreviewEnvironment`: PR 하나 = 하나. 상태: Queued / Deploying / Ready / Rejected / Expired
- 동작: PR 열림 → 상한 확인 → 네임스페이스 + ResourceQuota + LimitRange + NetworkPolicy → 앱 + 경량 DB 컨테이너(시드 데이터) 배포 → URL을 PR 코멘트로. 상한 초과 → 대기(또는 설정에 따라 거절) + 코멘트. PR 닫힘·TTL 만료 → 정리 + 코멘트
- 앱 배포 방식 [제안]: 오퍼레이터가 프리뷰마다 ArgoCD `Application`을 만듦(kustomize 이미지 덮어쓰기). 동기화·헬스는 ArgoCD에 맡기고, 오퍼레이터는 ApplicationSet이 못 하는 쿼터·동시성·TTL·상태 보고에 집중
- 이미지: 앱 레포 Actions가 PR마다 `pr-<번호>-<sha>` 태그로 빌드. fork PR은 승인 후에만 빌드(기존 규칙)
- PR 코멘트용 GitHub App은 태그 갱신용과 분리 [제안]
- Prometheus 지표 노출: 활성·대기·거절 수 → 3단계 알림 규칙과 연결
- 오퍼레이터 자체와 CRD는 gitops로 배포. homelab은 차트만 참조
- README: ApplicationSet PR Generator와 비교표(쿼터, 동시성, TTL, 상태 보고)
- 확인: PR 열기·닫기·TTL 만료가 모두 코멘트와 함께 동작, 상한 초과 시 대기/거절
- ADR: 0012 프리뷰를 커스텀 오퍼레이터로(vs ApplicationSet PR Generator), 0013 polling 방식

### 6단계: 장애 검증 (생략 금지)
`docs/verification/YYYY-MM-DD-<시나리오>.md`에 시나리오마다 재현 방법·기대 동작·실제 결과·감지 시간·복구 시간·개선점을 기록한다.

| # | 시나리오 | 기대 동작 | 측정 |
|---|---|---|---|
| 1 | 미니 PC 전원 차단 | 하트비트 알람 → SNS 이메일 | 차단 시각 → 이메일 수신(예상 3~5분), 전원 복구 → 워크로드 정상화 |
| 2 | 프리뷰 동시 생성으로 상한·쿼터 초과 | 오퍼레이터 대기/거절 + PR 코멘트 + Alertmanager 알림 | 초과 PR 생성 → 코멘트·Discord 수신 |
| 3 | 프리뷰 파드 OOM | OOMKilled·재시작 감지 → Discord | 메모리 폭주 엔드포인트 호출 → 알림 |
| 4 | 잘못된 매니페스트 push | ArgoCD 동기화 실패 → Discord, git revert로 롤백 | push → 알림 → revert → Healthy |
| 5 | 노드 재부팅 | 전체 워크로드 자동 복구, 알림 해소 | 재부팅 → 모든 Application Healthy |
| 6 | 클러스터 삭제 후 재구축 [제안: 기존 11단계에서 유지] | seed + `make` 명령으로 복구 | 전체 복구 시간 |

## 6. ADR

`docs/adr/NNNN-<제목>.md`, 형식: 상태 / 맥락 / 결정 / 대안 / 결과(트레이드오프). 각 단계에서 위에 적은 번호대로 작성한다.

## 7. 문서 변경 (승인 후에만 반영)

1단계 시작 시 CLAUDE.md와 runbook 변경안을 따로 보여준다. 요지:
- 목표·아키텍처 표: Jenkins → GitHub Actions, 개인 PC 클러스터·Loki·restic 삭제, CloudWatch·SSM 추가, 웹훅 수신 항목 삭제
- 진행 단계: 4~12단계를 이 문서의 1~6단계로 교체
- 미정 사항: 알림 채널(Discord)·개인 PC 관련·Jenkins 토큰 항목 해소, 도메인은 "구매 예정"으로

## 8. 사용자 확인이 필요한 것

1. **첫 서비스**: 2단계 파이프라인을 확인할 앱. 커넥티드카를 바로 올릴지, 작은 데모 앱(웹 + Postgres, 새 repo)으로 확인할지
2. **Terraform용 AWS 권한**: Identity Center에 `homelab-terraform` 권한 세트(IAM 역할·SSM·SNS·CloudWatch·Budgets 범위)를 콘솔에서 추가해도 되는지
3. **도메인 구매 시점**: 4단계(Tunnel) 전까지
4. **GitHub App 2개**(태그 갱신용, 프리뷰 코멘트용): 콘솔에서 직접 생성(runbook 기록)
