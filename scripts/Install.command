#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

finish_with_error() {
    status=$?
    echo
    echo "AgentBoard 설치에 실패했습니다. 위 오류를 확인하세요." >&2
    if [[ -t 0 ]]; then
        read -r -p "Enter를 누르면 창을 닫습니다." _
    fi
    exit "$status"
}
trap finish_with_error EXIT

"$ROOT/install.sh" --prebuilt --yes
trap - EXIT

echo
if open "$HOME/Applications/AgentBoard.app"; then
    echo "AgentBoard 설치와 앱 실행이 완료되었습니다."
else
    echo "AgentBoard 설치는 완료됐지만 앱을 자동으로 열지 못했습니다." >&2
    echo "Launchpad 또는 ~/Applications에서 AgentBoard를 직접 여세요." >&2
fi
if [[ -t 0 ]]; then
    read -r -p "Enter를 누르면 창을 닫습니다." _
fi
