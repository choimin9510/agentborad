[English](README.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md)

# AgentBoard

OpenAI·DeepSeek 등 로컬 Codex 대화의 진행 상황을 카드로 보여주는 macOS 플로팅 보드입니다.

## 주요 기능

- 대화별 카드에서 작업 목적, 최근 요청, 보고된 단계와 요약 확인
- 전체·진행 중·확인 필요·완료 탭
- 새 완료 표시, 일괄 읽음 처리와 완료 효과음
- 카드를 위아래로 드래그해 순서 변경, 좌우로 드래그해 숨기기. 작업이 재개되면 자동 복원
- 점 세 개 메뉴로 이름 변경, 여러 카드 동시 펼치기
- 보드 이동·크기 조절, 다른 창 경계에 붙기, 화면 가장자리로 접기

**문서는 영어·한국어·중국어 간체를 제공합니다. 현재 앱 화면은 한국어입니다.**

## 다른 Mac에 설치

**macOS 13 이상**, Apple Silicon 또는 Intel Mac과 로컬 Codex CLI 대화 기록이 필요합니다.

1. [Releases](https://github.com/choimin9510/agentborad/releases)에서 universal ZIP을 받습니다.
2. 폴더 전체를 압축 해제하고 `Install.command`를 더블클릭합니다.
3. 설치 후 앱이 열립니다. 사전 빌드 패키지는 개발 도구가 필요 없습니다.

앱과 helper는 ad-hoc 서명되어 있으나 **Apple 공증은 받지 않았습니다**. 신뢰하는 파일이 차단되면 해당 항목에 대해 macOS의 ‘그래도 열기’를 사용하세요. 설치 경로·보안 안내·제거 방법은 [설치 안내](Resources/Distribution-Install-KO.md)에 있습니다.

각 Mac의 로컬 대화만 읽으며, 기기 간 대화를 동기화하지 않습니다.

## 작동 방식

`~/.codex/sessions`, `~/.codex-ds/sessions` 및 별도로 지정한 `CODEX_HOME`의 JSONL 대화 기록을 읽습니다. 파일 변경 감지와 5초 주기 재확인으로 추가된 기록을 반영합니다. cmux·Herdr 등의 터미널 화면을 읽지 않고 동일한 로컬 대화 파일을 이용합니다.

에이전트가 정상적으로 응답을 마치면 카드가 완료됩니다. **빌드·테스트·사용자가 요청한 작업의 성공을 뜻하지 않습니다.** 서브에이전트와 지원하지 않는 제공자의 대화는 제외합니다.

현재 진행의 단계는 에이전트가 설치된 `agentboard` helper로 작성한 구조화 보고에서 가져옵니다. 일반 답변을 분석해 계획을 만들어내지 않습니다. 보고가 없으면 ‘계획 미등록’으로 표시합니다. 설치 시 지원하는 Codex 홈의 `AGENTS.md`에 보고 지침을 추가하며 새로 시작한 세션부터 적용됩니다. 보드만 다시 실행해도 기존 대화에 계획이 생기지는 않습니다.

기본으로 완료 카드는 최근 30일, 보고 없는 미완료 카드는 최근 7일만 표시합니다. 보고가 있는 미완료 작업에는 표시 기간 제한이 없습니다. 전체 기록으로 보관된 기록의 조회 범위를 넓힐 수 있으며 숨긴 카드는 별도로 관리합니다.

## 개인정보 및 제한

- 로컬 모니터링 앱입니다. 프롬프트 전송, 에이전트 중단·재개, 모델 API 호출을 하지 않습니다.
- 정리된 작업 정보와 설정은 `~/Library/Application Support/AgentBoard/agentboard.sqlite3`에 저장합니다. 전체 원문 대화와 인증 정보는 이 DB에 복사하지 않습니다.
- Codex 로그 형식 변경이나 누락·지연된 이벤트로 상태 표시가 부정확할 수 있습니다.
- 완료 알림은 기록된 응답 종료를 기준으로 하며 실제 작업 결과를 독립적으로 검증하지 않습니다.
- 제거해도 로컬 DB, Codex 대화와 인증 정보는 보존합니다.

## 빌드 및 검증

Xcode Command Line Tools와 Swift 컴파일러가 있는 Mac에서 실행합니다. SwiftUI/AppKit 앱, SQLite 코어, CLI helper를 빌드하며 패키징은 arm64와 x86_64를 모두 포함합니다.

```bash
git clone https://github.com/choimin9510/agentborad.git
cd agentborad
./scripts/build.sh
./scripts/test.sh
./scripts/integration.sh
./scripts/test-install.sh
./scripts/package.sh
./scripts/test-package.sh
```

`build/`, `.build/`, `dist/`는 생성 파일이며 Git에서 제외합니다. 테스트는 가상 대화 데이터를 사용합니다. `./scripts/install.sh`는 설치를 미리 보여주며 `--yes`로 적용합니다. `--no-agents`로 보고 지침 추가를 생략할 수 있습니다.

## 프로젝트 구성

- `Sources/AgentBoardApp`: 보드, 카드 조작과 창 동작
- `Sources/AgentBoardCore`: 대화 수집, 검증, 상태 처리와 SQLite 저장
- `Sources/agentboard`: 구조화 진행 보고 helper
- `Tests`, `fixtures`: 회귀 검사와 가상 대화
- `scripts`, `Resources`: 빌드·설치·배포 파일

## 현재 검증 상태

첫 배포는 미리보기 버전입니다. 코어 검사는 395개 중 393개가 통과하며, 정상 응답 종료 후 미읽음 표시 검사 2개가 실패합니다. `scripts/test.sh`는 이 지점에서 멈추므로 해당 실행에서 이후 검사까지 검증된 것은 아닙니다. 패키지 검증 결과는 릴리스 노트를 참고하세요.
