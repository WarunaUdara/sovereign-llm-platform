#!/usr/bin/env bash
# Public smoke test for the chat front door. Hits the internet-facing URL, not port-forwards.
# Checks: HTTP->HTTPS redirect, valid TLS, UI served, auth required for data, self-registration closed.
set -uo pipefail
HOST="${CHAT_HOST:-chat.example.com}"
PASS=0; FAILN=0
check() { if [[ "$2" == 0 ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAILN=$((FAILN+1)); fi; }

echo "== transport"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://$HOST/")
[[ "$CODE" == 301 ]]; check "plain HTTP redirects (got $CODE)" $?
VERIFY=$(curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 20 "https://$HOST/")
[[ "$VERIFY" == 0 ]]; check "TLS certificate verifies (verify_result=$VERIFY)" $?
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/")
[[ "$CODE" == 200 ]]; check "UI served over HTTPS (got $CODE)" $?
TITLE=$(curl -s --max-time 20 "https://$HOST/" | grep -o '<title>[^<]*</title>' | head -1)
[[ "$TITLE" == *LibreChat* ]]; check "page title is LibreChat" $?

echo "== authentication"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/api/convos")
[[ "$CODE" == 401 ]]; check "conversation list needs login without a session (got $CODE)" $?
# Property tested: bad credentials never yield a session token. (LibreChat v0.8.8 answers 404 for an unknown
# email, a user-enumeration issue recorded in docs/THREAT_MODEL.md; this test does not depend on that status.)
BODY=$(curl -s --max-time 20 -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.com","password":"wrong-password-123"}' "https://$HOST/api/auth/login")
echo "$BODY" | grep -q '"token"'; [[ $? -ne 0 ]]; check "bad credentials never return a session token" $?

echo "== invite-only"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Content-Type: application/json' \
  -d '{"email":"probe@example.com","name":"probe","username":"probe","password":"Probe-password-123"}' "https://$HOST/api/auth/register")
[[ "$CODE" != 200 && "$CODE" != 201 ]]; check "self-registration is closed (got $CODE)" $?

echo
echo "result: $PASS passed, $FAILN failed"
(( FAILN == 0 ))
