# homelab — 미니 PC k3s 홈랩

## 목표
N100 미니 PC를 24시간 돌아가는 **서비스 배포용 GitOps k3s 클러스터**로 구성한다.
서비스·ArgoCD·PR 프리뷰 오퍼레이터·경량 모니터링이 한 노드에서 돌고, 노드 자체는 외부(CloudWatch)에서 감시한다.
설계 상세: `docs/superpowers/specs/2026-10-18-direction-change-design.md`, 결정 이유: `docs/adr/`.
최종 목표: **OS 설치 + seed 절차 이후 명령 하나로 전체 재구축**, Git이 유일한 변경 경로.
취업 포트폴리오용이며, 설계 의도(ADR)와 장애 검증 기록(`docs/verification/`)이 결과물만큼 중요하다.

## 하드웨어 / 현재 상태
- Firebat T8, Intel N100 4코어, RAM 16GB (단일 노드)
- SSH 접속 완료 (사용자 `june`, 키 인증)
- BIOS: State After G3 → S0, WoL, Fast Boot Disabled — 사용자가 직접 설정 (원격 불가)
- OS: Ubuntu 24.04.4 LTS Server. 네트워크는 netplan + systemd-networkd가 관리. NetworkManager는 비활성화(netplan과 Wi-Fi 장치 충돌)
  - 데스크톱(lightdm)·xrdp·Cockpit 비활성화, 부팅은 `multi-user.target`
- 호스트명: `homelab`
- 디스크: SATA SSD 512GB, LVM 루트 466G (ext4)
- 네트워크: 유선 `enp3s0` 192.168.35.235 (DHCP, MAC 68:1d:ef:3f:d7:fe, metric 110), `enp1s0` 미사용
  - Wi-Fi `wlp2s0`는 예비 경로(metric 600). 유선 RTL8168h에서 원인 미상 링크 끊김 이력 있음(2026-10-05)
  - 관리 PC(Wi-Fi)에서 미니 PC LAN 주소로는 통신 불가(공유기 무선 격리 추정). 관리는 Tailscale로
- Tailscale: 100.124.153.34, 기기 이름 `kjt-home-server`, `tag:server`(key expiry 꺼짐). Ansible `tailscale` 역할로 관리(1.102.4 고정)
  - ACL(2026-10-18): member→tag:server는 tcp:22·6443·icmp만, member→self 전부. 기본 전부 허용 규칙 삭제
- k3s v1.36.5+k3s1 단일 노드 (2026-10-18 설치). kubeconfig는 관리 PC `~/.kube/homelab.yaml`
- ArgoCD(argo-cd 차트 10.10.5) 자기 관리, 메모리 약 0.3GiB (2026-11-02). 서비스: portfolio prod·lab
- 절전 차단됨 (sleep/suspend/hibernate target mask)

## 아키텍처 결정사항
| 영역 | 결정 |
|---|---|
| 코드 저장소 | GitHub (셀프호스팅 Git 없음). homelab은 **public**(2026-11-02 전환, 무료 요금제에서 ruleset·자동 병합 사용). 전환 전 전체 히스토리 gitleaks 확인 |
| 관리 PC | 개인 PC의 WSL2 Ubuntu 24.04. Ansible·Terraform·sops 실행과 관리자 키 보관은 여기서. 미니 PC에는 관리자 키·age 키·repo clone을 두지 않음. 도구는 `scripts/bootstrap-workstation.sh`로 버전 고정 설치 |
| 호스트 설정 · k3s 설치 | Ansible (`make host`) |
| k3s | 단일 노드, `--cluster-init`(embedded etcd), `--secrets-encryption`, etcd 스냅샷 6시간마다 S3 업로드, servicelb 끔, 내장 Traefik은 ClusterIP(호스트 포트 없음) |
| 외부 리소스 | Terraform — AWS(SNS·CloudWatch 알람·Budgets·IAM·SSM 활성화), GitHub(branch protection·ruleset), Cloudflare(Tunnel·DNS), Tailscale ACL, ArgoCD 부트스트랩까지만 |
| Terraform state | AWS S3 backend, `use_lockfile = true` (DynamoDB 없음) |
| 클러스터 내부 앱 | ArgoCD app-of-apps(dex·notifications 등 안 쓰는 컴포넌트 끔). 외부 앱은 Helm 차트, 직접 만든 앱은 Kustomize. gitops는 이 repo의 `gitops/` |
| 서비스 | 고정하지 않음(커넥티드카 등 필요할 때). 추가 = `gitops/apps/<이름>/` + 앱 repo에서 재사용 워크플로 호출 |
| CI | GitHub Actions 호스티드 러너 → GHCR. 앱 repo의 Actions는 homelab에 이미지 태그 **PR만** 열고, 태그 줄만 바뀐 PR은 경로 검사 통과 시 자동 병합. 쓰기 자격 증명은 GitHub App(단기 토큰). 자동 병합 조건: 필수 검사 `tag-pr-guard`(main 쪽 코드로 실행)·`static-checks`, ruleset은 Terraform(`terraform/github/`), 우회 없음. App `june21621-tag-bump`(Workflows 권한 없음) |
| CD | 클러스터 안 ArgoCD가 pull. 롤백은 git revert |
| 외부 노출 | Cloudflare Tunnel(아웃바운드만). 인바운드 포트 없음, k3s API 공개 노출 없음 |
| 내부 관측 | 경량 kube-prometheus-stack(보존 7일), Alertmanager → Discord. 로그 스택(Loki) 없음 |
| 외부 관측 | 호스트에 CloudWatch Agent + SSM 하이브리드 활성화. 노드 지표 10개 이하, 하트비트 알람(TreatMissingData=breaching) → SNS 이메일. 월 $5 이하 |
| 감시자 감시 | Alertmanager Watchdog → healthchecks.io (dead man's switch) |
| 시크릿 | SOPS + age로 확정(ADR 0003). 호스트는 Ansible `community.sops`가 관리 PC에서 복호화해 전달, 클러스터는 ArgoCD KSOPS + **클러스터 전용 age 키**(`gitops/`만 풀 수 있음, ADR 0008) |
| 원격 접속 | Tailscale (호스트에 직접 설치). **Tailscale 트래픽은 ufw를 거치지 않으므로 포트 제한은 Tailscale ACL**(ADR 0004) |
| 백업 | k3s etcd 스냅샷 → S3 (복원 리허설 2026-10-20). 볼륨 데이터(DB) 백업은 DB가 생기면 restic 검토 |
| AWS 접근 | 사람: IAM Identity Center(서울, 조직 인스턴스) + 로그인마다 MFA, 평소 root 사용 안 함. 관리 PC: SSO 프로필 `homelab-tfstate`(tfstate 버킷 객체만, 세션 1시간, 장기 키 없음). 미니 PC: IAM 사용자 `homelab-k3s-backup`(백업 버킷만, 장기 키, 원본은 Bitwarden). 버킷 `june21621-homelab-tfstate`·`june21621-homelab-k3s-backup`, 생성·설정은 `scripts/aws-bootstrap.sh`(CloudShell) |
| PR 프리뷰 | 별도 repo `pr-preview-operator`(Python, kopf). 이 repo에서는 차트만 참조 |

### 호스트 vs k3s 배치 원칙
"k3s가 통째로 안 뜰 때 이게 있어야 고칠 수 있나?" → 그렇다면 **호스트**, 아니면 **k3s**.
- 호스트(systemd): Tailscale, CloudWatch Agent·SSM Agent, etcd 스냅샷(k3s 내장 스케줄러)
- k3s: 나머지 전부
- 이미지 레지스트리는 외부(GHCR). Harbor·NFS·SonarQube 같은 부가 서버를 미니 PC에 두지 않는다

## 리소스 제약 (16GB)
- **기반 컴포넌트(k3s·ArgoCD·오퍼레이터·모니터링·cloudflared) 합계 4GB 안팎**. k3s 기반 실측 약 0.9GiB(2026-10-20), ArgoCD 약 0.3GiB(2026-11-02)
- **모든 Helm 차트에 requests/limits 지정**, 차트 버전 고정(`latest` 금지)
- Prometheus 보존 기간 7일
- PR 프리뷰: 전역 동시 개수 상한 + 프로젝트별 상한, TTL, namespace별 ResourceQuota/LimitRange/NetworkPolicy
- CloudWatch: 파드 단위 차원 수집 금지, 컨테이너 로그 전체 전송 금지, 로그 그룹 retention 7~14일

## repo 구조
```
homelab/
├── .github/workflows/  # 앱 repo가 부르는 재사용 빌드 워크플로, PR 검사(tag-pr-guard·static-checks)
├── ansible/            # 호스트 하드닝 + k3s (host_vars/*/secrets.sops.yaml은 SOPS 암호화)
├── terraform/          # AWS, GitHub, Cloudflare, Tailscale, ArgoCD 부트스트랩
├── gitops/             # ArgoCD 감시 경로 (apps, values, SOPS 암호화 secrets)
├── scripts/            # 셸/파이썬 운영 스크립트 (verify-k3s.sh 등)
├── docs/runbook.md     # seed 절차, BIOS 설정, 수동 작업 기록
├── docs/adr/           # 설계 결정 기록
├── docs/verification/  # 장애·복원 검증 기록 (재현 방법, 기대·실제, 감지·복구 시간)
└── Makefile            # make host / kubeconfig / verify-k3s / etcd-restore (최종: make up)
```

## 진행 단계 (각 단계는 확인 기준 통과 후 다음으로)
0. ✅ **repo 뼈대 + 관리 PC** — WSL2 도구 설치, `.gitignore`, pre-commit(gitleaks·SOPS 암호화 검사·shellcheck·terraform fmt)
   - 확인: 가짜 시크릿 커밋 시 차단됨 (2026-10-05)
1. ✅ **호스트 하드닝 (Ansible)** — SSH 키 인증만, 패스워드·root 로그인 차단, ufw, unattended-upgrades, 타임존 Asia/Seoul, WoL 영구 설정
   - 확인: 새 세션으로 SSH 재접속 성공, 패스워드 로그인 거부
   - 결과: 새 세션 접속, 비밀번호·root 로그인 거부, LAN에서 22 외 포트 차단, 재실행 시 changed=0 (2026-10-05)
2. ✅ **Tailscale** — 확인: 외부망(핫스팟)에서 SSH 접속
   - 결과: 핫스팟에서 SSH 접속 성공(LAN 주소 ping 불가로 외부망 확인), 설치·등록을 플레이북으로 이관 (2026-10-08)
3. ✅ **S3 버킷 + IAM (수동, runbook 기록)** — `tfstate`, `k3s-backup` 버킷 / 버킷별 최소 권한 IAM / 버전 관리·암호화·퍼블릭 차단·수명 주기
   - 결과: 버킷 2개(서울, 버전 관리·SSE-S3·퍼블릭 차단·HTTPS 강제·수명 주기 90/30일) + 백업용 IAM 사용자. 관리 PC의 SSO 프로필로 tfstate만 접근되고 다른 버킷과 버킷 설정 변경은 거부됨을 확인 (2026-10-14)
4. ✅ **k3s 설치 (Ansible) + 호스트 시크릿(SOPS)** — 방향 전환 후 "신규 1단계"
   - 확인: etcd 스냅샷이 S3에 올라감, **스냅샷 복원 1회 실제 수행**, `make verify-k3s` 통과 (LAN 포트는 유선 기기에서 미확인), 재실행 changed=0
   - 결과: 6시간 정기 스냅샷 S3 업로드, S3 사본으로 복원 2회(API 중단 약 14~17초, `docs/verification/2026-10-20-etcd-restore.md`),
     k3s 기반 메모리 약 0.9GiB. 발견: Tailscale이 ufw를 우회 → ACL로 제한, traefik 차트 40.x는 `service.spec.type`,
     복원 플레이북 대기 태스크 따옴표 버그 수정. age 키는 노출되어 교체 (2026-10-18~20)
5. ✅ **ArgoCD 부트스트랩 + GitHub Actions 파이프라인** — 이후 `kubectl apply`/`helm install` 직접 사용 금지. KSOPS, branch protection, 재사용 빌드 워크플로, 태그 PR 경로 검사
   - 확인: 앱 push → 새 파드 배포, 태그 외 줄을 바꾼 PR은 자동 병합 거부
   - 결과: 앱 병합 → prod 새 파드 8분, 사람 개입 0(2026-11-12). 위조 봇 PR 3종 병합 막힘, 워크플로 수정 push 거부,
     main 직접 push 거부(2026-11-13, `docs/verification/2026-11-13-tag-pr-guard.md`). ADR 0005~0009
6. **내부 모니터링** — 경량 kube-prometheus-stack, Alertmanager → Discord, Watchdog → healthchecks.io. 알림: OOMKilled, 재시작, ArgoCD 동기화 실패, 디스크, 마지막 S3 스냅샷 7시간 초과
   - 확인: 테스트 알림 수신, Watchdog 핑 수신
7. **CloudWatch + Terraform(AWS) + Cloudflare Tunnel** — SSM 하이브리드, 하트비트 알람 → SNS 이메일, Budgets $5, Tailscale ACL Terraform 이관
   - 확인: 에이전트를 멈추면 알람 이메일 수신, 외부에서 서비스 URL 접속(인바운드 포트 0)
8. **PR 프리뷰 오퍼레이터** — 쿼터·동시성 상한·TTL·PR 코멘트 상태 보고, README에 ApplicationSet PR Generator와 비교
9. **장애 검증 (생략 금지)** — 전원 차단(하트비트 알람까지 시간), 프리뷰 쿼터 초과, 프리뷰 OOM, ArgoCD 동기화 실패·롤백, 재부팅 후 자동 복구, 클러스터 삭제 후 재구축, ArgoCD 자기 업그레이드 실패 → `terraform apply -replace` 비상 재설치, selfHeal이 kubectl 직접 변경을 되돌림. 각각 재현·기대·실제·감지/복구 시간 기록

## 작업 규칙 (반드시 지킬 것)
- **SSH·방화벽·네트워크 설정 변경 전**: 변경 내용을 먼저 보여주고 승인받기. 기존 SSH 세션을 유지한 채 새 세션으로 접속 확인 후 다음 진행 (잠김 방지)
  - Tailscale 경유 포트 제한은 ufw가 아니라 **Tailscale ACL**에서 한다. 방화벽 변경 후에는 바깥에서 실제로 접속해 확인(`make verify-k3s`)
- **파괴적 명령 금지**: `rm -rf`, `kubectl delete`, 디스크 포맷, `terraform destroy` 등은 실행 전 반드시 확인
- **ArgoCD 이후 클러스터 변경은 Git으로만**. 클러스터에는 조회·디버깅(get, describe, logs)만
- **평문 시크릿·AWS 키·age 키·Tailscale auth key를 절대 커밋하지 않음**. `.gitignore`와 pre-commit으로 방지
- 모든 스크립트·플레이북은 **멱등**하게, 실패 시 non-zero 종료
- 셸: `set -euo pipefail`, shellcheck 통과. 명령 연결이면 셸, 로직·API·측정이면 Python(`uv`로 의존성 고정)
- 수동으로 한 작업은 즉시 `docs/runbook.md`에 기록
- git 커밋과 Ansible·Terraform 실행은 **WSL에서** (Windows git에는 pre-commit 훅이 없음). repo는 Windows 폴더(`/mnt/c/Users/kymoo/Downloads/Projects/homelab`)에 둔다
- fork PR은 승인 후에만 빌드
- WSL의 `gh`는 Windows `gh.exe`라 WSL 환경 변수(`GH_TOKEN`)가 전달되지 않는다. 토큰을 바꿔 써야 하는 스크립트는 `curl`로
- **문서 갱신**: 미정 사항이 결정되거나 단계가 끝나면, CLAUDE.md와 `docs/runbook.md` 변경안을 먼저 제안하고 승인받은 뒤 반영할 것. 승인 없이 이 두 파일을 직접 수정하지 않음

## 미정 사항 (해당 단계에서 사용자에게 확인)
- PR 프리뷰 코멘트용 GitHub App 생성 — 8단계 전, 콘솔 수동
- Terraform용 AWS 권한 세트(`homelab-terraform`: IAM·SSM·SNS·CloudWatch·Budgets) 추가 — 7단계 전
- Cloudflare에서 쓸 도메인 (구매 예정) — 7단계 전
- PR 프리뷰 앱을 미니 PC에 띄우는 동시 개수 상한 값 — 메모리 실측에서 역산
- AWS 액세스 키(`homelab-k3s-backup`) 교체 주기, 또는 SSM 하이브리드 임시 자격 증명으로 대체 가능한지(7단계에서 검증)
