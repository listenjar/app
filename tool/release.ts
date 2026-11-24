// Release identity, update signatures, appcasts and publication: every
// platform's package goes up to listenjar/desktop's GitHub release, and the
// in-app updaters (lib/updates.dart: Sparkle on macOS, WinSparkle on Windows
// x64 and arm64) read their platform's appcast from the latest release:
//
//   https://github.com/listenjar/desktop/releases/latest/download/appcast-<platform>.xml
//
// pubspec.yaml's `version: X.Y.Z+N` is the release: tag vX.Y.Z, shown as
// X.Y.Z, and N is the build number both updaters compare, so N only grows
// (`dart tool/release.dart prepare` reserves each). macOS and Windows sign
// their payload with their own Ed25519 seed, and the apps carry the matching
// public key (macos/Runner/Info.plist, windows/runner/updates.h); Linux and
// Android, which update elsewhere, only get a manifest with the hash.
//
//   node tool/release.ts identity [tag]
//   node tool/release.ts prepare <platform> <payload> <directory>
//   node tool/release.ts verify <directory>
//   node tool/release.ts publish <directory>
import { execFileSync } from "node:child_process"
import { createHash, createPrivateKey, createPublicKey, sign, verify } from "node:crypto"
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { androidApps } from "../passkeys.ts"

const repository = "listenjar/desktop"
// The APK's signing certificate (tool/release.dart checks the APK against it).
const [androidCertificate] = androidApps[0].sha256
const pubspec = path.join(import.meta.dirname, "../packages/desktop/pubspec.yaml")

type Updater = { seed: string; key: string; minimumSystem: string }
// Both Windows architectures share one update key; each has its own appcast,
// which windows/runner/updates.cpp picks by the architecture it was built for.
const windowsUpdater: Updater = { seed: "WINDOWS_UPDATE_SEED_BASE64", key: "WINDOWS_UPDATE_PUBLIC_KEY", minimumSystem: "10.0" }
const platforms: Record<string, { suffix: string; updater?: Updater }> = {
  macos: {
    suffix: ".dmg",
    updater: { seed: "MACOS_UPDATE_SEED_BASE64", key: "MACOS_UPDATE_PUBLIC_KEY", minimumSystem: "12.0" },
  },
  "windows-x64": { suffix: "-setup.exe", updater: windowsUpdater },
  "windows-arm64": { suffix: "-setup.exe", updater: windowsUpdater },
  "linux-x64": { suffix: ".tar.gz" },
  android: { suffix: ".apk" },
}
type Platform = string

type Release = { version: string; build: number; commit: string; tag: string }
type Manifest = Release & { platform: Platform; asset: string; length: number; sha256: string; signature?: string }

const isPlatform = (value: string): value is Platform => Object.hasOwn(platforms, value)

async function identity(tag?: string): Promise<Release> {
  const match = /^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m.exec(await readFile(pubspec, "utf8"))
  if (!match) throw new Error("pubspec.yaml needs version: X.Y.Z+N")
  const [, version, build] = match
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim()
  if (tag && tag !== `v${version}`) throw new Error(`${tag} does not match pubspec.yaml's ${version}`)
  if (tag && execFileSync("git", ["rev-parse", `${tag}^{commit}`], { encoding: "utf8" }).trim() !== commit) {
    throw new Error(`${tag} does not point at the built commit`)
  }
  return { version, build: Number(build), commit, tag: `v${version}` }
}

const assetName = (release: Release, platform: Platform) =>
  `ListenJar-${release.version}-${platform}${platforms[platform].suffix}`

function rawKey(value: string | undefined, length: number): Buffer {
  const bytes = Buffer.from(value ?? "", "base64")
  if (bytes.length !== length || bytes.toString("base64") !== value) {
    throw new Error(`Expected canonical base64 for a ${length}-byte key`)
  }
  return bytes
}

const updater = (platform: Platform): Updater => {
  const updater = platforms[platform].updater
  if (!updater) throw new Error(`${platform} has no in-app updater`)
  return updater
}

const publicKey = (platform: Platform) =>
  createPublicKey({
    key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), rawKey(process.env[updater(platform).key], 32)]),
    format: "der",
    type: "spki",
  })

const xml = (value: string | number) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;")

// No release notes: the updaters' alerts stay compact, and GitHub's release
// page is where notes are read.
function appcast(m: Manifest): string {
  const windows = m.platform !== "macos"
  const url = `https://github.com/${repository}/releases/download/${m.tag}/${m.asset}`
  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>ListenJar ${xml(m.platform)}</title><link>https://listenjar.com</link><description>ListenJar updates</description><language>en</language>
<item><title>ListenJar ${xml(m.version)}</title>
<sparkle:version>${m.build}</sparkle:version>
<sparkle:shortVersionString>${xml(m.version)}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>${updater(m.platform).minimumSystem}</sparkle:minimumSystemVersion>
<enclosure url="${xml(url)}" length="${m.length}" type="application/octet-stream" sparkle:version="${m.build}" sparkle:shortVersionString="${xml(m.version)}" sparkle:edSignature="${xml(m.signature)}" sparkle:os="${xml(m.platform)}"${windows ? ' sparkle:installerArguments="/SILENT /SP- /NOICONS /NORESTART"' : ""}/>
</item></channel></rss>
`
}

/**
 * Writes [payload], its manifest and, for macOS and Windows, its appcast to
 * [directory], signing the payload with the platform's update seed.
 */
async function prepare(platform: string, payload: string, directory: string) {
  if (!isPlatform(platform)) throw new Error(`Unknown platform ${platform}: ${Object.keys(platforms).join(", ")}`)
  const release = await identity(process.env.GITHUB_REF_TYPE === "tag" ? process.env.GITHUB_REF_NAME : undefined)
  if (path.basename(payload) !== assetName(release, platform)) throw new Error(`Expected ${assetName(release, platform)}`)
  const bytes = await readFile(payload)
  if (bytes.length === 0) throw new Error("Empty payload")
  const manifest: Manifest = {
    ...release,
    platform,
    asset: path.basename(payload),
    length: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  }
  if (platforms[platform].updater) {
    const privateKey = createPrivateKey({
      key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), rawKey(process.env[updater(platform).seed], 32)]),
      format: "der",
      type: "pkcs8",
    })
    const key = publicKey(platform)
    if (!createPublicKey(privateKey).equals(key)) throw new Error("The signing seed and the public key disagree")
    const signature = sign(null, bytes, privateKey)
    if (!verify(null, bytes, key, signature)) throw new Error("The payload's signature does not verify")
    manifest.signature = signature.toString("base64")
  }
  await mkdir(directory, { recursive: true })
  await writeFile(path.join(directory, manifest.asset), bytes)
  await writeFile(path.join(directory, `manifest-${platform}.json`), `${JSON.stringify(manifest, null, 2)}\n`)
  if (manifest.signature) await writeFile(path.join(directory, `appcast-${platform}.xml`), appcast(manifest))
}

/** Checks every platform's payload, signature and appcast in [directory]; returns the files to publish. */
async function verifyArtifacts(directory: string, release: Release): Promise<string[]> {
  const files: string[] = []
  for (const platform of Object.keys(platforms)) {
    const manifestName = `manifest-${platform}.json`
    const feedName = `appcast-${platform}.xml`
    const m = JSON.parse(await readFile(path.join(directory, manifestName), "utf8")) as Manifest
    if (
      m.version !== release.version ||
      m.build !== release.build ||
      m.commit !== release.commit ||
      m.tag !== release.tag ||
      m.platform !== platform ||
      m.asset !== assetName(release, platform)
    ) {
      throw new Error(`${manifestName} is for another release`)
    }
    const bytes = await readFile(path.join(directory, m.asset))
    if (bytes.length !== m.length || createHash("sha256").update(bytes).digest("hex") !== m.sha256) {
      throw new Error(`${m.asset}'s bytes differ from ${manifestName}`)
    }
    files.push(m.asset, manifestName)
    if (!platforms[platform].updater) continue
    if (!verify(null, bytes, publicKey(platform), rawKey(m.signature, 64))) throw new Error(`${m.asset}'s signature does not verify`)
    if ((await readFile(path.join(directory, feedName), "utf8")) !== appcast(m)) throw new Error(`${feedName} differs from ${manifestName}`)
    files.push(feedName)
  }
  return files
}

async function api(endpoint: string, method = "GET", body?: object, allowMissing = false) {
  const token = process.env.GH_TOKEN
  if (!token) throw new Error("GH_TOKEN is required")
  const response = await fetch(`https://api.github.com/repos/${repository}/${endpoint}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  if (response.status === 404 && allowMissing) return null
  if (!response.ok) throw new Error(`GitHub ${method} ${endpoint}: ${response.status}`)
  return response.json()
}

/** Refuses to make anything but a newer build the latest release. */
async function assertForward(release: Release) {
  const latest = await api("releases/latest", "GET", undefined, true)
  if (!latest || latest.tag_name === release.tag) return
  const feed = await fetch(`https://github.com/${repository}/releases/download/${latest.tag_name}/manifest-macos.json`)
  if (!feed.ok) throw new Error(`Cannot read ${latest.tag_name}'s manifest`)
  const previous = (await feed.json()) as Manifest
  if (release.build <= previous.build) throw new Error(`Build ${release.build} is not newer than ${latest.tag_name}'s ${previous.build}`)
}

async function anonymousVerify(release: Release, files: string[], directory: string) {
  for (const name of files) {
    const response = await fetch(`https://github.com/${repository}/releases/download/${release.tag}/${name}`)
    if (!response.ok || new URL(response.url).protocol !== "https:") throw new Error(`Anonymous HTTPS download failed: ${name}`)
    if (!Buffer.from(await response.arrayBuffer()).equals(await readFile(path.join(directory, name)))) {
      throw new Error(`Anonymous download differs: ${name}`)
    }
  }
}

const gh = (...args: string[]) => execFileSync("gh", [...args, "--repo", repository], { stdio: "pipe" })

/**
 * Uploads the verified set to a draft, checks the uploaded bytes, publishes
 * it, checks anonymous downloads, and only then makes it the latest release,
 * which is what the updaters read. Published assets are never replaced: fix
 * a release with a newer one.
 */
async function publish(directory: string) {
  if (process.env.GITHUB_REF_TYPE !== "tag" || !process.env.GITHUB_REF_NAME) throw new Error("Publish from a tagged Actions run")
  const release = await identity(process.env.GITHUB_REF_NAME)
  const files = await verifyArtifacts(directory, release)
  await assertForward(release)
  const remote = await api(`commits/${release.tag}`)
  if (remote.sha !== release.commit) throw new Error("The remote tag no longer points at the built commit")
  const notes = `ListenJar ${release.version}

macOS: a Developer ID signed and notarized DMG for Apple silicon and Intel. Windows: per-user installers for x64 and Arm64. Linux: an x64 tar.gz. Android: an APK. On macOS and Windows ListenJar updates itself from here: Sparkle and WinSparkle check each update's Ed25519 signature before installing it.

The Windows installer has no Authenticode publisher certificate yet, so SmartScreen may warn about it.

Each package here was built by this repository's release workflow at the commit below; check one with \`gh attestation verify <file> --repo ${repository}\`. The APK is signed with the certificate whose SHA-256 is ${androidCertificate}.

Source: ${release.commit}.
`
  let existing = await api(`releases/tags/${release.tag}`, "GET", undefined, true)
  existing ??= await api("releases", "POST", {
    tag_name: release.tag,
    target_commitish: release.commit,
    name: `ListenJar ${release.version}`,
    body: notes,
    draft: true,
    prerelease: false,
    make_latest: "false",
  })
  if (existing.target_commitish !== release.commit || existing.prerelease || existing.body !== notes) {
    throw new Error("The existing release has another commit or notes")
  }
  const staging = await mkdtemp(path.join(tmpdir(), "listenjar-release-"))
  try {
    for (const asset of existing.assets as { name: string }[]) {
      if (!files.includes(asset.name)) throw new Error(`Unexpected asset on the release: ${asset.name}`)
      gh("release", "download", release.tag, "--pattern", asset.name, "--dir", staging)
      if (!(await readFile(path.join(staging, asset.name))).equals(await readFile(path.join(directory, asset.name)))) {
        throw new Error(`An uploaded asset differs: ${asset.name}`)
      }
    }
    for (const name of files) {
      if ((existing.assets as { name: string }[]).some(asset => asset.name === name)) continue
      if (!existing.draft) throw new Error("Cannot add assets to a published release")
      gh("release", "upload", release.tag, path.join(directory, name))
    }
    await rm(staging, { recursive: true, force: true })
    await mkdir(staging)
    gh("release", "download", release.tag, "--dir", staging)
    await verifyArtifacts(staging, release)
    existing = await api(`releases/${existing.id}`)
    const names = (existing.assets as { name: string }[]).map(asset => asset.name)
    if (names.length !== files.length || names.some(name => !files.includes(name))) throw new Error("The release's assets are incomplete")
    if (existing.draft) await api(`releases/${existing.id}`, "PATCH", { draft: false, make_latest: "false" })
    await anonymousVerify(release, files, directory)
    await assertForward(release)
    await api(`releases/${existing.id}`, "PATCH", { make_latest: "true" })
    if ((await api("releases/latest")).tag_name !== release.tag) throw new Error("The release did not become the latest")
    console.log(`Published ${release.tag} as the latest release`)
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

const [command, ...args] = process.argv.slice(2)
if (command === "identity") {
  const release = await identity(args[0])
  console.log(JSON.stringify(release))
  if (process.env.GITHUB_OUTPUT) {
    await appendFile(process.env.GITHUB_OUTPUT, `version=${release.version}\nbuild=${release.build}\ncommit=${release.commit}\n`)
  }
} else if (command === "prepare" && args.length === 3) {
  await prepare(args[0], args[1], args[2])
} else if (command === "verify" && args.length === 1) {
  await verifyArtifacts(args[0], await identity(process.env.GITHUB_REF_TYPE === "tag" ? process.env.GITHUB_REF_NAME : undefined))
} else if (command === "publish" && args.length === 1) {
  await publish(args[0])
} else {
  throw new Error("Usage: release.ts identity [tag] | prepare PLATFORM PAYLOAD DIRECTORY | verify DIRECTORY | publish DIRECTORY")
}
