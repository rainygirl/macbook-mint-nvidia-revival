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
| `install-mcp89-backlight.sh` | 드라이버 교체 후 죽은 F1/F2 밝기 키 복구 |
| `fix-screen-blank.sh` | 유휴 시간 후 화면이 꺼지게 함 |
| `nv-backlight.py` | 백라이트 레지스터를 찾고 조작하는 유저스페이스 도구 (진단용) |
| `boot-nouveau-probe.sh` | 비교 대조군으로 nouveau를 한 번만 부팅 |
| `fix-brightness-keys.sh` | 대체됨 -- 진단과 `--revert` 때문에 남겨둠 |
| `set-mac-boot-splash.sh` | 맥 스타일 부팅 화면 + 부팅 시간 단축 |
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

## `install-mcp89-backlight.sh`

nouveau가 nvidia-340으로 바뀌면 F1/F2가 밝기를 못 바꿉니다. 키가 죽은 게 아니라 키가 조작할
대상이 사라진 것입니다. nouveau의 KMS 드라이버는 `/sys/class/backlight/nv_backlight`를
등록하고 xfce4-power-manager가 거기에 직접 씁니다. nvidia-340은 nouveau를 블랙리스트에 넣고
KMS 없는 DRM 노드를 등록하므로 backlight 장치가 하나도 남지 않습니다.

그럴듯한 경로 세 가지가 전부 막다른 길이고, 스크립트는 그것들을 제거합니다:

- **nvidia-340 자체의 백라이트.** 없습니다. `strings nvidia_drv.so`에 나오는 건
  `%s/%s/brightness`, `Unable to find the brightness file path under`,
  `EnableACPIBrightnessHotkeys`뿐입니다 - *읽기만* 하고 만들지 않습니다.
  `EnableBrightnessControl`이라는 문자열은 없습니다. `RegistryDwords`는 모르는 키를 조용히
  무시하고, Xorg 로그의 `(**)`는 "사용자가 지정함"이지 "드라이버가 이해함"이 아닙니다.
- **`apple_bl`.** 이 기기에 있는 `APP0002`에 매칭되고, MCP89 호스트 브리지라 nvidia 경로도
  맞습니다. 그런데 `apple_bl_add()`는 마지막에 레거시 I/O 포트 `0x52f`로 하드웨어 응답을
  확인하고, 응답이 없으면 **로그 한 줄 없이** `-ENODEV`로 빠집니다. "this may not work under
  EFI"라는 자체 주석이 붙어 있고, 이 맥은 EFI로 부팅합니다. `acpi_backlight=vendor`는
  무관합니다 - 거기까지 가지도 못합니다.
- **`acpi_video`.** `acpi_backlight=` 유무와 관계없이 이 기기에선 아무것도 등록하지 않습니다.

그래서 모듈이 PWM을 직접 제어합니다. 레지스터는 nouveau 헤더에서 베낀 게 아닙니다 - nouveau의
Tesla 상수는 `0x61c880`에 divisor `+0x84`인데 여기선 둘 다 0입니다. nouveau로 부팅해
`nv_backlight`를 바꾸면서 BAR를 차분해서 찾았습니다 (`nv-backlight.py --diff`):

    0x61c080   period. 읽기만 하고 쓰지 않음 (nouveau 2966, nvidia-340 24557)
    0x61c084   bit 31  write-only 래치. 없이 쓰면 값은 저장되지만 PWM에 안 닿음.
                       읽기는 이미 nv_backlight와 일치했는데 쓰기만 안 먹던 이유
               bit 30  하드웨어가 유지
               bits 0. duty

밝기는 그 시점 period에 대한 백분율로 계산하므로, period가 서로 다른 두 드라이버에서 같은
코드가 동작합니다.

결과물은 `/sys/class/backlight/mcp89_backlight`입니다. `nv_backlight`가 있던 시절과 똑같이
xfce4-power-manager가 F1/F2를 직접 처리합니다 - 커스텀 키 바인딩도, 헬퍼도, sudo도 없습니다.
DKMS `AUTOINSTALL`이라 커널 업데이트마다 자동 재빌드되며, nvidia-340과 같은 방식입니다.
`PMC_BOOT_0`의 칩셋이 `0xaf`가 아니면 로드를 거부하고, nouveau가 GPU를 잡고 있으면 물러납니다.

`--uninstall`로 되돌립니다.

## `fix-screen-blank.sh`

유휴 상태에서 화면이 안 꺼지는 원인은 `xscreensaver`입니다. 자기 `dpmsEnabled`가 False면
`xset -dpms`를 실행합니다 - `xset q`에 타임아웃 값은 멀쩡한데 `DPMS is Disabled`가 같이 나오는
상태가 그것입니다. xfce4-power-manager 타이머만 고쳐봐야 xscreensaver가 다음에 자기 설정을
적용할 때 되돌립니다. 그래서 `~/.xscreensaver`를 먼저 고치고, 그 다음 xfconf 키를 맞추고,
마지막에 `xset +dpms`로 어느 데몬도 기다리지 않고 즉시 적용합니다.

`--diagnose`는 아무것도 바꾸지 않고 root도 필요 없습니다. `--test`는 DPMS를 즉시 끕니다 -
"드라이버가 이 패널을 블랭킹 못 한다"와 "유휴 타이머가 안 돈다"를 가르는 유일한 방법입니다.
설정을 아무리 읽어도 이건 구분되지 않습니다.

## `nv-backlight.py`

위 레지스터를 찾아낸 도구입니다. 다른 칩에서 다시 찾을 때 쓰는 방법 자체라 남겨둡니다.
`--probe`는 BAR0을 읽기 전용으로 훑고 `PMC_BOOT_0`으로 매핑이 살아있음을 증명합니다.
`--pairs`는 상수를 믿는 대신 PWM 쌍의 *모양*을 찾습니다. `--sweep`은 후보를 하나씩 잠깐
구동하고 전부 복원합니다. `--diff`가 결론을 낸 것으로, 동작하는 백라이트가 있는 상태에서
밝기를 바꾸고 어느 레지스터가 따라 움직였는지 보고합니다. 저절로 움직이는 것은 대조 패스로
걸러냅니다.

BAR0 접근은 `/sys/bus/pci/devices/<addr>/resource0`을 통하므로 `/dev/mem`이 필요 없고
`iomem=strict`의 영향도 받지 않습니다. 읽고 쓰기는 Python 슬라이싱이 아니라 ctypes `uint32`
배열로 합니다 - 슬라이싱은 `memcpy`로 복사하는데 바이트 단위 로드를 써도 되는 반면 MMIO는
정렬된 32비트 접근이 필요합니다.

## `boot-nouveau-probe.sh`

같은 커널을 `modprobe.blacklist=nvidia,...`로 한 번만 부팅해 nouveau가 GPU를 잡게 하는 GRUB
항목을 추가합니다. GRUB 메뉴는 띄우지 않습니다 - `09_enable_vga`의 setpci 쓰기가 grub.cfg
파싱 중에 실행되고, 그 이후 GRUB은 스캔아웃되지 않는 프레임버퍼에 그리기 때문에 "보이는"
메뉴는 실제로는 *보이지 않는* 프롬프트이고 아무 키나 누르면 거기서 멈춥니다. 대신
`grub-editenv set next_entry`로 미리 선택합니다. 00_header가 생성하는 전처리부가 이것을 읽고
스스로 지우면서 부팅하므로, 일회성이고 자기소멸적이며 전원을 껐다 켜면 원래대로 돌아옵니다.

## `fix-brightness-keys.sh`

첫 시도였고 `install-mcp89-backlight.sh`로 대체됐습니다. 후자가 이 스크립트의 `--revert`를
호출해 설정을 되돌립니다. `--diagnose`는 backlight 장치, 드라이버 상태, `apple_bl` 바인드
결과, `hid_apple`의 `fnmode`를 한 번에 보여줘서 여전히 가장 빠른 확인 수단입니다.

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
