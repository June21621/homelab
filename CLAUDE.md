# homelab — 미니 PC k3s 홈랩

## 목표
N100 미니 PC를 24시간 돌아가는 **CI/CD · 모니터링 · PR 프리뷰(dev) 클러스터**로 구성한다.
무거운 작업은 개인 PC에서 돌리고, 미니 PC는 관리·감시 역할만 맡는다.
개인 PC의 워크로드 클러스터(k3d, 커넥티드카 데모·트러블슈팅용)에 대한 CI/CD와 모니터링도 미니 PC가 맡는다.
최종 목표: **OS 설치 + seed 절차 이후 명령 하나로 전체 재구축**, Git이 유일한 변경 경로.

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
- Tailscale: 100.124.153.34 (설치됨)
- 절전 차단됨 (sleep/suspend/hibernate target mask)

## 아키텍처 결정사항
| 영역 | 결정 |
|---|---|
| 코드 저장소 | GitHub (셀프호스팅 Git 없음). private로 시작, public 전환 전 전체 히스토리 gitleaks 스캔 |
| 관리 PC | 개인 PC의 WSL2 Ubuntu 24.04. Ansible·Terraform·sops 실행과 관리자 키 보관은 여기서. 미니 PC에는 관리자 키·repo clone을 두지 않음. 도구는 `scripts/bootstrap-workstation.sh`로 버전 고정 설치 |
| 호스트 설정 · k3s 설치 | Ansible |
| k3s | 단일 노드, `--cluster-init`(embedded etcd), etcd 스냅샷 S3 업로드, `--secrets-encryption`, 내장 Traefik 유지 |
| 외부 리소스 | Terraform — GitHub(repo 설정, 웹훅, branch protection), Cloudflare(Tunnel), Tailscale ACL, ArgoCD 부트스트랩까지만 |
| Terraform state | AWS S3 backend, `use_lockfile = true` (DynamoDB 없음) |
| 클러스터 내부 앱 | ArgoCD app-of-apps. 외부 앱은 Helm 차트, 직접 만든 앱은 Kustomize |
| 개인 PC 워크로드 클러스터 | Docker Desktop 위 k3d(k3s). 커넥티드카 텔레메트리(앱 + Kafka·MongoDB·Redis + Traefik, 스토리지 local-path). 관리용 WSL과 분리. 꺼져 있는 시간이 많은 것을 전제로 설계 |
| CI | Jenkins (kubernetes 플러그인으로 빌드마다 agent pod), 이미지는 GHCR. 개인 PC 클러스터 앱도 Jenkins → GHCR → gitops 태그 갱신 → ArgoCD 배포 (Jenkins는 클러스터 권한 없음) |
| 웹훅 수신 | Cloudflare Tunnel로 Jenkins 웹훅 경로만 노출 |
| 모니터링 | kube-prometheus-stack, Loki + Alloy, Alertmanager → 메신저 알림. 개인 PC 클러스터는 Alloy가 지표·로그를 미니 PC로 전송. 개인 PC가 꺼진 것은 장애로 알리지 않음 (켜져 있는데 서비스가 죽었을 때만 알림) |
| 감시자 감시 | Alertmanager Watchdog → healthchecks.io (dead man's switch) |
| 시크릿 | 기본 SOPS + age (Vault + ESO는 미정, 아래 참고) |
| 원격 접속 | Tailscale (호스트에 직접 설치) |
| 백업 | k3s etcd 스냅샷 + restic → S3 (버킷·IAM 사용자 용도별 분리) |
| PR 프리뷰 | 별도 repo `pr-preview-operator`(Python, kopf). 이 repo에서는 차트만 참조 |

### 호스트 vs k3s 배치 원칙
"k3s가 통째로 안 뜰 때 이게 있어야 고칠 수 있나?" → 그렇다면 **호스트**, 아니면 **k3s**.
- 호스트(systemd): Tailscale, WoL 스크립트(개인 PC 깨우기), etcd 스냅샷·restic 백업
- k3s: 나머지 전부

### 미니 PC vs 개인 PC 배치 원칙
- 앱이 **실행 중에 의존하는 것**(스토리지, DB, 인그레스)은 앱과 같은 곳(개인 PC)에 둔다.
  미니 PC나 네트워크가 끊겨도 앱이 멈추지 않게 하기 위함
- **빌드·배포·관찰 도구**(Jenkins, ArgoCD, 모니터링)는 미니 PC
- 이미지 레지스트리는 외부(GHCR). Harbor·NFS·SonarQube 같은 부가 서버를 미니 PC에 두지 않는다

## 리소스 제약 (16GB)
- **모든 Helm 차트에 requests/limits 지정**, 차트 버전 고정(`latest` 금지)
- Jenkins 컨트롤러 힙 제한, 동시 빌드 1~2개
- Prometheus·Loki 보존 기간 7~15일
- PR 프리뷰: 전역 동시 개수 상한 + 프로젝트별 상한, TTL, namespace별 ResourceQuota/LimitRange/NetworkPolicy

## repo 구조
```
homelab/
├── ansible/        # 호스트 하드닝 + k3s
├── terraform/      # GitHub, Cloudflare, Tailscale, ArgoCD 부트스트랩
├── gitops/         # ArgoCD 감시 경로 (apps, values, SOPS 암호화 secrets)
├── scripts/        # 셸/파이썬 운영 스크립트
├── docs/runbook.md # seed 절차, BIOS 설정, 수동 작업 기록
└── Makefile        # make up / make rebuild 진입점
```

## 진행 단계 (각 단계는 확인 기준 통과 후 다음으로)
0. ✅ **repo 뼈대 + 관리 PC** — WSL2 도구 설치, `.gitignore`, pre-commit(gitleaks·SOPS 암호화 검사·shellcheck·terraform fmt)
   - 확인: 가짜 시크릿 커밋 시 차단됨 (2026-10-05)
1. ✅ **호스트 하드닝 (Ansible)** — SSH 키 인증만, 패스워드·root 로그인 차단, ufw, unattended-upgrades, 타임존 Asia/Seoul, WoL 영구 설정
   - 확인: 새 세션으로 SSH 재접속 성공, 패스워드 로그인 거부
   - 결과: 새 세션 접속, 비밀번호·root 로그인 거부, LAN에서 22 외 포트 차단, 재실행 시 changed=0 (2026-10-05)
2. **Tailscale** — 확인: 외부망(핫스팟)에서 SSH 접속
3. **S3 버킷 + IAM (수동, runbook 기록)** — `tfstate`, `k3s-backup` 버킷 / 버킷별 최소 권한 IAM / 버전 관리·암호화·퍼블릭 차단·수명 주기
4. **k3s 설치 (Ansible)** — 위 옵션 포함
   - 확인: etcd 스냅샷이 S3에 올라감, **스냅샷 복원 1회 실제 수행**
5. **ArgoCD 부트스트랩 + app-of-apps** — 이후 `kubectl apply`/`helm install` 직접 사용 금지
6. **시크릿 (SOPS)**
7. **모니터링** — 확인: 테스트 알림 수신, Watchdog 핑 수신
8. **Cloudflare Tunnel**
9. **Jenkins + 첫 파이프라인** — 샘플 앱(Stream Walkway)으로 push → 빌드 → GHCR → 매니페스트 갱신 → ArgoCD 배포 end-to-end
10. **PR 프리뷰 오퍼레이터 연동**
11. **장애 검증** — 전원 차단, 재부팅, 디스크 풀, 클러스터 삭제 후 재구축 (복구 시간 기록)
12. **개인 PC 워크로드 클러스터 연동** (5·7·9단계 이후) — ArgoCD에 개인 PC k3d를 외부 클러스터로 등록(Tailscale 경유), Alloy 원격 전송, 커넥티드카 파이프라인
    - 확인: 커넥티드카 push → 빌드 → GHCR → ArgoCD가 개인 PC에 배포 / Grafana에서 개인 PC 클러스터 지표·로그 확인 / 개인 PC를 꺼도 장애 알림이 오지 않음

## 작업 규칙 (반드시 지킬 것)
- **SSH·방화벽·네트워크 설정 변경 전**: 변경 내용을 먼저 보여주고 승인받기. 기존 SSH 세션을 유지한 채 새 세션으로 접속 확인 후 다음 진행 (잠김 방지)
- **파괴적 명령 금지**: `rm -rf`, `kubectl delete`, 디스크 포맷, `terraform destroy` 등은 실행 전 반드시 확인
- **ArgoCD 이후 클러스터 변경은 Git으로만**. 클러스터에는 조회·디버깅(get, describe, logs)만
- **평문 시크릿·AWS 키·age 키·Tailscale auth key를 절대 커밋하지 않음**. `.gitignore`와 pre-commit으로 방지
- 모든 스크립트·플레이북은 **멱등**하게, 실패 시 non-zero 종료
- 셸: `set -euo pipefail`, shellcheck 통과. 명령 연결이면 셸, 로직·API·측정이면 Python(`uv`로 의존성 고정)
- 수동으로 한 작업은 즉시 `docs/runbook.md`에 기록
- git 커밋과 Ansible·Terraform 실행은 **WSL에서** (Windows git에는 pre-commit 훅이 없음). repo는 Windows 폴더(`/mnt/c/Users/kymoo/Downloads/Projects/homelab`)에 둔다
- fork PR은 승인 후에만 빌드
- **문서 갱신**: 미정 사항이 결정되거나 단계가 끝나면, CLAUDE.md와 `docs/runbook.md` 변경안을 먼저 제안하고 승인받은 뒤 반영할 것. 승인 없이 이 두 파일을 직접 수정하지 않음

## 미정 사항 (해당 단계에서 사용자에게 확인)
- 시크릿: SOPS로 확정할지, Vault + ESO로 갈지 (Vault는 재부팅 시 unseal 필요)
- 알림 채널: Discord / Slack
- Cloudflare에서 쓸 도메인
- 개인 PC의 MAC 주소·IP (WoL 대상)
- PR 프리뷰 앱을 미니 PC에 띄우는 동시 개수 상한 값
- 개인 PC k3d API를 미니 PC에 여는 방식 (Windows Tailscale IP + 인증서 tls-san 등)과 ArgoCD에 줄 권한 범위
- gitops/ 안에서 클러스터별 경로 구분 방식 (미니 PC / 개인 PC) — 5단계에서 결정
