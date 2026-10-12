#!/bin/sh
# One time, for the maintainer: makes the certificate releases are signed with and saves it
# as the repository's SIGNING_CERTIFICATE secrets. Needs the GitHub CLI (brew install gh).
# Usage: scripts/make-signing-cert.sh
set -e
repo=tangheng05/clippeek
dir="$HOME/.clippeek-signing"

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh, then gh auth login" >&2; exit 1; }
[ ! -e "$dir/clippeek.p12" ] || { echo "$dir/clippeek.p12 already exists; a new certificate would make everyone allow the Keychain again." >&2; exit 1; }
mkdir -p "$dir"
chmod 700 "$dir"
cd "$dir"

cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = clippeek
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config cert.cnf -keyout key.pem -out cert.pem 2>/dev/null
pass=$(openssl rand -hex 16)
# The older encryption is the one macOS's security tool reads.
openssl pkcs12 -export -inkey key.pem -in cert.pem -name clippeek -out clippeek.p12 -passout "pass:$pass" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
printf '%s' "$pass" > password.txt
rm key.pem cert.cnf

base64 < clippeek.p12 | gh secret set SIGNING_CERTIFICATE --repo "$repo"
gh secret set SIGNING_CERTIFICATE_PASSWORD --repo "$repo" < password.txt
echo "Done. Releases from now on are signed with it. Back up $dir: losing it means everyone allows the Keychain once more."
