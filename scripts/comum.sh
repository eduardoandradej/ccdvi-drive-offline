#!/usr/bin/env bash
# Funções e variáveis compartilhadas pelos scripts do CCDVI Drive.
# Não executar diretamente: é carregado pelos demais scripts com ". comum.sh".

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DIR=/etc/ccdvi-drive
QUADLET_DIR=/etc/containers/systemd
URL="${DRIVE_URL:-http://127.0.0.1:8081}"
APP=drive-app
DB=drive-db

GRUPOS=(DVI-Todos DVI-Comando DVI-AnteMortem DVI-PostMortem DVI-TIC)
PASTA_FORMULARIOS="Formulários e Referências"

msg()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
erro() { printf '\n[ERRO] %s\n' "$*" >&2; exit 1; }

exigir_root() {
  [ "$(id -u)" -eq 0 ] || erro "Execute com sudo (ex.: sudo $0)."
}

gerar_senha() {
  python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(__import__("sys").argv[1]))))' "${1:-24}"
}

porta_em_uso() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

occ() {
  podman exec -u www-data "$APP" php occ --no-interaction "$@"
}

senha_admin() {
  [ -r "$CONF_DIR/admin.senha" ] || erro "Arquivo $CONF_DIR/admin.senha não encontrado. Execute scripts/instalar.sh."
  cat "$CONF_DIR/admin.senha"
}

# Codifica um caminho para uso em URL (mantém as barras).
url_caminho() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

# Chamada WebDAV/OCS autenticada como admin. Uso: dav_admin MÉTODO caminho [args extras do curl]
dav_admin() {
  local metodo="$1" caminho="$2"; shift 2
  curl -s -o /dev/null -w '%{http_code}' -u "admin:$(senha_admin)" -X "$metodo" \
    "$URL/remote.php/dav/files/admin/$(url_caminho "$caminho")" "$@"
}

ocs_admin() {
  local metodo="$1" caminho="$2"; shift 2
  curl -s -u "admin:$(senha_admin)" -H 'OCS-APIRequest: true' -X "$metodo" \
    "$URL/ocs/v2.php/$caminho?format=json" "$@"
}

# Aguarda o Nextcloud responder como instalado e fora de manutenção.
esperar_pronto() {
  local limite="${1:-900}" inicio=$SECONDS
  printf '    aguardando o Nextcloud ficar pronto'
  while (( SECONDS - inicio < limite )); do
    if curl -s "$URL/status.php" 2>/dev/null | grep -q '"installed":true'; then
      if podman exec -u www-data "$APP" php occ status --output=json 2>/dev/null | grep -q '"maintenance":false'; then
        printf ' pronto.\n'
        return 0
      fi
    fi
    printf '.'
    sleep 5
  done
  printf '\n'
  erro "O Nextcloud não ficou pronto em ${limite}s. Veja: sudo podman logs $APP"
}
