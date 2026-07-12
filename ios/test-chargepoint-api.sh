#!/bin/bash
# Reads ChargePoint credentials from Keychain and tests the API flow,
# printing full responses at each step so we can see the exact shapes.

set -e

EMAIL=$(security find-generic-password -s "com.jasongelman.LutronHome.chargepoint" -a "email_0" -w 2>/dev/null)
PASS=$(security find-generic-password -s "com.jasongelman.LutronHome.chargepoint" -a "password_0" -w 2>/dev/null)

if [ -z "$EMAIL" ] || [ -z "$PASS" ]; then
  echo "ERROR: No ChargePoint credentials found in Keychain for account 0"
  exit 1
fi

UA="ChargePoint/6.0.0 CFNetwork/1568.200.51 Darwin/24.1.0"

echo "=== STEP 1: Discovery ==="
DISC=$(curl -s -X POST "https://discovery.chargepoint.com/discovery/v3/globalconfig" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  -d "{\"username\": \"$EMAIL\"}")
echo "$DISC" | python3 -m json.tool 2>/dev/null || echo "$DISC"

SSO=$(echo "$DISC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('endPoints',d.get('endpoints',{})).get('sso_endpoint',{}).get('value',''))" 2>/dev/null)
ACCOUNTS=$(echo "$DISC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('endPoints',d.get('endpoints',{})).get('accounts_endpoint',{}).get('value',''))" 2>/dev/null)
HCM=$(echo "$DISC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('endPoints',d.get('endpoints',{})).get('hcpo_hcm_endpoint',{}).get('value',''))" 2>/dev/null)
REGION=$(echo "$DISC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('region','NA'))" 2>/dev/null)

echo ""
echo "SSO=$SSO"
echo "ACCOUNTS=$ACCOUNTS"
echo "HCM=$HCM"
echo "REGION=$REGION"

echo ""
echo "=== STEP 2: Login ==="
LOGIN_RESP=$(curl -s -i -X POST "${SSO}v1/user/login" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  -d "{\"username\": \"$EMAIL\", \"password\": \"$PASS\"}" \
  -c /tmp/cp_cookies.txt \
  -L -o /tmp/cp_login_body.txt -w "HTTP_CODE=%{http_code} REDIRECT=%{redirect_url}")
echo "$LOGIN_RESP"
echo "--- Response Headers (from curl -i): ---"
# Re-do without -o to see headers
curl -s -D /tmp/cp_login_headers.txt -X POST "${SSO}v1/user/login" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  -d "{\"username\": \"$EMAIL\", \"password\": \"$PASS\"}" \
  -c /tmp/cp_cookies.txt \
  -o /tmp/cp_login_body2.txt
echo "--- Headers: ---"
cat /tmp/cp_login_headers.txt
echo "--- Body: ---"
cat /tmp/cp_login_body2.txt | head -c 2000
echo ""
echo "--- Cookies: ---"
cat /tmp/cp_cookies.txt

# Extract token - try coulomb_sess first, then auth-session
TOKEN=$(grep "coulomb_sess" /tmp/cp_cookies.txt 2>/dev/null | awk '{print $NF}')
TOKEN_TYPE="coulomb_sess"
if [ -z "$TOKEN" ]; then
  TOKEN=$(grep "auth-session" /tmp/cp_cookies.txt 2>/dev/null | awk '{print $NF}')
  TOKEN_TYPE="auth-session"
fi

if [ -z "$TOKEN" ]; then
  echo "ERROR: No session token found in cookies"
  exit 1
fi
echo ""
echo "TOKEN_TYPE=$TOKEN_TYPE"
echo "TOKEN=${TOKEN:0:40}..."

echo ""
echo "=== STEP 3: Profile ==="
if [ "$TOKEN_TYPE" = "auth-session" ]; then
  CP_SESSION_TYPE="AUTH_SESSION"
else
  CP_SESSION_TYPE="CP_SESSION_TOKEN"
fi

PROFILE_RESP=$(curl -s -w "\nHTTP_CODE=%{http_code}" "${ACCOUNTS}v1/driver/profile/user" \
  -H "User-Agent: $UA" \
  -H "Cookie: ${TOKEN_TYPE}=${TOKEN}" \
  -H "cp-session-type: $CP_SESSION_TYPE" \
  -H "cp-session-token: $TOKEN" \
  -H "cp-region: $REGION")
echo "$PROFILE_RESP" | head -c 3000
echo ""

# Extract user_id
USER_ID=$(echo "$PROFILE_RESP" | python3 -c "
import sys,json
lines = sys.stdin.read().split('\n')
body = '\n'.join(l for l in lines if not l.startswith('HTTP_CODE='))
try:
    d = json.loads(body)
    uid = d.get('user',{}).get('userId') or d.get('user',{}).get('user_id') or d.get('userId') or d.get('user_id')
    print(uid or 'NOT_FOUND')
except: print('PARSE_ERROR')
" 2>/dev/null)
echo "USER_ID=$USER_ID"

if [ "$USER_ID" = "NOT_FOUND" ] || [ "$USER_ID" = "PARSE_ERROR" ] || [ -z "$USER_ID" ]; then
  echo "ERROR: Could not extract user_id, stopping here"
  exit 1
fi

echo ""
echo "=== STEP 4: Charger List ==="
CHARGERS_RESP=$(curl -s -w "\nHTTP_CODE=%{http_code}" "${HCM}api/v1/configuration/users/${USER_ID}/chargers" \
  -H "User-Agent: $UA" \
  -H "Content-Type: application/json" \
  -H "Cookie: ${TOKEN_TYPE}=${TOKEN}" \
  -H "cp-session-type: $CP_SESSION_TYPE" \
  -H "cp-session-token: $TOKEN" \
  -H "cp-region: $REGION")
echo "$CHARGERS_RESP" | head -c 3000
echo ""

# Cleanup
rm -f /tmp/cp_cookies.txt /tmp/cp_login_body.txt /tmp/cp_login_body2.txt /tmp/cp_login_headers.txt
echo ""
echo "=== DONE ==="
