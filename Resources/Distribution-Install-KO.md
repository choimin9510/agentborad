[English](Distribution-Install-EN.md) · [한국어](Distribution-Install-KO.md) · [简体中文](Distribution-Install-ZH-CN.md)

# AgentBoard 설치 안내

요구 사항: macOS 13 이상. 이 패키지는 Apple Silicon과 Intel Mac에서 공용으로 실행되는 universal 빌드입니다.

## 설치

1. 이 ZIP을 Finder에서 압축 해제합니다.
2. 폴더 최상위의 `Install.command`를 더블클릭합니다.
3. macOS가 확인되지 않은 개발자 경고를 표시하면 `시스템 설정 > 개인정보 보호 및 보안`의 보안 영역에서 `그래도 열기`를 선택합니다. Apple 공식 안내: <https://support.apple.com/en-us/102445>
4. 설치가 끝나면 AgentBoard 앱이 자동으로 열립니다.

`Install.command` 더블클릭이 되지 않으면 Terminal을 엽니다. `bash`를 입력하고 공백을 한 칸 입력한 다음, `Install.command` 파일을 Terminal 창으로 드래그하고 Enter를 누릅니다.

설치 위치:

- 앱: `~/Applications/AgentBoard.app`
- report helper: `~/.local/bin/agentboard`

개발 도구, Python, `rg`는 필요하지 않습니다.

## 사용 조건

- Codex CLI가 설치되어 있고 이 Mac에 Codex 대화 기록이 있어야 합니다.
- 기본으로 `~/.codex`와 설치 시 존재하는 `~/.codex-ds`의 Codex 세션을 함께 감시합니다. 나중에 `~/.codex-ds`를 새로 분리했다면 설치 폴더의 설치 프로그램을 다시 실행해 해당 홈의 전용 보고 지침을 추가하세요.
- AgentBoard는 해당 Mac의 로컬 Codex 세션만 표시합니다. 기기 간 동기화 기능은 없습니다.
- 이 버전은 현재 읽기 전용 모니터링 앱이며 대화 전송·중단·재개를 수행하지 않습니다.
- 전용 단계 보고는 설치 후 새로 시작하는 Codex 세션부터 적용됩니다. 기존 대화는 새 보고가 생기기 전까지 계획이 없을 수 있습니다.
- 각 카드를 위아래로 드래그해 순서를 바꿀 수 있으며, 수동 순서는 이 Mac에 저장됩니다. `자동 정렬`로 언제든 자동 정렬에 복귀할 수 있습니다.
- 앱과 helper는 ad-hoc 서명되어 있지만 Apple notarization은 적용되지 않았습니다.

`AgentBoard.app`, `agentboard` helper, `Install.command` 중 어느 대상이 차단됐는지 시스템 설정에 표시된 이름을 확인한 뒤 해당 항목만 `그래도 열기`로 허용하고 `Install.command`를 다시 실행하세요. 자동으로 quarantine 속성을 제거하거나 macOS 보안 기능을 끄지 않습니다.

## 제거

AgentBoard를 종료한 뒤, 압축을 푼 폴더에서 다음 명령을 실행합니다.

```bash
bash uninstall.sh --yes
```

제거 스크립트는 AgentBoard 앱, helper와 AgentBoard가 추가한 AGENTS 블록만 제거합니다. Codex 세션 기록, 인증, 다른 AGENTS 지침과 AgentBoard 데이터베이스는 삭제하지 않습니다.

나중에 제거하려면 `uninstall.sh`만 따로 보관하지 말고 압축 해제 폴더 전체 또는 배포 ZIP을 보관하세요. 제거 시 helper, package marker와 함께 있어야 합니다.
