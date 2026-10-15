#!/usr/bin/env bash
# Backup do CCDVI Drive: banco PostgreSQL + configuração + arquivos dos usuários, com manifesto SHA-256.
# O Nextcloud fica em modo de manutenção durante a cópia (alguns segundos a minutos).
# Criptografia: defina DRIVE_BACKUP_GPG_RECIPIENT com a chave pública institucional.
# Uso: sudo scripts/backup.sh <diretório-destino>
. "$(dirname "$0")/comum.sh"
exigir_root
DEST="${1:?Informe o diretório de destino. Ex.: sudo scripts/backup.sh /srv/backups/drive}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TRAB="$(mktemp -d)"
B="$TRAB/ccdvi-drive-backup-$STAMP"
mkdir -p "$B"
manutencao_off() { occ maintenance:mode --off >/dev/null 2>&1 || true; rm -rf "$TRAB"; }
trap manutencao_off EXIT

msg "Ativando modo de manutenção"
occ maintenance:mode --on >/dev/null
ok "manutenção ativa"

msg "Copiando banco de dados"
podman exec "$DB" pg_dump -U nextcloud -d nextcloud --format=custom --no-owner > "$B/banco.dump"
ok "banco.dump ($(du -h "$B/banco.dump" | cut -f1))"

msg "Copiando configuração e arquivos"
podman exec "$APP" tar -C /var/www/html -cf - config data ccdvi-modelo > "$B/arquivos.tar"
ok "arquivos.tar ($(du -h "$B/arquivos.tar" | cut -f1))"

occ maintenance:mode --off >/dev/null
ok "manutenção desativada"

( cd "$B" && sha256sum banco.dump arquivos.tar > MANIFESTO.sha256 )
cat > "$B/INFO.txt" <<INFO
Backup CCDVI Drive (Nextcloud)
Data (UTC): $STAMP
Versão: $(occ status --output=json | python3 -c 'import json,sys; print(json.load(sys.stdin)["versionstring"])')
Usuários: $(occ user:list --output=json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
INFO

mkdir -p "$DEST"
SAIDA="$DEST/ccdvi-drive-backup-$STAMP.tar"
tar -C "$TRAB" -cf "$SAIDA" "ccdvi-drive-backup-$STAMP"
if [ -n "${DRIVE_BACKUP_GPG_RECIPIENT:-}" ]; then
  gpg --batch --yes --encrypt --recipient "$DRIVE_BACKUP_GPG_RECIPIENT" --output "$SAIDA.gpg" "$SAIDA"
  shred -u "$SAIDA" 2>/dev/null || rm -f "$SAIDA"
  SAIDA="$SAIDA.gpg"
else
  echo "    AVISO: backup NÃO criptografado (contém config.php com credenciais). Defina DRIVE_BACKUP_GPG_RECIPIENT." >&2
fi
chmod 600 "$SAIDA"
sha256sum "$SAIDA" > "$SAIDA.sha256"
msg "Backup concluído"
echo "    $SAIDA"
