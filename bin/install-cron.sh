#!/usr/bin/env bash
# 월~금 06:00 crontab 등록. 멱등이다(여러 번 돌려도 한 줄만 남는다).
#
#   install-cron.sh            등록/갱신
#   install-cron.sh --remove   해제
#   install-cron.sh --show     현재 상태
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"

MARK="# jira-nightly-scheduler"
ENTRY="0 6 * * 1-5 $BIN_DIR/nightly_scheduler.sh >> $LOG_DIR/cron.log 2>&1 $MARK"

show() {
  echo "── crontab ──"
  crontab -l 2>/dev/null | grep -F "$MARK" || echo "(등록되어 있지 않다)"
  echo
  echo "── cron 서비스 ──"
  printf 'enabled: %s\nactive : %s\n' \
    "$(systemctl is-enabled cron 2>&1)" "$(systemctl is-active cron 2>&1)"
}

case "${1:-install}" in
  --show)   show; exit 0 ;;
  --remove)
    crontab -l 2>/dev/null | grep -vF "$MARK" | crontab - || true
    echo "해제했다."; show; exit 0 ;;
  install) ;;
  *) echo "사용법: install-cron.sh [--show|--remove]" >&2; exit 2 ;;
esac

{ crontab -l 2>/dev/null | grep -vF "$MARK" || true; echo "$ENTRY"; } | crontab -
echo "등록했다: 월~금 06:00"
show

cat <<'EOF'

━━ WSL 에서 cron 이 실제로 뜨려면 ━━

이 환경은 /etc/wsl.conf 에 systemd=true 가 있고 cron 이 enabled+active 이므로
WSL 인스턴스가 살아있는 동안에는 06:00 에 정상 실행된다.

주의할 것은 두 가지뿐이다.

 1) Windows 절전. 절전/최대 절전에 들어가면 cron 도 멈춘다.
    화면 잠금과 덮개 닫기는 괜찮다(전원 연결 + 절전 '안 함' + 덮개 '아무것도 안 함').

 2) Windows 재부팅. 재부팅 후에는 아무도 WSL 을 깨우지 않으면 인스턴스가 뜨지 않고,
    따라서 cron 도 없다. 확실히 하려면 Windows 작업 스케줄러에 로그온 시 트리거로
    아래를 등록해 WSL 을 깨워 두면 된다(systemd 가 PID 1 로 남아 계속 살아있다).

    프로그램: wsl.exe
    인수    : -d Ubuntu -- true

실행 확인:
    tail -f <이 저장소>/logs/cron.log
EOF
