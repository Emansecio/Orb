#!/bin/zsh
# Cria, uma vez, o certificado de assinatura local "Orb Local" no chaveiro de login.
#
# Por quê: o app é assinado só com uma assinatura temporária (ad-hoc), cuja identidade é um hash do binário. A cada
# compilação o macOS enxerga "outro app" e esquece as permissões de Automação, Acessibilidade e Acesso Total ao Disco.
# Com um certificado fixo a identidade não muda e as permissões ficam. O certificado é autoassinado: vale só neste Mac
# e não serve para distribuir o app.
#
# Uso: scripts/make-signing-identity.sh   (depois, scripts/bundle.sh assina com ele sozinho)
set -euo pipefail

NAME="Orb Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "$(security find-identity -v -p codesigning 2>/dev/null || true)" == *"\"$NAME\""* ]]; then
  echo "A identidade \"$NAME\" já existe no chaveiro de login. Nada a fazer."
  exit 0
fi

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "Não achei o chaveiro de login em $KEYCHAIN." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Uma execução anterior pode ter importado o certificado e parado na confiança (senha cancelada). Importar de novo
# criaria um segundo "$NAME" e o codesign reclamaria de identidade ambígua: nesse caso só repete a confiança.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "O certificado \"$NAME\" já está no chaveiro, mas ainda não é confiável. Repetindo só a confiança."
  echo "(Se não funcionar, apague \"$NAME\" no app Acesso às Chaves e rode este script de novo.)"
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$WORK/cert.pem"
else
  # O openssl do sistema (LibreSSL) gera um .p12 que o chaveiro aceita; o do Homebrew (OpenSSL 3) exige opções legadas.
  OPENSSL=/usr/bin/openssl
  PASS="$(uuidgen)"

  echo "1/3  Gerando o certificado \"$NAME\" (válido por 10 anos)…"
  cat > "$WORK/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/orb.p12" -passout "pass:$PASS"

  echo "2/3  Importando no chaveiro de login (o macOS pode pedir a senha do chaveiro)…"
  security import "$WORK/orb.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
fi

echo "3/3  Marcando o certificado como confiável para assinar código (o macOS vai pedir sua senha)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if [[ "$(security find-identity -v -p codesigning 2>/dev/null || true)" == *"\"$NAME\""* ]]; then
  echo
  echo "Pronto: a identidade \"$NAME\" está no chaveiro."
  echo "Rode scripts/bundle.sh para assinar o Orb com ela. Na primeira assinatura o macOS pode perguntar se o"
  echo "codesign pode usar a chave: escolha \"Sempre Permitir\". Depois, libere as permissões do Orb uma última vez."
else
  echo
  echo "O certificado foi importado, mas o macOS ainda não o lista como válido para assinar." >&2
  echo "Abra o app Acesso às Chaves, ache \"$NAME\", e em Confiar escolha \"Assinatura de Código: Confiar sempre\"." >&2
  exit 1
fi
