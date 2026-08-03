# macbook-mint-nvidia-revival

2010년형 하얀 MacBook을 Linux Mint 20.3 + nvidia-340 으로 되살립니다.

대상은 MacBook7,1입니다 -- Core 2 Duo P8600, GeForce 320M, 64비트 EFI. 이 기기에서 Mint
20.3을 쓸 만하게 만들려면 레거시 `nvidia-340` 드라이버가 필요한데 그게 깔끔하게 설치되지
않고, KMS 없는 GPU를 우회하는 부팅 경로도 따로 필요합니다.

[English README](README.md)

변경하는 모든 것은 백업되고 되돌릴 수 있습니다.

| 스크립트 | 역할 |
| --- | --- |
| `fix-nvidia-340.sh` | `nvidia-340` 패키지 설치를 완료시킴 |
| `set-mac-boot-splash.sh` | 맥 스타일 부팅 화면 + 부팅 시간 단축 |
| `prune-efi-entries.sh` | EFI 부트 항목 정리, shim 건너뛰기 |
| `get-mint-iso.sh` | 가장 빠른 미러에서 Mint ISO 다운로드 |

## `fix-nvidia-340.sh`

`kelebek333/nvidia-legacy` PPA의 `nvidia-340`은 커널 5.4에서 configure에 실패해 dpkg가
`iF` 상태로 남겨둡니다. PPA가 커널 5.7~6.3용 DKMS 패치 13개를 넣어놓고 `PATCH_MATCH`를
주석 처리해서 전부 무조건 적용되는 것이 원인입니다. `0006-kernel-5.14.patch`가
`nv_drm_load()`를 `extra->pdev`로 바꾸는데, 그 구조체는 `drm_legacy_pci_init()`이 없는
분기에서만 정의됩니다. 5.4에는 그 함수가 있으므로:

    nv-drm.c:352: error: dereferencing pointer to incomplete type 'struct nv_drm_extra_priv_data'

패치를 전부 끄는 건 불가능합니다 (`0001-kernel-5.7.patch`가 `uvm/`의 `vm_fault_t` 시그니처를
고침). 그래서 `0014-kernel-pre-5.14-drm-pdev.patch`를 추가해 `dev->pdev`로 폴백하게 하고,
설치된 모든 커널에 대해 모듈을 재빌드한 뒤 `dpkg --configure -a`를 실행합니다.

`/etc/grub.d/09_enable_vga`도 만듭니다. GPU 상위 브리지의 VGA-enable 비트와 GPU의 PCI
Command 레지스터를 세팅하는 GRUB `setpci` 명령을 내보냅니다. 버스 ID는 `lspci`/sysfs에서
가져오며 하드코딩하지 않습니다. 이게 없으면 nvidia-340이 GPU를 인수한 뒤 패널이 검게
나갑니다. `09_` 접두사가 중요합니다 -- GRUB이 gfxterm으로 전환하기 전에 실행되면 GRUB이
스캔아웃되지 않는 프레임버퍼에 그리게 됩니다.

root로 실행. 커널마다 모듈을 빌드하므로 5~10분 걸립니다.

## `set-mac-boot-splash.sh`

부팅 스플래시를 Yosemite 이전 맥 화면으로 바꿉니다 -- 배경 `#d8d8d8`, 애플 로고
`#6b6b6b`, 얇은 진행 바. 로고는 실행 시점에 받아옵니다 (Wikimedia Commons
`Apple_logo_black.svg`, 폴백으로 `ABATBeliever/Plymouth-theme-mac`, 또는 `LOGO=`). 대상
기기에 ImageMagick도 rsvg-convert도 없어서, 내장된 stdlib 전용 Python 헬퍼가 PNG를
디코드/트림/리컬러/리사이즈합니다. GRUB에도 같은 로고를 같은 배경, 같은 좌표로 주므로 GRUB
화면과 plymouth 화면이 이어집니다.

nvidia 드라이버가 X 시작 시 아무것도 그리지 않도록 `Option "NoLogo"`를 설정하고, GRUB의
`Loading Linux ...` 메시지도 억제합니다.

이 하드웨어에서 스플래시가 **나오게 하려면** 두 플래그가 필요합니다:

- `--fb-only` -- nvidia-340이 KMS 없는 `/dev/dri/card0`을 등록합니다. plymouth는 DRM 장치가
  있으면 DRM 렌더러로 확정하고, 실패한 뒤(`Could not get card resources`) `/dev/fb0`으로
  폴백하지 않습니다. initramfs에서 `drm.so`를 제거해 그 경로를 끊습니다.
- `--early-splash` -- 패키지의 plymouth 스크립트가 `PREREQ="udev"`라 `udevadm settle`을
  기다립니다. plymouth는 udev가 필요 없으므로 `init-top`에서 실행하게 옮깁니다.

부팅 시간 플래그:

- `--slim-initrd` -- `MODULES=dep`와, 이 기기에 없는 하드웨어의 firmware 제거(netronome
  34MB, amdgpu 32MB, radeon, liquidio, i915 …). initramfs의 firmware는 root 마운트 전에
  필요한 장치에만 의미가 있고 여기 root는 평범한 AHCI SATA입니다. 88MB -> 37MB. 기존
  initrd는 보관되고 `45_mac_fallback`이 그것으로 부팅하는 메뉴 항목을 추가합니다.
- `--fast-boot` -- initramfs에서 `drivers/md` 제거(`raid6_pq`가 로드 시 모든 구현을
  벤치마크하며 1.9초를 쓰는데 이 기기엔 RAID도 LVM도 없음), `networkd-dispatcher`와
  `NetworkManager-wait-online` 비활성화, `/boot/efi`를 `x-systemd.automount`로 전환해 그
  fsck가 `local-fs.target`을 붙잡지 않게 함.

진단용: `--dry-run`(root 없이 어디서든 애셋 생성), `--test-plymouth`,
`--debug-boot` / `--show-boot-log`, `--grub-pause N`, `--logo-hold N`. `--revert`는 전부
되돌립니다.

GRUB의 비디오가 올라오기 전 나오는 펌웨어 텍스트 커서는 없앨 수 없습니다. GRUB이 읽는 양을
줄이고 단계를 하나 없애 약 6초에서 약 4초로 줄였지만, 그 커서는 Apple EFI가 그리는 것이고
GRUB 코어가 올라오기 전에는 무엇으로도 덮을 수 없습니다.

## `prune-efi-entries.sh`

EFI 부트 항목을 라벨로 삭제하며 `BootCurrent`는 절대 건드리지 않습니다. 먼저
`efibootmgr -v` 전체를 `/var/backups/`에 저장하고, 복구용 `efibootmgr --create` 명령도
출력합니다. 항목 삭제는 파티션이나 부트로더 파일에 영향을 주지 않습니다.

`--skip-shim`은 `shimx64.efi`를 거치지 않고 `grubx64.efi`를 직접 로드하는 항목을 만들어
`BootOrder` 맨 앞에 둡니다. shim은 Secure Boot용이고 이 Mac에는 Secure Boot가 없습니다.
기존 항목은 그대로 남겨둡니다. `--timeout N`은 펌웨어 부트 매니저 타임아웃을 설정합니다
(기본 0, 원래는 2초).

기본은 dry-run이고 `--apply`로 실제 적용합니다.

## `get-mint-iso.sh`

실행하는 위치에서 실제로 가장 빠른 미러에서 Mint ISO를 받습니다 -- 지역 하드코딩이
없습니다. `linuxmint.com/mirrors.php`의 "Download mirrors" 표를 파싱하고(각 행의 국기 파일명이
ISO 3166-1 alpha-2 코드라 geo-IP 국가코드와 바로 매칭됨), 실행 위치를 geo-IP로 판별한 뒤,
약 154개 미러에 실제 ISO URL로 병렬 프로브하고, 후보만 실측 throughput을 재고, 받은 뒤
미러의 `sha256sum.txt`와 sha256을 대조합니다. 중단 후 재시작이 가능하고, `aria2c`가 있으면
여러 미러에서 병렬로, 없으면 `curl -C -`로 받습니다.

기본값은 `linuxmint-20.3-xfce-64bit.iso`입니다 -- 20.3이 nvidia-340과 맞는 5.4 커널을 쓰는
마지막 릴리스이고, Xfce가 이 하드웨어에 적합합니다. `RELEASE`, `EDITION`, `ARCH`, `OUTDIR`,
`MIRROR`로 바꿀 수 있고 `PROBE_ONLY=1`로 미러 순위만 볼 수 있습니다. root 불필요.

## AI 기여 고지

이 프로그램은 Claude와 함께 작업해 만들었습니다.
