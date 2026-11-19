# QNAP 매니저

느린 QTS 웹 화면 대신 쓰는 가벼운 QNAP NAS 관리 앱입니다. **Windows**와 **Android**를 지원하고, 여러 대의 NAS를 등록해 전환할 수 있습니다.

| 화면 | 기능 |
|---|---|
| 대시보드 | CPU·메모리·온도·가동 시간, 네트워크 속도, 볼륨 사용량, 디스크 SMART 상태 (5초마다 갱신) |
| 파일 | 공유 폴더 탐색, 검색, 업로드, 다운로드(폴더는 zip), 새 폴더, 이름 변경, 이동, 복사, 삭제, 다중 선택 |
| Docker | Container Station 컨테이너 목록, 시작·중지·재시작, 로그 보기 |
| 다운로드 | Download Station 작업 목록·진행률, URL/마그넷 추가, 시작·정지·삭제 |
| 설정 | NAS 관리, 자동 업데이트, API 진단 |

- NAS마다 **주소 2개**를 넣을 수 있습니다. 주소 1(내부망)을 먼저 시도하고, 안 되면 주소 2(외부 DDNS)로 연결합니다.
- 비밀번호와 토큰은 OS 보안 저장소(Android Keystore, Windows 자격 증명)에 암호화해 저장합니다.
- 2단계 인증 계정을 지원합니다.

## 처음 설정 (한 번만)

### 1. GitHub 시크릿 등록 (Android 서명 키)

저장소 **Settings → Secrets and variables → Actions → New repository secret**에서 두 개를 등록합니다.

| 이름 | 값 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 전달받은 `ANDROID_KEYSTORE_BASE64.txt` 내용 |
| `ANDROID_KEYSTORE_PASSWORD` | 전달받은 `ANDROID_KEYSTORE_PASSWORD.txt` 내용 |

> ⚠️ `release.jks`와 비밀번호는 따로 안전한 곳에 백업하세요. 잃어버리면 Android 앱을 지우고 다시 설치해야 합니다.

### 2. 빌드

`main` 브랜치에 푸시하면 **Actions**가 자동으로 빌드하고 `v1.0.N` Release를 만듭니다. Actions 탭에서 **Run workflow**로 직접 실행할 수도 있습니다.

### 3. 업데이트용 토큰 만들기

저장소가 비공개라서 앱이 Release를 읽으려면 읽기 전용 토큰이 필요합니다.

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. Repository access: **Only select repositories** → 이 저장소만 선택
3. Permissions: **Contents → Read-only** (다른 권한은 주지 않음)
4. 만료 기간은 원하는 대로 (만료되면 앱에서 새 토큰으로 교체)

### 4. 설치

- **Android**: Release에서 `qnap-manager-android.apk`를 받아 설치합니다. "출처를 알 수 없는 앱 설치"를 허용해야 합니다.
- **Windows**: `qnap-manager-windows.zip`을 **쓰기 가능한 폴더**(예: `%LOCALAPPDATA%\QnapManager`)에 풀고 `qnap_manager.exe`를 실행합니다. `Program Files`에 두면 자동 업데이트가 파일을 덮어쓰지 못합니다.

앱에서 **설정 → GitHub 토큰**에 3번 토큰을 넣으면, 이후 실행할 때마다 새 버전을 확인합니다.

## NAS 주소 넣는 법

| 상황 | 주소 1 | 주소 2 |
|---|---|---|
| 집 NAS (집·밖 모두 사용) | `http://192.168.0.10:8080` | `https://내DDNS:포트` |
| 외부에 있는 NAS | `https://내DDNS:포트` | (비움) |

- myQNAPcloud 주소를 쓸 때는 **포트포워딩된 주소**를 넣으세요. `qlink.to` 릴레이를 거치면 매우 느립니다.
- 보안을 위해 외부 접속은 HTTPS 포트(기본 443 또는 8081)를 권장합니다.

## 문제 해결

어떤 기능이 안 되면 **설정 → API 진단 → 진단 실행 → 복사**를 눌러 결과를 전달해 주세요. NAS 펌웨어나 앱 버전마다 API 응답이 조금씩 달라서 이 결과로 바로 고칠 수 있습니다. 세션 ID는 자동으로 지워집니다.

## 개발

```bash
flutter pub get
flutter test
flutter run -d windows
```
