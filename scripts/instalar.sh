#!/usr/bin/env bash
# Instala o CCDVI Drive (Nextcloud) com Podman + Quadlet/systemd, no modo rootful.
# Uso: sudo scripts/instalar.sh [--usuarios ARQUIVO.csv] [--formularios PASTA]
# Pode ser executado novamente com segurança (não sobrescreve senhas nem dados existentes).
. "$(dirname "$0")/comum.sh"
exigir_root

command -v podman >/dev/null || erro "Podman não instalado. Execute: sudo apt install -y podman"
[ -x /usr/libexec/podman/quadlet ] || erro "Quadlet não encontrado (Podman 4.4 ou superior é necessário)."

msg "1/6 Verificando porta 8081"
if porta_em_uso 8081 && ! podman container exists "$APP"; then
  erro "A porta 8081 já está em uso por outro programa. Libere-a e execute novamente."
fi
ok "porta disponível"

msg "2/6 Preparando configuração e senhas em $CONF_DIR"
install -d -m 700 "$CONF_DIR"
NOVA_SENHA_ADMIN=0
if [ ! -s "$CONF_DIR/db.senha" ]; then
  gerar_senha > "$CONF_DIR/db.senha"; chmod 600 "$CONF_DIR/db.senha"
  ok "senha do banco gerada"
fi
if [ ! -s "$CONF_DIR/admin.senha" ]; then
  if [ -n "${DRIVE_SENHA_ADMIN:-}" ]; then printf '%s' "$DRIVE_SENHA_ADMIN" > "$CONF_DIR/admin.senha"
  else gerar_senha > "$CONF_DIR/admin.senha"; fi
  chmod 600 "$CONF_DIR/admin.senha"; NOVA_SENHA_ADMIN=1
  ok "senha do administrador definida"
fi
chmod 600 "$CONF_DIR"/*.senha
if [ ! -s "$CONF_DIR/drive.env" ]; then
  IP="${DRIVE_IP:-$(hostname -I | awk '{print $1}')}"
  [ -n "$IP" ] || erro "Não foi possível detectar o IP. Defina DRIVE_IP=... e execute novamente."
  sed "s/DRIVE_IP/$IP/g" "$RAIZ/config/drive.env.example" > "$CONF_DIR/drive.env"
  chmod 600 "$CONF_DIR/drive.env"
  ok "drive.env criado para o IP $IP"
fi

msg "3/6 Criando segredos do Podman"
podman secret exists drive_db_password    || podman secret create drive_db_password "$CONF_DIR/db.senha" >/dev/null
podman secret exists drive_admin_password || podman secret create drive_admin_password "$CONF_DIR/admin.senha" >/dev/null
ok "segredos drive_db_password e drive_admin_password"

msg "4/6 Instalando unidades Quadlet em $QUADLET_DIR"
install -d "$QUADLET_DIR"
install -m 644 "$RAIZ"/deploy/quadlet/* "$QUADLET_DIR"/
systemctl daemon-reload
ok "unidades instaladas"

msg "5/6 Iniciando serviços (na primeira vez, o download e a instalação levam alguns minutos)"
systemctl start drive-db.service drive-redis.service drive-app.service
esperar_pronto 900
systemctl start drive-cron.service
ok "drive-db, drive-redis, drive-app e drive-cron em execução"

msg "6/6 Aplicando a configuração do CCDVI (política, grupos e pastas)"
"$RAIZ/scripts/configurar.sh" "$@"

IP_ATUAL="$(grep -oP '(?<=OVERWRITECLIURL=).*' "$CONF_DIR/drive.env")"
msg "Instalação concluída"
echo "    Endereço ...........: $IP_ATUAL"
echo "    Administrador ......: admin"
if [ "$NOVA_SENHA_ADMIN" = 1 ]; then
  echo "    Senha do admin .....: $(cat "$CONF_DIR/admin.senha")   (guardada em $CONF_DIR/admin.senha)"
else
  echo "    Senha do admin .....: (inalterada; veja $CONF_DIR/admin.senha)"
fi
echo "    Teste automático ...: sudo scripts/testar.sh"
