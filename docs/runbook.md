# Runbook

## 1. Seed 절차 (재구축 시 사람이 하는 일)

### 미니 PC
- BIOS: State After G3 → S0, WoL Enabled, Fast Boot Disabled
- Ubuntu Server 24.04 설치, 사용자 `june`, OpenSSH 서버 포함
  - 디스크 설정에서 루트 LV를 디스크 전체로 잡기 (기본값은 100G만 잡힘)
- 관리 PC 공개키를 `~/.ssh/authorized_keys`에 등록

### 관리 PC (Windows + WSL2)
- PowerShell: `wsl --update` → `wsl --install -d Ubuntu-24.04` → `wsl --set-default Ubuntu-24.04`
- Ubuntu: `bash scripts/bootstrap-workstation.sh` → PowerShell: `wsl --shutdown`
- `ssh-keygen -t ed25519` (passphrase 설정), `git config --global user.name/user.email` (GitHub noreply 주소)
- repo 폴더에서 `make hooks`. 커밋은 항상 WSL에서 (Windows git에는 pre-commit 훅이 없음)

### Git 밖에 보관하는 비밀값 (비밀번호 관리자)
- (해당 단계에서 추가: age 개인키, AWS 키, Tailscale auth key, ...)

## 2. 수동 작업 기록

### 2026-10-05
- 절전 차단: `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target` → 1단계 플레이북으로 옮길 예정
- 루트 LV 확장 100G → 466G: `lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` (일회성, 플레이북에 넣지 않음)
- Wi-Fi 제거: `/etc/netplan/50-cloud-init.yaml` → `/root/50-cloud-init.yaml.bak`,
  `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` 생성(`network: {config: disabled}`), `netplan try` → 1단계로 옮길 예정
- WSL 공개키(`homelab-admin@wsl`)를 `authorized_keys`에 추가 → 1단계로 옮길 예정

### 날짜 미상 (이 기록 이전)
- Tailscale 설치 (100.124.153.34) → 2단계에서 플레이북으로 옮길 예정

## 3. 남은 수동 작업
- [ ] 공유기 DHCP 예약: `68:1d:ef:3f:d7:fe` → `192.168.35.235`
- [ ] Tailscale 관리 콘솔에서 이 기기의 key expiry 끄기
