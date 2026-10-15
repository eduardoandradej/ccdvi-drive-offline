#!/usr/bin/env bash
# Teste automático do CCDVI Drive: cria dois usuários temporários, verifica permissões e política,
# e remove os usuários ao final. Não altera documentos existentes.
# Uso: sudo scripts/testar.sh
. "$(dirname "$0")/comum.sh"
exigir_root

FALHAS=0
passo() { if [ "$2" = "$3" ]; then ok "$1"; else printf '    [FALHA] %s (esperado %s, obtido %s)\n' "$1" "$3" "$2"; FALHAS=$((FALHAS+1)); fi; }

SENHA_T="$(gerar_senha 20)"
limpar() {
  for u in teste.am teste.pm; do occ user:delete "$u" >/dev/null 2>&1 || true; done
}
trap limpar EXIT

dav() { # usuario método caminho [args]
  local u="$1" m="$2" c="$3"; shift 3
  curl -s -o /dev/null -w '%{http_code}' -u "$u:$SENHA_T" -X "$m" "$URL/remote.php/dav/files/$u/$(url_caminho "$c")" "$@"
}
lista_raiz() {
  curl -s -u "$1:$SENHA_T" -X PROPFIND -H 'Depth: 1' "$URL/remote.php/dav/files/$1/" |
    python3 -c 'import sys,re,urllib.parse; print("\n".join(urllib.parse.unquote(h).rstrip("/").split("/")[-1] for h in re.findall(r"<d:href>([^<]+)</d:href>", sys.stdin.read())[1:]))'
}

msg "Serviço"
passo "Nextcloud instalado e respondendo" "$(curl -s "$URL/status.php" | grep -c '"installed":true')" "1"
passo "fora do modo de manutenção" "$(occ status --output=json | grep -c '"maintenance":false')" "1"
passo "operação sem internet (has_internet_connection=false)" "$(occ config:system:get has_internet_connection)" "false"
passo "loja de aplicativos desativada" "$(occ config:system:get appstoreenabled)" "false"
passo "links públicos desativados" "$(occ config:app:get core shareapi_allow_links)" "no"
passo "tarefas em segundo plano via cron" "$(occ config:app:get core backgroundjobs_mode)" "cron"

msg "Criando usuários temporários (teste.am em Ante Mortem, teste.pm em Post Mortem)"
for par in teste.am:DVI-AnteMortem teste.pm:DVI-PostMortem; do
  u="${par%%:*}"; g="${par##*:}"
  podman exec -u www-data -e OC_PASS="$SENHA_T" "$APP" php occ --no-interaction user:add --password-from-env "$u" >/dev/null
  occ group:adduser DVI-Todos "$u" >/dev/null
  occ group:adduser "$g" "$u" >/dev/null
done
ok "usuários criados"

msg "Pastas visíveis"
RAIZ_AM="$(lista_raiz teste.am)"
passo "teste.am vê '$PASTA_FORMULARIOS'" "$(grep -cx "$PASTA_FORMULARIOS" <<<"$RAIZ_AM")" "1"
passo "teste.am vê 'Geral'" "$(grep -cx "Geral" <<<"$RAIZ_AM")" "1"
passo "teste.am vê 'Ante Mortem'" "$(grep -cx "Ante Mortem" <<<"$RAIZ_AM")" "1"
passo "teste.am NÃO vê 'Post Mortem'" "$(grep -cx "Post Mortem" <<<"$RAIZ_AM" || true)" "0"
passo "teste.am NÃO vê 'Comando'" "$(grep -cx "Comando" <<<"$RAIZ_AM" || true)" "0"
passo "política de uso na pasta pessoal" "$(grep -cx "LEIA-ME_Politica_de_Uso.txt" <<<"$RAIZ_AM")" "1"

msg "Permissões"
passo "baixar da pasta de formulários" "$(dav teste.am GET "$PASTA_FORMULARIOS/LEIA-ME_Politica_de_Uso.txt")" "200"
passo "gravar na pasta de formulários é negado" "$(dav teste.am PUT "$PASTA_FORMULARIOS/teste.txt" --data 'x')" "403"
passo "gravar na pasta da própria equipe" "$(dav teste.am PUT "Ante Mortem/teste-automatico.txt" --data 'teste ficticio')" "201"
passo "outra equipe não acessa o arquivo" "$(dav teste.pm GET "Ante Mortem/teste-automatico.txt")" "404"
passo "gravar na pasta Geral" "$(dav teste.pm PUT "Geral/teste-automatico.txt" --data 'teste ficticio')" "201"
passo "outra equipe lê o arquivo da pasta Geral" "$(dav teste.am GET "Geral/teste-automatico.txt")" "200"
dav teste.am DELETE "Ante Mortem/teste-automatico.txt" >/dev/null
dav teste.pm DELETE "Geral/teste-automatico.txt" >/dev/null

msg "Compartilhamento por link público"
dav teste.am PUT "arquivo-pessoal.txt" --data 'x' >/dev/null
resp="$(curl -s -u "teste.am:$SENHA_T" -H 'OCS-APIRequest: true' -X POST \
  "$URL/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json" -d path=/arquivo-pessoal.txt -d shareType=3)"
passo "criação de link público é recusada" "$(grep -c '"statuscode":200' <<<"$resp" || true)" "0"

echo
if [ "$FALHAS" -eq 0 ]; then echo "RESULTADO: todos os testes aprovados."; else echo "RESULTADO: $FALHAS teste(s) falharam."; exit 1; fi
