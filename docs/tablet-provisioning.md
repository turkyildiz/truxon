# Trux Companion — tablet provisioning checklist

> **ONE-APP RADIO (2026-07-21):** the app now has native push-to-talk built
> in — voice rides Truxon's own authenticated connection (Radio tab, hold to
> talk), and dispatch answers from truxon.com → 📻 Radio. Once one tablet
> passes a field smoke test on the native radio, steps 1 (Tailscale) and
> 2 (Mumla) below become UNNECESSARY for new tablets: provisioning collapses
> to install-one-app → log in → grant permissions. The Mumla path stays as
> the in-app fallback link until then.

Do this once per truck tablet (Samsung / Android). ~10 min each. The goal:
the app runs **always-on in the background**, shares location 24/7, and never
needs a thumb drive again after this.

Fill one row per tablet at the bottom.

---

## 0. Before you start
- [ ] Tablet charged, on Wi-Fi (for setup — trucks use LTE after).
- [ ] Settings → General management → Date and time → **Automatic** (on).
- [ ] Know the driver's **Truxon login** (email + password) for this truck.

## 1. Tailscale VPN (so the radio reaches dispatch)
- [ ] Play Store → install **Tailscale**.
- [ ] Open it → **Sign in** with the fleet account (`turkyildiz@gmail.com`).
- [ ] Confirm it shows **Connected** and a `100.x.x.x` address.

## 2. Mumla (push-to-talk radio)
- [ ] Play Store → install **Mumla**.
- [ ] Add server → Address `100.89.140.98`, Port `64738`,
      Username = truck/driver name, Password = **server join password**
      (from the password manager).
- [ ] Mumla → Settings → **Push to Talk** → map it to a big on-screen button.
- [ ] Connect once and confirm you can talk to the office.

## 3. Install Trux Companion
- [ ] Easiest: open the tablet browser to
      `github.com/turkyildiz/truxon-releases/releases/latest/download/TruxCompanion.apk`
      (works once the releases repo is live), **or** copy the APK from a thumb drive.
- [ ] Tap the APK → if blocked, **Allow from this source** → **Install**.
- [ ] (After this first install, the app **self-updates** — no more manual installs.)

## 4. Log in + grant permissions (do all of these)
- [ ] Open Trux Companion → log in with the driver's Truxon email + password.
- [ ] **Location → "Allow all the time"** — this is the important one. If it only
      offered "While using", go to Settings → Apps → Trux Companion → Permissions
      → Location → **Allow all the time**.
- [ ] **Microphone** — Allow (Trux voice).
- [ ] **Camera** — Allow (delivery-receipt photos).
- [ ] **Notifications** — Allow (dispatch alarms).
- [ ] **Install unknown apps** — Settings → Apps → Trux Companion → *Install
      unknown apps* → **Allow** (lets the app update itself).

## 5. Keep it alive (Samsung battery settings — critical)
- [ ] Settings → Battery → **Background usage limits**:
      - **Never sleeping apps** → add **Trux Companion**, **Mumla**, **Tailscale**.
      - Make sure none of the three are in "Sleeping" / "Deep sleeping".
- [ ] Settings → Apps → Trux Companion → **Battery** → **Unrestricted**.
- [ ] Settings → Battery → turn **off** "Put unused apps to sleep" (or exclude these apps).

## 6. Alarms through Do-Not-Disturb
- [ ] Make sure the **Alarm volume** is up (dispatch alarms play on the alarm channel).
- [ ] If the tablet uses a custom Do-Not-Disturb schedule, allow **Alarms** in it
      (Settings → Notifications → Do Not Disturb → Allowed → Alarms on).

## 7. Verify (2-minute smoke test)
- [ ] Loads tab shows this driver's loads and reads **"Sharing location — Always on."**
- [ ] Trux tab → tap mic → "what are my loads" → hear a British-voice reply.
- [ ] Radio tab → **Connect** → Mumla opens to the server.
- [ ] **Reboot the tablet.** After it comes up (don't open the app), within a
      couple minutes the **"Trux — sharing location"** notification should reappear
      on its own. That proves always-on tracking survives restarts.

## 8. Lock it down (optional but recommended for truck-mounted)
- [ ] Pin/kiosk Trux Companion + Mumla (Knox or Android screen pinning).
- [ ] Label the tablet with the **truck number**.

---

## Per-tablet log

| Truck # | Driver | Truxon login (email) | Tailscale ✓ | Mumla ✓ | Location "all the time" ✓ | Never-sleeping ✓ | Reboot test ✓ | Date done |
|---------|--------|----------------------|-------------|---------|---------------------------|------------------|---------------|-----------|
|         |        |                      |             |         |                           |                  |               |           |
|         |        |                      |             |         |                           |                  |               |           |
|         |        |                      |             |         |                           |                  |               |           |

> Notes: server join password and fleet Tailscale account are in the password
> manager. Each driver logs in with **their own** Truxon account (linked to their
> driver record) — don't share one login across trucks, or the map shows every
> truck at one spot.
