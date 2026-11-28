// Sends a release's iOS build to TestFlight: uploads the .ipa that
// tool/package-ios.sh exported, waits for App Store Connect to process it,
// sets its What to Test to the release's notes (`tool/release.ts notes`), adds
// it to the external "Public" group, whose public link takes up to 10,000
// testers, and submits it to Beta App Review, after which that group can
// install it. Each step it finds already done it skips, so a rerun picks up
// where a failed one stopped.
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

// A build VALID moments ago can be missing from TestFlight's own endpoints
// for a while: they answer 404, "no resource of type 'builds'", until they
// catch up.
async function once404sClear<T>(step: () => Promise<T>): Promise<T> {
  const deadline = Date.now() + 15 * 60_000
  for (;;) {
    try {
      return await step()
    } catch (e) {
      if (!String(e).includes(": 404 ") || Date.now() > deadline) throw e
      console.log("TestFlight doesn't list the build yet; trying again in 30 s")
      await sleep(30_000)
    }
  }
}

const ipa = process.argv[2] ?? (() => { throw new Error("Usage: node tool/testflight.ts <ipa>") })()
const node = (...args: string[]) => JSON.parse(execFileSync("node", ["tool/release.ts", ...args], { encoding: "utf8" }))
const { version, build } = node("identity")
const changes: string[] = node("notes")

// TestFlight shows the version and build above What to Test.
const whatsNew = `${changes.length ? `What's new:\n${changes.map(change => `• ${change}`).join("\n")}` : "Fixes behind the scenes, nothing new to try."}

Found a bug or something confusing? Take a screenshot and send it as TestFlight feedback.`.slice(0, 4000)

const [app] = await list(`/v1/apps?filter[bundleId]=${bundleId}&fields[apps]=bundleId`)
if (!app) throw new Error(`No App Store Connect app for ${bundleId}`)

const find = async () => (await list(`/v1/builds?filter[app]=${app.id}&filter[version]=${build}`
  + `&filter[preReleaseVersion.version]=${version}&fields[builds]=processingState,version`))[0]

let uploaded = await find()
if (uploaded) {
  console.log(`${version} build ${build} is already on App Store Connect`)
} else {
  console.log(`Uploading ${ipa} (${version} build ${build})`)
  execFileSync("xcrun", ["altool", "--upload-package", ipa, "--api-key", keyId, "--api-issuer", issuer, "--p8-file-path", keyPath],
    { stdio: "inherit" })
}

// Processing usually takes 5–20 minutes.
const deadline = Date.now() + 90 * 60_000
for (;;) {
  uploaded = await find()
  const state = uploaded?.attributes.processingState
  console.log(`Build ${build}: ${state ?? "not listed yet"}`)
  if (state === "VALID") break
  if (state === "FAILED" || state === "INVALID") throw new Error(`App Store Connect could not process build ${build}: ${state}`)
  if (Date.now() > deadline) throw new Error(`Build ${build} still not processed after 90 minutes`)
  await sleep(30_000)
}
const buildId = uploaded!.id

// The relationship takes no filters.
const localization = (await list(`/v1/builds/${buildId}/betaBuildLocalizations`)).find(each => each.attributes.locale === locale)
if (localization) {
  await api("PATCH", `/v1/betaBuildLocalizations/${localization.id}`,
    { data: { type: "betaBuildLocalizations", id: localization.id, attributes: { whatsNew } } })
} else {
  await api("POST", "/v1/betaBuildLocalizations", { data: { type: "betaBuildLocalizations", attributes: { locale, whatsNew },
    relationships: { build: { data: { type: "builds", id: buildId } } } } })
}

// Every push to master is a release, so TestFlight would email and push every
// tester several times a day. Only a release with notes for listeners tells
// them; the rest still reach TestFlight and its automatic updates, silently.
const autoNotifyEnabled = changes.length > 0
await once404sClear(async () => {
  const details = (await api("GET", `/v1/builds/${buildId}/buildBetaDetail`))!.data as Resource
  await api("PATCH", `/v1/buildBetaDetails/${details.id}`,
    { data: { type: "buildBetaDetails", id: details.id, attributes: { autoNotifyEnabled } } })
})
console.log(autoNotifyEnabled ? "Testers get told about this build" : "No release notes: testers aren't told about this build")

const external = (await list(`/v1/apps/${app.id}/betaGroups`))
  .find(each => each.attributes.name === group && each.attributes.isInternalGroup === false)
if (!external) throw new Error(`No external TestFlight group named ${group}`)
await once404sClear(() =>
  api("POST", `/v1/betaGroups/${external.id}/relationships/builds`, { data: [{ type: "builds", id: buildId }] }))
console.log(`Added build ${build} to ${group}`)

const submitted = (await api("GET", `/v1/builds/${buildId}/betaAppReviewSubmission`))?.data as Resource | null | undefined
if (submitted) {
  console.log(`${version} (${build}) is already in Beta App Review: ${submitted.attributes.betaReviewState}`)
} else {
  // Apple takes only a few builds into Beta App Review at once
  // (SUBMISSION_LIMIT_REACHED), and a release goes out on every push. So only
  // the newest build waits: expiring an older one that's still waiting is the
  // API's only way to take it out of the queue. One Apple is reviewing, or has
  // approved, stays.
  const document = (await api("GET", `/v1/builds?filter[app]=${app.id}&filter[expired]=false`
    + `&fields[builds]=version,betaAppReviewSubmission&include=betaAppReviewSubmission`
    + `&fields[betaAppReviewSubmissions]=betaReviewState&limit=200`))! as Document & { included?: Resource[] }
  const states = new Map((document.included ?? []).map(each => [each.id, each.attributes.betaReviewState]))
  for (const older of document.data as (Resource & { relationships?: { betaAppReviewSubmission?: { data?: { id: string } | null } } })[]) {
    const submission = older.relationships?.betaAppReviewSubmission?.data?.id
    if (Number(older.attributes.version) >= Number(build) || !submission) continue
    if (states.get(submission) !== "WAITING_FOR_REVIEW") continue
    await api("PATCH", `/v1/builds/${older.id}`, { data: { type: "builds", id: older.id, attributes: { expired: true } } })
    console.log(`Expired build ${older.attributes.version}, which was still waiting for Beta App Review`)
  }
  await once404sClear(() => api("POST", "/v1/betaAppReviewSubmissions",
    { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: buildId } } } } }))
  console.log(`Submitted ${version} (${build}) to Beta App Review`)
}
