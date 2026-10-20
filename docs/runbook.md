# Runbook

## 1. Seed 절차 (재구축 시 사람이 하는 일)

### 미니 PC
- BIOS: State After G3 → S0, WoL Enabled, Fast Boot Disabled
- Ubuntu Server 24.04 설치, 사용자 `june`, OpenSSH 서버 포함
  - 디스크 설정에서 루트 LV를 디스크 전체로 잡기 (기본값은 100G만 잡힘)
- 관리 PC 공개키를 `~/.ssh/authorized_keys`에 등록
- Tailscale 재등록: 관리 콘솔에서 인증 키 생성(태그 `tag:server`, 1회용) →
  첫 `make host`는 `ansible/inventory/hosts.yml`의 `ansible_host`를 LAN IP(192.168.35.235)로 바꿔 실행 →
  실행 중 키 입력(또는 `TAILSCALE_AUTHKEY` 환경변수) → 끝나면 새 Tailscale IP로 inventory 갱신
- Tailscale 버전을 올릴 때도 LAN IP로 실행 (tailscaled 재시작으로 Tailscale 경유 연결이 끊김)
- k3s는 `make host`가 함께 설치한다(토큰·백업 키는 SOPS 파일에서). 이어서 관리 PC에서 `make kubeconfig` → `make verify-k3s`
- 클러스터 상태를 S3 백업으로 되돌릴 때: 미니 PC에서 `sudo k3s etcd-snapshot ls`로 이름 확인(또는 관리 PC에서
  `kubectl get etcdsnapshotfiles`) → 관리 PC에서 `make etcd-restore SNAPSHOT=<이름>` → `yes` → **1~2분 뒤 `make verify-k3s`로 확인**
  (플레이북 성공만 믿지 말 것. 복원된 etcd의 노드 상태가 이미 Ready라 kubelet 보고 전에도 통과할 수 있음)
  - etcd 스냅샷에는 볼륨 데이터(DB 파일)가 없다. 스냅샷 이후의 배포 변경은 ArgoCD(5단계 이후)가 Git 기준으로 되돌린다

### 관리 PC (Windows + WSL2)
- PowerShell: `wsl --update` → `wsl --install -d Ubuntu-24.04` → `wsl --set-default Ubuntu-24.04`
- Ubuntu: `bash scripts/bootstrap-workstation.sh` → PowerShell: `wsl --shutdown`
- `ssh-keygen -t ed25519` (passphrase 설정), `git config --global user.name/user.email` (GitHub 계정 이메일)
- repo 폴더에서 `make hooks`. 커밋은 항상 WSL에서 (Windows git에는 pre-commit 훅이 없음)
- age 키 복구: Bitwarden `homelab-sops-age` 메모의 키 파일 세 줄을 `~/.config/sops/age/keys.txt`에 저장 → `chmod 600`
  (화면에 출력하지 말 것. 백업할 때도 `clip.exe < ~/.config/sops/age/keys.txt`로 클립보드에 바로 복사)
- 미니 PC 구성: `make host-check`로 미리 보기 → `make host`로 적용. SSH 키 passphrase(agent에 1시간)와 미니 PC sudo 비밀번호를 입력
- 호스트 시크릿을 처음 만들 때만: `bash scripts/init-host-secrets.sh` (Bitwarden의 `homelab-k3s-backup` 키 입력, k3s 토큰은 자동 생성).
  이미 있으면 아무것도 하지 않음. 값 수정은 `sops ansible/inventory/host_vars/homelab/secrets.sops.yaml`

### AWS
- 평소 로그인: Identity Center 액세스 포털(URL은 Bitwarden) → `june1`. root는 결제·계정 복구에만
- 관리 PC 처음 한 번: `aws configure sso`
  - SSO session name `homelab`, start URL은 포털 URL(끝 `/` 없이), SSO region `ap-northeast-2`, scopes 기본값
  - 역할 `homelab-tfstate`, client region `ap-northeast-2`, output `json`, profile name `homelab-tfstate`
  - 브라우저 승인이 안 되면 `aws configure sso --use-device-code`
- 평소: `aws sso login --profile homelab-tfstate`
- 버킷·백업용 IAM 사용자를 다시 만들 때: AWS 콘솔(서울) CloudShell에 `scripts/aws-bootstrap.sh` 업로드 → `sha256sum`으로 파일 확인 → `bash aws-bootstrap.sh check` → `apply`
  - 액세스 키 생성과 Identity Center 권한 세트 `homelab-tfstate`(인라인 정책은 apply 출력)는 콘솔에서 직접

### Git 밖에 보관하는 비밀값 (Bitwarden, 값은 여기 적지 않음)
- AWS root 이메일·비밀번호 (MFA는 휴대폰 Google Authenticator — Bitwarden에 넣지 않음)
- AWS 액세스 포털 URL, `june1` 비밀번호
- `homelab-k3s-backup` 액세스 키 ID·비밀 액세스 키
- Bitwarden 복구 코드 (종이, Bitwarden 밖)
- `homelab-sops-age`: age 개인키 (보안 메모, 2026-10-18 교체본). 이 키로 repo의 `*.sops.yaml`을 연다
  - k3s 토큰은 Bitwarden이 아니라 SOPS 파일(`host_vars/homelab/secrets.sops.yaml`)에만 있다

## 2. 수동 작업 기록

### 2026-10-05
- 절전 차단: `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` → 1단계 플레이북으로 이관 완료
- 루트 LV 확장 100G → 466G: `lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` (일회성, 플레이북에 넣지 않음)
- Wi-Fi 제거: `/etc/netplan/50-cloud-init.yaml` → `/root/50-cloud-init.yaml.bak`,
  `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` 생성(`network: {config: disabled}`), `netplan try` → 1단계 플레이북으로 이관 완료
- WSL 공개키(`homelab-admin@wsl`)를 `authorized_keys`에 추가 → 1단계 플레이북으로 이관 완료
- 12:42~14:09 KST 유선(`enp3s0`, RTL8168h/r8169) 링크 끊김 → 강제 재부팅으로 복구
  - 원인 미확정: EEE는 꺼져 있었고 케이블·공유기는 건드리지 않음. 커널 오류 로그 없음
  - Wi-Fi를 제거해 둔 탓에 예비 경로가 없어 원격 접속이 통째로 끊겼음
- Wi-Fi 예비 경로 복구: `/root/50-cloud-init.yaml.bak`에서 Wi-Fi 부분만 꺼내
  `/etc/netplan/60-wifi-fallback.yaml`(0600, `route-metric: 600`) 생성 → `netplan try`
- NetworkManager·NetworkManager-wait-online·wpa_supplicant.service 비활성화:
  NetworkManager가 Wi-Fi 장치를 먼저 차지해 netplan의 Wi-Fi(`netplan-wpa-wlp2s0`)가 시작 실패하던 충돌 해소. 1단계 플레이북에도 반영
- 장애 전환 테스트 통과: 랜선 분리 시 기본 경로가 Wi-Fi로 전환되고 Tailscale로 재접속됨, 재연결 시 유선(metric 110)으로 복귀

### 2026-10-08
- Tailscale 관리 콘솔: 미니 PC(`kjt-home-server`) key expiry 끔
- Tailscale ACL: `tagOwners`에 `tag:server` → `autogroup:admin` 추가 (Definitions → Tags). Terraform 도입 후 이관 예정
- Tailscale 관리 콘솔: 미니 PC에 `tag:server` 부착 (Machines → Edit ACL tags)
- 외부망 확인: 개인 PC를 핫스팟에 연결, LAN 주소 ping 불가 확인 후 Tailscale로 SSH 접속 성공

### 2026-10-13 ~ 10-14 (3단계)
- AWS root: MFA 등록(Google Authenticator), root 액세스 키 없음 확인
- AWS Budgets: 월 $10 비용 예산(템플릿 기본 알림: 실제 85%·100%, 예상 100%)
- 계정 설정: 결제 정보에 대한 IAM 사용자·역할 액세스 활성화 (root로)
- IAM Identity Center: 서울 리전, 조직 인스턴스(AWS Organizations 활성화), 단일 리전, 로그인마다 MFA 요구
  - 사용자 `june1`, 권한 세트 `AdministratorAccess`(1시간)·`homelab-tfstate`(인라인 정책, 1시간) 할당
- CloudShell에서 `scripts/aws-bootstrap.sh apply`: 버킷 `june21621-homelab-tfstate`(이전 버전 90일)·`june21621-homelab-k3s-backup`(30일), IAM 사용자 `homelab-k3s-backup`(인라인 정책 `june21621-homelab-k3s-backup-rw`)
- `homelab-k3s-backup` 액세스 키 생성(설명 `mini-pc-etcd-restic`) → Bitwarden 저장, csv 다운로드 안 함
- 권한 확인(SSO 프로필 `homelab-tfstate`): tfstate 업로드·목록·삭제 성공 / backup 버킷 목록·전체 버킷 목록·버전 관리 변경 AccessDenied

### 날짜 미상 (이 기록 이전)
- Tailscale 설치 (100.124.153.34) → 2단계 플레이북으로 이관 완료

### 2026-10-18 ~ 10-20 (4단계: k3s)
- 사전 조회: k3s·Jenkins·Docker 흔적 없음. 관리 PC(Wi-Fi 192.168.35.187)에서 미니 PC LAN 주소로 통신 불가 —
  미니 PC 방화벽 로그에도 흔적 없음 → 공유기 무선 격리 추정. 관리는 Tailscale로
- age 키 생성 → Bitwarden `homelab-sops-age`. 같은 날 키 파일 출력이 작업 중 대화 기록에 노출되어 **교체**:
  새 키 생성 → `.sops.yaml` 공개키 교체 → `sops rotate --add-age <새> --rm-age <옛>`(데이터 키까지 새로) → keys.txt 교체 → Bitwarden 갱신.
  시크릿 파일은 커밋 전이었고 시크릿 값 자체는 바꾸지 않음
- Tailscale ACL(관리 콘솔 시각 편집기): ① `autogroup:member` → `tag:server`: `tcp:22`, `tcp:6443`, `icmp:*`
  ② `autogroup:member` → `autogroup:self`: 전부 ③ 기본 "All users and devices → 전부" 삭제(마지막에).
  이유: iptables `ts-input`이 ufw보다 먼저 tailscale0 트래픽을 전부 ACCEPT해서 ufw 규칙이 효과가 없었음(ADR 0004).
  결과: Tailscale 경유 10250·NodePort 차단, 22·6443·ping 허용, SSH 유지
- `kubectl delete pod default/dnstest`(확인 스크립트가 남긴 테스트 파드), `kubectl delete configmap default/drill-marker`(리허설 데이터) — 사용자 승인 후
- etcd 복원 리허설 2회: `docs/verification/2026-10-20-etcd-restore.md`

## 3. 남은 수동 작업
- [ ] 공유기 DHCP 예약: `68:1d:ef:3f:d7:fe` → `192.168.35.235`
- [x] Tailscale 관리 콘솔에서 이 기기의 key expiry 끄기 (2026-10-08)
- [ ] 7단계: Tailscale ACL(tagOwners, grants 2개)을 Terraform으로 이관하고 `tests`(22·6443 허용, 10250·80·443 차단) 추가
- [ ] Wi-Fi 예비 경로 설정(비밀번호 포함)을 SOPS + Ansible로 옮기기 (SOPS 준비됨, 지금 가능)
- [ ] 6단계: 유선 링크 끊김 알림
- [ ] 유선 LAN 기기에서 `make verify-k3s`로 LAN 쪽 포트(6443·80·443·10250·2379·2380) 차단 확인 (관리 PC는 무선 격리로 건너뜀)
- [ ] 서비스에 DB가 생기면 볼륨 데이터 백업(restic 등) 검토 — etcd 스냅샷에는 볼륨이 없음
- [ ] Google Authenticator 클라우드 백업 확인, 또는 AWS root에 두 번째 MFA 등록
- [x] 4단계: `homelab-k3s-backup` 키를 실제 업로드(etcd 스냅샷)로 검증 (2026-10-18 정기 스냅샷부터 S3 업로드, 2026-10-20 S3 사본으로 복원)
- [ ] AWS 액세스 키 교체 주기 정하기 (예: 1년)
