// The app builds that may use listenjar.com's passkeys, read in the listenjar
// monorepo by the backend, which accepts the origins they sign
// (`nativeOrigins`), and the web app, which lists them in
// /.well-known/apple-app-site-association and /.well-known/assetlinks.json.
// Nothing here is secret: the files are public, and so is every certificate
// an app ships signed with.
//
// macOS and iOS sign `https://<rpId>` as the origin once the build carries
// the `webcredentials:listenjar.com` Associated Domain. Windows (webauthn.dll,
// through package:passkeys) signs the same. Android signs
// `android:apk-key-hash:<base64url SHA-256 of the signing certificate>`, for
// each certificate listed here; Linux has no platform passkeys.

/** Team ID plus bundle ID of every Apple build (Release.xcconfig). */
export const appleApps = ["N624KG8EA7.com.listenjar.desktop"]

/** The Android package and the SHA-256 of each certificate it is signed with. */
export const androidApps: { package: string; sha256: string[] }[] = [
  {
    package: "com.listenjar.desktop",
    // The release key's (~/.secrets/listenjar/desktop-signing/android), which
    // signs every published APK. Debug builds are com.listenjar.desktop.dev.
    sha256: ["7B:AE:23:DA:4F:E1:0F:2B:8B:6C:4A:32:C7:BD:0A:F7:FB:40:1C:86:13:3C:D5:5E:28:3A:D3:DF:02:BF:ED:BE"],
  },
]

/** `AA:BB:…` as WebAuthn's Android origin. */
function apkKeyHash(fingerprint: string): string {
  const bytes = fingerprint.split(":").map(byte => parseInt(byte, 16))
  const base64 = btoa(String.fromCharCode(...bytes))
  return `android:apk-key-hash:${base64.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")}`
}

/** Every origin the apps sign a passkey assertion for `rpId` with. */
export const nativeOrigins = (rpId: string): string[] => [
  `https://${rpId}`,
  ...androidApps.flatMap(app => app.sha256.map(apkKeyHash)),
]
