// Sends a release's iOS build to TestFlight: uploads the .ipa that
// tool/package-ios.sh exported, waits for App Store Connect to process it,
// says what's new (the released commit's subject), adds it to the external
// "Public" group, whose public link takes up to 10,000 testers, and submits it
// to Beta App Review, after which that group can install it.
//
//   node tool/testflight.ts <ipa>
//
//   APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID  an App Store Connect
//   APP_STORE_CONNECT_KEY_PATH                             API key (Admin) and its .p8
import { execFileSync } from "node:child_process"
import { createPrivateKey, sign } from "node:crypto"
import { readFileSync } from "node:fs"

const bundleId = "com.listenjar.desktop"
const group = "Public"
const locale = "en-US"

const env = (name: string) => process.env[name] || (() => { throw new Error(`Set ${name}`) })()
const keyId = env("APP_STORE_CONNECT_KEY_ID")
const issuer = env("APP_STORE_CONNECT_ISSUER_ID")
const keyPath = env("APP_STORE_CONNECT_KEY_PATH")
const key = createPrivateKey(readFileSync(keyPath))

function token(): string {
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url")
  const now = Math.floor(Date.now() / 1000)
  const unsigned = `${encode({ alg: "ES256", kid: keyId, typ: "JWT" })}.${encode({ iss: issuer, iat: now, exp: now + 900, aud: "appstoreconnect-v1" })}`
  return `${unsigned}.${sign("sha256", Buffer.from(unsigned), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`
}

type Resource = { id: string; attributes: Record<string, unknown> }
type Document = { data: Resource | Resource[] }

async function api(method: string, path: string, body?: object): Promise<Document | undefined> {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body && JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${text}`)
  return text ? JSON.parse(text) : undefined
}
const list = async (path: string) => (await api("GET", path))!.data as Resource[]
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

const ipa = process.argv[2] ?? (() => { throw new Error("Usage: node tool/testflight.ts <ipa>") })()
const { version, build, commit } = JSON.parse(execFileSync("node", ["tool/release.ts", "identity"], { encoding: "utf8" }))

// What's new: the commit this release was cut from (version.yaml's
// `Source-commit:` trailer on "Release vX.Y.Z"), else the built commit.
const git = (...args: string[]) => execFileSync("git", args, { encoding: "utf8" }).trim()
const source = /^Source-commit:\s*(\S+)/m.exec(git("log", "-1", "--format=%B", commit))?.[1] ?? commit
const whatsNew = `ListenJar ${version} (${build})\n\n${git("log", "-1", "--format=%s", source)}`.slice(0, 4000)

const [app] = await list(`/v1/apps?filter[bundleId]=${bundleId}&fields[apps]=bundleId`)
if (!app) throw new Error(`No App Store Connect app for ${bundleId}`)

console.log(`Uploading ${ipa} (${version} build ${build})`)
execFileSync("xcrun", ["altool", "--upload-package", ipa, "--api-key", keyId, "--api-issuer", issuer, "--p8-file-path", keyPath],
  { stdio: "inherit" })

// Processing usually takes 5–20 minutes.
const deadline = Date.now() + 90 * 60_000
let uploaded: Resource | undefined
for (;;) {
  ;[uploaded] = await list(`/v1/builds?filter[app]=${app.id}&filter[version]=${build}`
    + `&filter[preReleaseVersion.version]=${version}&fields[builds]=processingState,version`)
  const state = uploaded?.attributes.processingState
  console.log(`Build ${build}: ${state ?? "not listed yet"}`)
  if (state === "VALID") break
  if (state === "FAILED" || state === "INVALID") throw new Error(`App Store Connect could not process build ${build}: ${state}`)
  if (Date.now() > deadline) throw new Error(`Build ${build} still not processed after 90 minutes`)
  await sleep(30_000)
}
const buildId = uploaded!.id

const [localization] = await list(`/v1/builds/${buildId}/betaBuildLocalizations?filter[locale]=${locale}`)
if (localization) {
  await api("PATCH", `/v1/betaBuildLocalizations/${localization.id}`,
    { data: { type: "betaBuildLocalizations", id: localization.id, attributes: { whatsNew } } })
} else {
  await api("POST", "/v1/betaBuildLocalizations", { data: { type: "betaBuildLocalizations", attributes: { locale, whatsNew },
    relationships: { build: { data: { type: "builds", id: buildId } } } } })
}

const [external] = await list(`/v1/apps/${app.id}/betaGroups?filter[name]=${group}&filter[isInternalGroup]=false`)
if (!external) throw new Error(`No external TestFlight group named ${group}`)
await api("POST", `/v1/betaGroups/${external.id}/relationships/builds`, { data: [{ type: "builds", id: buildId }] })
console.log(`Added build ${build} to ${group}`)

await api("POST", "/v1/betaAppReviewSubmissions",
  { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: buildId } } } } })
console.log(`Submitted ${version} (${build}) to Beta App Review`)
