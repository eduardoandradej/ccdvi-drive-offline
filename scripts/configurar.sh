#!/usr/bin/env bash
# Aplica a configuração do CCDVI: operação sem internet, idioma, política de compartilhamento,
# grupos, pastas por equipe, usuários (opcional) e formulários (opcional).
# Uso: sudo scripts/configurar.sh [--usuarios ARQUIVO.csv] [--formularios PASTA]
# Pode ser executado novamente com segurança.
. "$(dirname "$0")/comum.sh"
exigir_root

USUARIOS=""
FORMULARIOS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --usuarios) USUARIOS="${2:?informe o arquivo CSV}"; shift 2 ;;
    --formularios) FORMULARIOS="${2:?informe a pasta}"; shift 2 ;;
    *) erro "Opção desconhecida: $1" ;;
  esac
done
[ -z "$USUARIOS" ] || [ -r "$USUARIOS" ] || erro "Arquivo de usuários não encontrado: $USUARIOS"
[ -z "$FORMULARIOS" ] || [ -d "$FORMULARIOS" ] || erro "Pasta de formulários não encontrada: $FORMULARIOS"

esperar_pronto 300

msg "Operação sem internet e idioma"
occ config:system:set has_internet_connection --value=false --type=boolean >/dev/null
occ config:system:set appstoreenabled --value=false --type=boolean >/dev/null
occ config:system:set updatechecker --value=false --type=boolean >/dev/null
occ config:system:set knowledgebaseenabled --value=false --type=boolean >/dev/null
occ config:system:set default_language --value=pt_BR >/dev/null
occ config:system:set default_locale --value=pt_BR >/dev/null
occ config:system:set default_phone_region --value=BR >/dev/null
occ config:system:set maintenance_window_start --value=4 --type=integer >/dev/null
occ background:cron >/dev/null
ok "sem loja de apps, sem verificação de atualização, pt-BR, tarefas via cron"

msg "Desativando aplicativos que dependem de internet ou não se aplicam"
ATIVOS="$(occ app:list --output=json)"
for app in firstrunwizard nextcloud_announcements updatenotification survey_client support weather_status \
           recommendations lookup_server_connector federation app_api; do
  if printf '%s' "$ATIVOS" | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["enabled"] else 1)' "$app"; then
    occ app:disable "$app" >/dev/null && ok "desativado: $app"
  fi
done

msg "Política de compartilhamento"
occ config:app:set core shareapi_allow_links --value=no >/dev/null
occ config:app:set core shareapi_allow_resharing --value=no >/dev/null
occ config:app:set files_sharing outgoing_server2server_share_enabled --value=no >/dev/null
occ config:app:set files_sharing incoming_server2server_share_enabled --value=no >/dev/null
occ config:app:set files_sharing lookupServerEnabled --value=no >/dev/null
occ config:app:set files_sharing lookupServerUploadEnabled --value=no >/dev/null
ok "links públicos, recompartilhamento e federação desativados"

msg "Identidade visual e aviso de uso"
occ theming:config name "CCDVI Drive" >/dev/null
occ theming:config slogan "Documentos de apoio. Dados de casos somente no Sistema DVI." >/dev/null
occ theming:config primary_color "#2f3b47" >/dev/null 2>&1 || occ theming:config color "#2f3b47" >/dev/null
ok "nome, slogan e cor aplicados"

msg "Modelo de pasta inicial dos usuários (contém a política de uso)"
podman exec "$APP" mkdir -p /var/www/html/ccdvi-modelo
podman cp "$RAIZ/politica/LEIA-ME_Politica_de_Uso.txt" "$APP:/var/www/html/ccdvi-modelo/LEIA-ME_Politica_de_Uso.txt"
podman exec "$APP" chown -R www-data:www-data /var/www/html/ccdvi-modelo
occ config:system:set skeletondirectory --value=/var/www/html/ccdvi-modelo >/dev/null
occ config:system:set templatedirectory --value= >/dev/null
ok "novos usuários recebem apenas LEIA-ME_Politica_de_Uso.txt"

msg "Grupos"
GRUPOS_EXISTENTES="$(occ group:list --output=json)"
for g in "${GRUPOS[@]}"; do
  if printf '%s' "$GRUPOS_EXISTENTES" | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$g"; then
    ok "$g (já existia)"
  else
    occ group:add "$g" >/dev/null && ok "$g criado"
  fi
done

msg "Pastas por equipe (pertencem ao admin e são compartilhadas com os grupos)"
# permissões OCS: 1=ler, 15=ler+editar+criar+apagar (sem recompartilhar)
declare -A PASTAS=(
  ["$PASTA_FORMULARIOS"]="DVI-Todos:1"
  ["Geral"]="DVI-Todos:15"
  ["Comando"]="DVI-Comando:15"
  ["Ante Mortem"]="DVI-AnteMortem:15"
  ["Post Mortem"]="DVI-PostMortem:15"
  ["TIC"]="DVI-TIC:15"
)
for pasta in "${!PASTAS[@]}"; do
  grupo="${PASTAS[$pasta]%%:*}"; perm="${PASTAS[$pasta]##*:}"
  codigo="$(dav_admin MKCOL "$pasta")"
  case "$codigo" in 201|405) ;; *) erro "Falha ao criar a pasta '$pasta' (HTTP $codigo)";; esac
  codigo="$(dav_admin PUT "$pasta/LEIA-ME_Politica_de_Uso.txt" --data-binary @"$RAIZ/politica/LEIA-ME_Politica_de_Uso.txt")"
  case "$codigo" in 201|204) ;; *) erro "Falha ao enviar a política para '$pasta' (HTTP $codigo)";; esac
  existentes="$(ocs_admin GET apps/files_sharing/api/v1/shares -G --data-urlencode "path=/$pasta")"
  if printf '%s' "$existentes" | python3 -c 'import json,sys; d=json.load(sys.stdin)["ocs"]["data"]; sys.exit(0 if any(s["share_with"]==sys.argv[1] for s in d) else 1)' "$grupo"; then
    ok "$pasta -> $grupo (já compartilhada)"
  else
    resp="$(ocs_admin POST apps/files_sharing/api/v1/shares --data-urlencode "path=/$pasta" -d shareType=1 \
            --data-urlencode "shareWith=$grupo" -d "permissions=$perm")"
    printf '%s' "$resp" | grep -q '"statuscode":200' || erro "Falha ao compartilhar '$pasta': $resp"
    ok "$pasta -> $grupo ($([ "$perm" = 1 ] && echo somente leitura || echo leitura e escrita))"
  fi
done

if [ -n "$FORMULARIOS" ]; then
  msg "Enviando formulários de $FORMULARIOS para '$PASTA_FORMULARIOS'"
  n=0
  while IFS= read -r -d '' arq; do
    nome="$(basename "$arq")"
    codigo="$(dav_admin PUT "$PASTA_FORMULARIOS/$nome" --data-binary @"$arq")"
    case "$codigo" in 201|204) ok "$nome"; n=$((n+1));; *) erro "Falha ao enviar $nome (HTTP $codigo)";; esac
  done < <(find "$FORMULARIOS" -maxdepth 1 -type f \( -iname '*.pdf' -o -iname '*.docx' -o -iname '*.odt' \
            -o -iname '*.xlsx' -o -iname '*.ods' -o -iname '*.txt' \) -print0 | sort -z)
  ok "$n arquivo(s) enviado(s)"
fi

if [ -n "$USUARIOS" ]; then
  msg "Criando usuários de $USUARIOS"
  SENHAS="$CONF_DIR/senhas-iniciais.txt"
  touch "$SENHAS"; chmod 600 "$SENHAS"
  EXISTENTES="$(occ user:list --output=json)"
  while IFS=';' read -r usuario nome grupos; do
    usuario="$(echo "$usuario" | tr -d '[:space:]')"
    [ -z "$usuario" ] || [ "${usuario:0:1}" = "#" ] && continue
    if printf '%s' "$EXISTENTES" | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$usuario"; then
      ok "$usuario (já existia)"; continue
    fi
    senha="${DRIVE_SENHA_INICIAL:-$(gerar_senha 16)}"
    podman exec -u www-data -e OC_PASS="$senha" "$APP" php occ --no-interaction user:add --password-from-env \
      --display-name "$nome" "$usuario" >/dev/null
    # Grupos são adicionados DEPOIS da criação da conta: adicionados junto com user:add, o Nextcloud
    # não ativa automaticamente o compartilhamento do primeiro grupo (comportamento observado no 31.0.14).
    IFS=',' read -ra lista <<< "DVI-Todos,$grupos"
    for g in "${lista[@]}"; do g="$(echo "$g" | tr -d '[:space:]')"; [ -n "$g" ] && occ group:adduser "$g" "$usuario" >/dev/null; done
    printf '%s;%s\n' "$usuario" "$senha" >> "$SENHAS"
    ok "$usuario ($grupos)"
  done < "$USUARIOS"
  echo "    Senhas iniciais registradas em $SENHAS (entregar a cada usuário e pedir troca no primeiro acesso)."
fi

msg "Configuração concluída"
