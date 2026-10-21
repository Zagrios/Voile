#!/bin/bash
# Makes the Ed25519 key that signs voile-feed.json. The private key goes to the login Keychain (service voile-feed,
# account zagrios) and to the Feed workflow as the VOILE_FEED_KEY secret, with gh's account; the public key is printed
# in the form Obelisk checks the feed with (base64 of its 32 bytes), for its crates/game-runtime/src/voile/feed.rs.
# A new key makes every Obelisk built with the old one refuse the feed: they keep the runtime they have.
set -euo pipefail

OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
REPOSITORY="${REPOSITORY:-Zagrios/Voile}"
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "$OPENSSL is not OpenSSL 3 (brew install openssl@3)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$OPENSSL" genpkey -algorithm ed25519 -out "$work/key.pem"
security add-generic-password -U -s voile-feed -a zagrios -w "$(cat "$work/key.pem")"
gh secret set VOILE_FEED_KEY -R "$REPOSITORY" < "$work/key.pem"
# The last 32 bytes of the SubjectPublicKeyInfo are the raw key.
"$OPENSSL" pkey -in "$work/key.pem" -pubout -outform DER | tail -c 32 | base64
