#!/usr/bin/env bash
# Remove o CCDVI Drive: serviços, contêineres e unidades Quadlet.
# Por padrão PRESERVA os dados (volumes) e as senhas em /etc/ccdvi-drive.
# Uso: sudo scripts/desinstalar.sh            -> remove serviços, mantém dados
#      sudo scripts/desinstalar.sh --tudo     -> remove TAMBÉM dados, segredos e senhas (irreversível)
. "$(dirname "$0")/comum.sh"
exigir_root

TUDO=0
[ "${1:-}" = "--tudo" ] && TUDO=1
if [ "$TUDO" = 1 ] && [ "${DRIVE_CONFIRMAR:-}" != "sim" ]; then
  read -rp "Isto APAGA todos os arquivos e usuários do CCDVI Drive. Digite APAGAR para continuar: " resp
  [ "$resp" = "APAGAR" ] || erro "Cancelado."
fi

msg "Parando serviços"
systemctl stop drive-cron.service drive-app.service drive-redis.service drive-db.service 2>/dev/null || true
for c in drive-cron drive-app drive-redis drive-db; do podman rm -f "$c" >/dev/null 2>&1 || true; done
ok "serviços parados e contêineres removidos"

msg "Removendo unidades Quadlet"
rm -f "$QUADLET_DIR"/ccdvi-drive.network "$QUADLET_DIR"/drive-*.container "$QUADLET_DIR"/drive-*.volume
systemctl daemon-reload 2>/dev/null || true
ok "unidades removidas"

if [ "$TUDO" = 1 ]; then
  msg "Removendo dados, rede, segredos e senhas"
  podman volume rm -f drive-db drive-html >/dev/null 2>&1 || true
  podman network rm -f ccdvi-drive >/dev/null 2>&1 || true
  podman secret rm drive_db_password drive_admin_password >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR"
  ok "tudo removido"
else
  echo "    Dados preservados (volumes drive-db e drive-html; senhas em $CONF_DIR)."
  echo "    Para reinstalar mantendo os dados: sudo scripts/instalar.sh"
fi
