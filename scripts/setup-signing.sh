#!/bin/zsh
# Creates a self-signed code signing certificate in the login keychain, once.
# Builds signed with it keep the same identity, so macOS remembers "Always Allow"
# for the keychain and local network across updates.
set -euo pipefail

NAME="Homericc Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Le certificat « $NAME » existe déjà."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:homericc 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -out "$WORK/id.p12" -passout pass:homericc
security import "$WORK/id.p12" -k ~/Library/Keychains/login.keychain-db -P homericc -T /usr/bin/codesign
echo "macOS va demander ton mot de passe pour faire confiance au certificat (signature de code uniquement)."
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"
echo "C'est fait : « $NAME » est prêt."
