#!/usr/bin/env bash
# Restaura um backup gerado por scripts/backup.sh sobre uma instalação em funcionamento
# (a mesma ou uma nova, feita com scripts/instalar.sh). SUBSTITUI todo o conteúdo atual do Drive.
# Uso: sudo scripts/restaurar.sh <arquivo .tar ou .tar.gpg>
. "$(dirname "$0")/comum.sh"
exigir_root
ARQ="${1:?Informe o arquivo de backup}"
[ -f "$ARQ" ] || erro "Arquivo não encontrado: $ARQ"

if [ "${DRIVE_CONFIRMAR:-}" != "sim" ]; then
  read -rp "Isto SUBSTITUI todos os dados atuais do CCDVI Drive. Digite RESTAURAR para continuar: " resp
  [ "$resp" = "RESTAURAR" ] || erro "Cancelado."
fi

[ -f "$ARQ.sha256" ] && { sha256sum -c "$ARQ.sha256" >/dev/null && ok "hash do arquivo de backup confere"; }
TRAB="$(mktemp -d)"
trap 'rm -rf "$TRAB"' EXIT
if [[ "$ARQ" == *.gpg ]]; then gpg --batch --decrypt --output "$TRAB/b.tar" "$ARQ"; else cp "$ARQ" "$TRAB/b.tar"; fi
tar -C "$TRAB" -xf "$TRAB/b.tar"
B="$(find "$TRAB" -maxdepth 1 -type d -name 'ccdvi-drive-backup-*' | head -1)"
[ -n "$B" ] || erro "Conteúdo do backup não reconhecido."
( cd "$B" && sha256sum -c MANIFESTO.sha256 >/dev/null ) || erro "Manifesto SHA-256 não confere: backup corrompido."
ok "manifesto SHA-256 confere"

esperar_pronto 300
msg "Parando tarefas em segundo plano e ativando manutenção"
systemctl stop drive-cron.service 2>/dev/null || podman stop drive-cron >/dev/null 2>&1 || true
occ maintenance:mode --on >/dev/null
ok "pronto para restaurar"

msg "Restaurando configuração e arquivos"
podman exec "$APP" sh -c 'rm -rf /var/www/html/data /var/www/html/ccdvi-modelo && mkdir -p /var/www/html/data'
podman exec -i "$APP" tar -C /var/www/html -xf - < "$B/arquivos.tar"
# O config.php restaurado traz o usuário e a senha do banco da instalação de origem (criados pelo
# instalador do Nextcloud). Mantemos essas credenciais e ajustamos apenas o que é desta máquina.
podman exec "$APP" php -r '
  $f = "/var/www/html/config/config.php"; include $f;
  $CONFIG["dbhost"] = "drive-db";
  $CONFIG["trusted_domains"] = array_values(array_filter(explode(" ", getenv("NEXTCLOUD_TRUSTED_DOMAINS"))));
  $CONFIG["overwrite.cli.url"] = getenv("OVERWRITECLIURL");
  $CONFIG["maintenance"] = true;
  file_put_contents($f, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");'
podman exec "$APP" chown -R www-data:www-data /var/www/html/config /var/www/html/data /var/www/html/ccdvi-modelo
DBUSER="$(podman exec "$APP" php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbuser"];')"
DBPASS="$(podman exec "$APP" php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbpassword"];')"
[[ "$DBUSER" =~ ^[A-Za-z0-9_]+$ ]] || erro "Usuário de banco inválido no backup: $DBUSER"
ok "configuração e arquivos restaurados"

msg "Restaurando banco de dados (usuário da aplicação: $DBUSER)"
podman exec -i "$DB" psql -q -v ON_ERROR_STOP=1 -U nextcloud -d postgres -v u="$DBUSER" -v p="$DBPASS" <<'SQL'
DROP DATABASE IF EXISTS nextcloud WITH (FORCE);
SELECT format('CREATE ROLE %I LOGIN', :'u') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'u') \gexec
ALTER ROLE :"u" WITH LOGIN PASSWORD :'p' CREATEDB;
CREATE DATABASE nextcloud OWNER :"u";
SQL
podman exec -i "$DB" pg_restore -U nextcloud -d nextcloud --no-owner --role="$DBUSER" --exit-on-error < "$B/banco.dump"
ok "banco restaurado"

msg "Finalizando"
occ maintenance:mode --off >/dev/null
occ maintenance:data-fingerprint >/dev/null
# A conta admin passa a usar a senha DESTA instalação (/etc/ccdvi-drive/admin.senha), para que os scripts
# continuem funcionando. As senhas dos demais usuários voltam como estavam na origem.
podman exec -u www-data -e OC_PASS="$(senha_admin)" "$APP" php occ --no-interaction \
  user:resetpassword --password-from-env admin >/dev/null
ok "senha do admin alinhada a $CONF_DIR/admin.senha"
systemctl start drive-cron.service 2>/dev/null || podman start drive-cron >/dev/null 2>&1 || true
esperar_pronto 120
ok "Drive restaurado: $(occ user:list --output=json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') usuários"
