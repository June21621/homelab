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
- `ssh-keygen -t ed25519` (passphrase 설정), `git config --global user.name/user.email` (GitHub 계정 이메일)
- repo 폴더에서 `make hooks`. 커밋은 항상 WSL에서 (Windows git에는 pre-commit 훅이 없음)
- 미니 PC 구성: `make host-check`로 미리 보기 → `make host`로 적용. SSH 키 passphrase(agent에 1시간)와 미니 PC sudo 비밀번호를 입력

### Git 밖에 보관하는 비밀값 (비밀번호 관리자)
- (해당 단계에서 추가: age 개인키, AWS 키, Tailscale auth key, ...)

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

### 날짜 미상 (이 기록 이전)
- Tailscale 설치 (100.124.153.34) → 2단계에서 플레이북으로 옮길 예정

## 3. 남은 수동 작업
- [ ] 공유기 DHCP 예약: `68:1d:ef:3f:d7:fe` → `192.168.35.235`
- [ ] Tailscale 관리 콘솔에서 이 기기의 key expiry 끄기
- [ ] 6단계: Wi-Fi 예비 경로 설정(비밀번호 포함)을 SOPS + Ansible로 옮기기
- [ ] 7단계: 유선 링크 끊김 알림
