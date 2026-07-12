# Sub-Zero / Wolf Owner's App — Command-Send Capture Runbook

**Goal:** Capture the exact app→cloud HTTPS request the Sub-Zero/Wolf Owner's App sends
when you change ONE device setting (recommended: **toggle the oven light**), so we can
implement the COMMAND-SEND path of the integration.

**Status of the reverse-engineering effort:**

- **READ path — solved.** Real-time device state arrives over Azure SignalR
  (`*.service.signalr.net`). No work needed here.
- **COMMAND-SEND path — the gap this runbook closes.** When the app changes a setting it
  POSTs an app→cloud request we cannot see. The binary references
  `POST /directmethod/executeAPICmd` and device command bodies shaped like
  `{"cmd":"set","params":{...}}`, `{"cmd":"get_async"}`,
  `{"cmd":"open_async_channel_open"}` — but `POST /directmethod/executeAPICmd` returns
  **404** on `https://prod.iot.subzero.com` for every subscription key / method / body we
  tried. So **the real command host + route is unknown and must be captured on the wire.**
  There is also an unresolved `_crmBaseUrl` in the binary that may be the command host.

**Why this is hard (read this first):** The app is **Flutter (Dart AOT, Dart 3.11.5)**.
Flutter does **not** use the Android system HTTP proxy and does **not** use the Android
system CA trust store. TLS verification happens inside `libflutter.so` (a statically-linked
BoringSSL), in `ssl_crypto_x509_session_verify_cert_chain`. So the classic
"mitmproxy + install a user CA + set the Wi-Fi proxy" recipe is defeated twice over: the
app ignores the proxy, and even if forced through it, it rejects the mitm CA. We must
**neutralize the TLS check inside `libflutter.so`** AND **force traffic to the proxy**.

> This whole exercise is passive HTTPS interception of an app we own, running on an emulator
> we control, to observe its own outbound API calls. No app code is modified in this repo.

---

## 0. Environment & assets you already have

- **Mac:** Apple Silicon, macOS. (All commands below assume `zsh` and Apple Silicon.)
- **iPhone:** non-jailbroken — **not usable** as the primary capture device (see
  "Why not iOS" at the bottom). We use an **Android emulator on the Mac** instead.
- **App package:** `com.subzero.group.owners.app` (Play Store).
- **Downloaded install artifacts (already on disk):** `/tmp/subzero-re/`
  - `xapk/` — the XAPK already unpacked into split APKs:
    - `xapk/com.subzero.group.owners.app.apk`  (base)
    - `xapk/config.arm64_v8a.apk`  (native libs, **arm64**)
    - `xapk/config.en.apk`, `config.es.apk`, `config.hdpi.apk`  (resources)
    - `xapk/manifest.json`
  - `xapk/arm64/lib/arm64-v8a/libflutter.so`  ← the Flutter engine we must unpin (~11 MB)
  - `xapk/arm64/lib/arm64-v8a/libapp.so`      ← the Dart AOT app snapshot (~16 MB)
  - `libapp.strings.txt` — pre-dumped strings from `libapp.so`

Because the arm64 libs are the real ones, we run an **arm64-v8a emulator** so the exact
same `libflutter.so` we analyzed is the one running. (Do NOT use an x86_64 image — it would
pull the x86_64 variant of the libs, and none of the arm64 offsets/patterns transfer.)

---

## 1. Two viable techniques (both researched) — pick one

Flutter apps built with recent engine versions frequently defeat the "one-liner" Frida
script, and reFlutter's byte patterns lag new engine releases. So we present both, with a
manual fallback for each.

### Technique A — Frida runtime hook of `libflutter.so` (**RECOMMENDED**)

Run a rooted arm64 emulator, start `frida-server`, and inject a maintained
"disable Flutter TLS verification" script that hooks
`ssl_crypto_x509_session_verify_cert_chain` in `libflutter.so` and forces it to succeed.
Then force the app's traffic to mitmproxy.

- **Pro:** No repackaging, no re-signing, no signature-mismatch issues. Iterate instantly —
  edit the JS and re-spawn. Easiest to combine with mitmproxy. Handles the case where the
  app also does Dart-level `dio`/`http` pinning (the NVISO script covers both layers).
- **Con:** Needs a rooted emulator and a `frida-server` build that matches the emulator arch.
  The auto-pattern may miss on a brand-new engine → then use the manual-offset fallback (A2).

### Technique B — reFlutter static patch + repackage

Run `reflutter` over the APK; it patches `libflutter.so` to disable cert verification, you
re-sign the split APKs, install them, and set the proxy over adb.

- **Pro:** No Frida/root needed at runtime once installed; the patched APK is self-contained.
- **Con:** reFlutter's patterns can fail on new engines (our Dart is **3.11.5**, recent);
  you must re-sign **all** split APKs consistently; Play Integrity is more likely to flag a
  re-signed, non-Play-installed build.

**Recommendation: Technique A (Frida).** It's the fastest to iterate, avoids re-signing the
split-APK set, and the NVISO script covers both BoringSSL and Dart-level pinning. Keep
Technique B as a fallback if you can't get root/`frida-server` stable.

---

## 2. Android emulator on Apple-Silicon macOS (arm64, rootable)

### 2.1 Install the SDK + command-line tools

If you already have Android Studio, you can create the AVD from **Device Manager** instead
of the CLI — just be sure to pick an **arm64-v8a** system image. CLI path:

```bash
# Homebrew is the least-friction way to get the SDK on macOS:
brew install --cask android-commandlinetools

# Point the SDK env at the Homebrew location (adjust if you use Android Studio's SDK):
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

sdkmanager --licenses
```

### 2.2 Install an arm64 **google_apis** system image (rootable) — NOT playstore

Use `google_apis` (which is `adb root`-able), **not** `google_apis_playstore` (production
build → `adbd cannot run as root in production builds`). API 34 is a safe, stable choice.

```bash
sdkmanager "platform-tools" "emulator"
sdkmanager "system-images;android-34;google_apis;arm64-v8a"
sdkmanager "platforms;android-34"
```

> Trade-off: a `google_apis` (non-Play) image has **no Google Play Store**, so you will
> **sideload** the downloaded APK (§2.5) rather than install from Play. That is exactly what
> we want here — it also sidesteps Play Integrity blocking the emulator. If you specifically
> need Play services present, use `google_apis_playstore` + root the ramdisk with rootAVD or
> a KernelSU kernel — heavier, and Play Integrity may still block the app. Start with
> `google_apis`.

### 2.3 Create and boot the AVD

```bash
avdmanager create avd -n subzero_arm64 \
  -k "system-images;android-34;google_apis;arm64-v8a" \
  -d pixel_6

# Cold boot with writable system, DNS pinned, and NO snapshot so root changes persist:
emulator -avd subzero_arm64 -no-snapshot -writable-system -dns-server 8.8.8.8 &
```

Wait for boot, then confirm arch is **arm64**:

```bash
adb wait-for-device
adb shell getprop ro.product.cpu.abi     # must print: arm64-v8a
```

### 2.4 Get root + a writable system partition

```bash
adb root         # restarts adbd as root  (works on google_apis, not playstore)
adb shell whoami # -> root
adb remount      # make /system writable (needed to plant the mitm CA in §3.3)
```

If `adb remount` complains, do:

```bash
adb shell avbctl disable-verification   # if present
adb reboot
adb root && adb remount
```

### 2.5 Install the app (sideload the downloaded split APKs)

The XAPK is a **split** app. Install the base + the arm64 config + resource splits together
so the arm64 native libs are used. **Do not install the base alone** — it has no libs.

```bash
cd /tmp/subzero-re/xapk

adb install-multiple -r \
  com.subzero.group.owners.app.apk \
  config.arm64_v8a.apk \
  config.en.apk \
  config.hdpi.apk
```

Verify and confirm the arm64 libs landed:

```bash
adb shell pm list packages | grep subzero      # -> package:com.subzero.group.owners.app
adb shell "run-as com.subzero.group.owners.app ls -la lib/arm64 2>/dev/null || \
           ls -la /data/app/*/com.subzero.group.owners.app*/lib/arm64"
# expect libflutter.so and libapp.so present
```

> If you used a `google_apis_playstore` image instead and want Play install: open the Play
> Store, sign in, install "Sub-Zero Group Owner's App". If Play Integrity blocks it on the
> emulator, fall back to the sideload above.

---

## 3. mitmproxy setup

### 3.1 Install and run mitmproxy on the Mac

```bash
brew install mitmproxy       # provides mitmproxy (TUI), mitmweb (browser UI), mitmdump

# Use mitmweb for the nice searchable UI, listening on all interfaces so the emulator reaches it:
mitmweb --listen-host 0.0.0.0 --listen-port 8080
```

On first run mitmproxy generates its CA at `~/.mitmproxy/mitmproxy-ca-cert.pem`.
The emulator reaches the host Mac at the special alias **`10.0.2.2`** (its NAT gateway) — so
the proxy the app must use is `10.0.2.2:8080`.

### 3.2 Point the emulator at the proxy

Flutter ignores the Android proxy setting, so we set it in **two** places: the emulator's
proxy (covers the OS/WebViews and is the redirect target once Frida forces Dart through it),
and — belt and suspenders — we'll also rely on the Frida script's proxy override in §4.

```bash
# Android global proxy (helps for any non-Flutter traffic + is the target host:port):
adb shell settings put global http_proxy 10.0.2.2:8080
```

If you prefer, launch the emulator itself with `-http-proxy http://10.0.2.2:8080` instead of
the `settings put` above; either works.

### 3.3 Trust the mitmproxy CA at the **system** level

A user-installed CA is not enough for many apps; install mitm's CA as a **system** CA. On
API 34 the modern, clean way is a certs overlay mount (works with `adb root`):

```bash
# 1) Compute the Android subject-hash filename Android expects for a system CA:
HASH=$(openssl x509 -inform PEM -subject_hash_old \
        -in ~/.mitmproxy/mitmproxy-ca-cert.pem | head -1)
cp ~/.mitmproxy/mitmproxy-ca-cert.pem "/tmp/${HASH}.0"

# 2) Push it and mount it into the system CA store (writable system from §2.4):
adb push "/tmp/${HASH}.0" /data/local/tmp/
adb shell su 0 sh -c '
  mkdir -p /data/local/tmp/certs
  cp /system/etc/security/cacerts/* /data/local/tmp/certs/ 2>/dev/null
  cp /data/local/tmp/'"${HASH}"'.0 /data/local/tmp/certs/
  mount -t tmpfs tmpfs /system/etc/security/cacerts
  cp /data/local/tmp/certs/* /system/etc/security/cacerts/
  chown root:root /system/etc/security/cacerts/*
  chmod 644 /system/etc/security/cacerts/*
  chcon u:object_r:system_security_cacerts_file:s0 /system/etc/security/cacerts/* 2>/dev/null
'
```

> **Do you even need §3.3?** For a pure-Flutter path, the Frida unpinning script in §4 makes
> BoringSSL accept *any* cert, so the system CA store is often irrelevant. Install it anyway
> — it makes the OS/WebView/login flows (which may not be Flutter) interceptable too, and
> costs nothing. If §4 is doing its job you'll see traffic even without it.

---

## 4. Frida setup + the Flutter TLS-unpinning hook

### 4.1 Frida tools on the Mac

Match client and server major/minor versions.

```bash
pipx install frida-tools    # or: pip3 install --user frida-tools
frida --version             # note the version, e.g. 17.x  -> match frida-server below
```

### 4.2 `frida-server` matching the emulator arch (**android-arm64**)

The emulator is arm64 (§2.3), so download the **android-arm64** server whose version equals
your `frida --version`.

```bash
FRIDA_VER=$(frida --version)     # e.g. 17.2.17
cd /tmp
curl -L -o frida-server.xz \
  "https://github.com/frida/frida/releases/download/${FRIDA_VER}/frida-server-${FRIDA_VER}-android-arm64.xz"
unxz -f frida-server.xz

adb root
adb push frida-server /data/local/tmp/frida-server
adb shell "chmod 755 /data/local/tmp/frida-server"
adb shell "su 0 /data/local/tmp/frida-server &"      # leave running

# Sanity check from the Mac (should list processes on the device):
frida-ps -U | head
```

### 4.3 Get the unpinning script (NVISO — the maintained, well-known one)

The current maintained script is **NVISOsecurity/disable-flutter-tls-verification**
(OWASP MASTG-TOOL-0101). It pattern-matches the BoringSSL cert-chain verifier inside
`libflutter.so` across ARM64/ARM32/x64 and also patches Dart-level pinning.

```bash
cd /tmp/subzero-re
curl -L -o disable-flutter-tls.js \
  https://raw.githubusercontent.com/NVISOsecurity/disable-flutter-tls-verification/main/disable-flutter-tls.js
```

### 4.4 Spawn the app under Frida with the hook

```bash
frida -U \
  -f com.subzero.group.owners.app \
  -l /tmp/subzero-re/disable-flutter-tls.js \
  --no-pause
```

You want to see a log line indicating it located and hooked the verifier (the NVISO script
prints when it patches `ssl_crypto_x509_session_verify_cert_chain` / disables TLS). If it
prints that it found the pattern and hooked, **skip to §5**.

Alternatively via codeshare (same script, hosted):

```bash
frida -U --codeshare TheDauntless/disable-flutter-tls-v1 \
  -f com.subzero.group.owners.app --no-pause
```

### 4.5 If the auto-pattern fails (new engine) — manual offset fallback (A2)

Dart **3.11.5** is recent, so the pattern may miss. Compute the exact function offset in
**our** `libflutter.so` and hook by address. Everything here runs against the on-disk lib at
`/tmp/subzero-re/xapk/arm64/lib/arm64-v8a/libflutter.so`.

1. **Identify the Flutter engine / BoringSSL revision** from the app snapshot hash:

   ```bash
   # reFlutter ships a helper; or read the snapshot hash string out of libapp.so:
   strings -a /tmp/subzero-re/xapk/arm64/lib/arm64-v8a/libapp.so | \
     grep -Eo '[0-9a-f]{32}' | sort -u | head
   ```
   Match that snapshot hash against reFlutter's engine-hash table to get the Flutter
   version + engine commit, then read that engine's `DEPS` for `boringssl_revision`.

2. **Get the matching BoringSSL `ssl_x509.cc`** and note the source line of the
   `OPENSSL_PUT_ERROR(...)` call inside `ssl_crypto_x509_session_verify_cert_chain` — that
   line number is baked into the compiled binary as a scalar (this is what makes the
   function findable):

   ```bash
   curl "https://boringssl.googlesource.com/boringssl/+/<COMMIT>/ssl/ssl_x509.cc?format=TEXT" \
     | base64 --decode > /tmp/ssl_x509.cc
   grep -n "ssl_crypto_x509_session_verify_cert_chain" /tmp/ssl_x509.cc
   ```

3. **Find the function in the binary** (Ghidra is easiest):
   - Import `libflutter.so`, auto-analyze.
   - Search → For Scalars → the `OPENSSL_PUT_ERROR` line number from step 2; filter to the
     function that takes **three** params (matches the source signature).
   - Note its absolute address `A` and the Image Base `B` (Window → Memory Map).
   - **Module offset** = `A - B`. (radare2 alternative:
     `r2 -A /tmp/subzero-re/xapk/arm64/lib/arm64-v8a/libflutter.so`, then
     `axt`/`/c` to locate; the load-relative address is the offset directly.)

4. **Hook by offset** — small Frida script (replace `0xOFFSET`):

   ```javascript
   // manual-flutter-unpin.js
   const m = Process.getModuleByName("libflutter.so");
   Interceptor.attach(m.base.add(0xOFFSET), {  // ssl_crypto_x509_session_verify_cert_chain
     onLeave(retval) { retval.replace(0x1); }  // force "chain valid"
   });
   console.log("[+] libflutter TLS verify hooked at " + m.base.add(0xOFFSET));
   ```

   ```bash
   frida -U -f com.subzero.group.owners.app -l /tmp/subzero-re/manual-flutter-unpin.js --no-pause
   ```

### 4.6 (Technique B alternative) reFlutter static patch

Only if you chose Technique B instead of Frida:

```bash
pip3 install "reflutter==0.8.6"
cd /tmp/subzero-re/xapk
reflutter com.subzero.group.owners.app.apk       # prompts for Burp/mitm IP -> enter 10.0.2.2
# -> produces release.RE.apk (patched libflutter). Re-sign ALL splits consistently:
brew install --cask android-platform-tools   # apksigner/zipalign, or use uber-apk-signer
java -jar uber-apk-signer.jar --allowResign -a release.RE.apk
# Reinstall the patched base together with the other splits, then set the proxy:
adb install-multiple -r release.RE.apk config.arm64_v8a.apk config.en.apk config.hdpi.apk
adb shell settings put global http_proxy 10.0.2.2:8080
```

> Flutter ≥ 3.24 removed reFlutter's hardcoded proxy IP, so the `settings put global
> http_proxy` step is required with reFlutter now, not optional.

---

## 5. THE CAPTURE — toggle the oven light and grab the request

1. mitmweb (§3.1) is running and capturing on `0.0.0.0:8080`.
2. The app is running under the Frida unpin hook (§4.4/§4.5). Confirm you see *any* HTTPS
   flows appear in mitmweb once the app loads (state reads to `prod.iot.subzero.com` and the
   SignalR host confirm interception works).
3. In the app, sign in, open your oven, and **toggle the OVEN LIGHT once**. (Oven light is
   the safest reversible action — instant, harmless, easy to repeat. If you can't reach it,
   fridge **night mode**, a small **set-temp** nudge, or a **kitchen timer** are acceptable
   substitutes; note which one you actually toggled.)

### What request to look for

You are hunting the **command** POST — not a state read. In mitmweb, filter/scan for a
request that is:

- **Method:** `POST` (commands are POSTs), and
- **NOT** going to `prod.iot.subzero.com/consumerapp/*`  (that's the read/config API), and
- **NOT** going to the `*.service.signalr.net` SignalR host  (that's the read channel).

The strongest tells, any one of which means "this is it":

- path contains **`/directmethod`** or **`executeAPICmd`**
- path or body contains **`open_async_channel`**, **`get_async`**, or **`cmd":"set"`**
- an **unfamiliar host** you haven't seen before — possibly the unresolved **`_crmBaseUrl`**,
  or an Azure IoT Hub direct-method endpoint (e.g. something like
  `*.azure-devices.net/twins/<deviceId>/methods` or an APIM host that is *not*
  `prod.iot.subzero.com`).

mitmweb filter examples you can paste into its search box:

```
~m POST ~u directmethod
~m POST ~u executeAPICmd
~m POST !~d prod.iot.subzero.com !~d service.signalr.net
```

(`~m` method, `~u` URL contains, `~d` host, `!` negate.)

Toggle the light a second time while watching — the request that appears **only when you
toggle** is the command. Correlate by timestamp.

### What to record from that request (all of it)

Open the flow in mitmweb and capture **every** field:

- **METHOD** (POST/PUT/PATCH)
- **Full URL** — scheme + **host** + **path** + **query string** (query params matter; the
  device id / method name is often there)
- **All request headers**, especially:
  - `Ocp-Apim-Subscription-Key`  (APIM gateway key)
  - `Authorization`  (bearer — note the token shape/issuer, don't need the secret value)
  - `userId`  (and any `deviceId` / correlation headers)
  - `Content-Type`
- **Exact request body** — the raw JSON, verbatim (the `{"cmd":"set","params":{...}}` shape).
- **Response** — status code and body (tells us success shape + whether it's async/polled).

### How to export it

- **mitmweb / mitmproxy TUI:** select the flow → **Copy as curl** (`b` then choose curl in
  the TUI, or right-click → Export → curl in mitmweb). Paste that curl verbatim — it
  contains method, URL, all headers, and body in one artifact.
- **Save the raw flow** for the record:

  ```bash
  # In the mitmproxy TUI:  press  w  -> save all flows to a file, e.g.
  #   subzero-oven-light.mitm
  # Or run a headless dump that writes every flow to disk while you toggle:
  mitmdump --listen-host 0.0.0.0 --listen-port 8080 -w /tmp/subzero-re/subzero-oven-light.mitm
  # Later, pretty-print just the command POSTs:
  mitmdump -nr /tmp/subzero-re/subzero-oven-light.mitm \
    "~m POST !~d prod.iot.subzero.com !~d service.signalr.net" -q
  ```

Redact the raw secret values of `Authorization` / `Ocp-Apim-Subscription-Key` before sharing
anywhere public — we only need their **presence, header name, and format**, not the live
token. (Do NOT commit any captured `.mitm` file or curl containing real tokens to this repo.)

---

## 6. "What to send back" checklist

Hand back exactly this so the command path can be implemented in
`server/src/subzero/` (and mirrored in `ios/.../SubZeroManager.swift`):

- [ ] **Which setting** you toggled (oven light / fridge night mode / set-temp / timer).
- [ ] **HTTP method.**
- [ ] **Full URL:** scheme, host, path, and query string — verbatim. **Is the host
      `prod.iot.subzero.com` or something else?** If else, that's likely `_crmBaseUrl` /
      the real command host — flag it.
- [ ] **Route:** does the path contain `/directmethod` / `executeAPICmd` / a device-twin
      `methods` endpoint? Verbatim path.
- [ ] **All request headers** (names + formats; redact live secret values):
      `Ocp-Apim-Subscription-Key`, `Authorization` (token issuer/shape),
      `userId`, `Content-Type`, any `deviceId`/correlation headers.
- [ ] **Exact request body** — the raw JSON (`cmd`, `params`, target device id, etc.).
- [ ] **Response** — status code + body (esp. whether it returns a job/async id we must poll
      vs. an immediate result, which tells us if `open_async_channel_open` / `get_async` are
      part of the flow).
- [ ] **The Copy-as-curl** for the command request (redacted).
- [ ] Whether **any preceding request** in the same toggle (e.g. an
      `open_async_channel_open` / channel-open POST) is required before the `set` — capture
      the ordered sequence if there's more than one.

With host + route + headers + body + response shape, the integration's command sender is a
mechanical port.

---

## 7. Pitfalls (read if traffic doesn't show up)

- **Flutter uses its own trust store, not Android's.** Installing the mitm CA as a user or
  even system cert is *not sufficient* for the Flutter path — you MUST neutralize
  `libflutter.so` (§4). If you see OS/WebView traffic but no Dart HTTP calls, the unpin hook
  isn't landing.
- **Hook the right library.** The verifier lives in **`libflutter.so`**, not `libssl`,
  `libapp.so`, or the OS `libcrypto`. A generic "SSL unpinning" script that hooks the system
  BoringSSL will do nothing here.
- **arm64 vs x86 image mismatch.** Use an **arm64-v8a** system image so the real
  `libflutter.so`/`libapp.so` run and the offsets/patterns match our analysis. An x86_64
  emulator loads different libs; nothing transfers.
- **frida-server / frida-tools version mismatch.** The device `frida-server` version must
  match your `frida --version` (client). A mismatch fails to attach or crashes on spawn.
- **Google Play services / Play Integrity.** A Play (`google_apis_playstore`) image plus a
  re-signed reFlutter APK is the combination most likely to be blocked by Play Integrity on
  an emulator. **Fallback:** the `google_apis` image + **sideload** the downloaded splits
  (§2.5) — no Play, no Integrity attestation to fail. If login itself requires Play services,
  try `google_apis_playstore` + root, but expect to fight Integrity.
- **Flutter ignores the OS proxy.** Setting the Wi-Fi/global proxy alone won't route Dart
  traffic; the emulator global-proxy + the unpin hook together are what make Dart flows land
  in mitmproxy. If nothing appears, verify the hook logged success first, then the proxy.
- **`adb root` won't work on a `playstore` image** (`adbd cannot run as root in production
  builds`). Use `google_apis`, or root the ramdisk/KernelSU for a playstore image.
- **New engine defeats the auto-pattern.** Dart 3.11.5 is recent; if the NVISO script can't
  find the pattern, use the manual-offset fallback (§4.5) against our exact `libflutter.so`.
- **Certificate transparency / snapshot state.** Boot with `-no-snapshot -writable-system`
  so the planted system CA and root survive; a Quick-Boot snapshot silently reverts them.

---

## Why not iOS (kept for the record)

The iPhone is **non-jailbroken**. Frida can't inject into arbitrary apps on a stock iOS
device, and you can't easily unpin a Flutter app there. reFlutter on iOS needs a re-signed
IPA and a jailbroken/provisioned device to route traffic. The Android emulator path above is
strictly less friction and uses the arm64 libs we already reverse-engineered. Revisit iOS
only if the Android build's command path somehow differs (unlikely — same cloud API).

---

### Sources

- [NVISOsecurity/disable-flutter-tls-verification](https://github.com/NVISOsecurity/disable-flutter-tls-verification)
- [OWASP MASTG-TOOL-0101: disable-flutter-tls-verification](https://mas.owasp.org/MASTG/tools/generic/MASTG-TOOL-0101/)
- [OWASP MASTG-TECH-0109: Intercepting Flutter HTTPS Traffic (Android)](https://mas.owasp.org/MASTG/techniques/android/MASTG-TECH-0109/)
- [reFlutter (Impact-I/reFlutter)](https://github.com/Impact-I/reFlutter)
- [Bypassing Flutter TLS/SSL Verification When reFlutter Fails (2026)](https://petruknisme.medium.com/bypassing-flutter-tls-ssl-verification-when-reflutter-fails-a4c41ff758a3)
- [Rooting an Android Emulator for Mobile Security Testing (8kSec)](https://www.8ksec.io/rooting-an-android-emulator-for-mobile-security-testing/)
- [Frida on Android Studio Emulator (2026)](https://medium.com/@thrishank007/frida-on-android-studio-emulator-2026-installation-usage-frida-compile-workflow-c44cf8c823a7)
- [Frida — Android docs](https://frida.re/docs/android/)
