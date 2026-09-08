#!/usr/bin/env node

import { createHash, createPrivateKey, sign } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const API_BASE = "https://api.appstoreconnect.apple.com";
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_CONFIG = path.join(SCRIPT_DIR, "config.json");
const VALID_OPERATIONS = new Set(["validate", "verify", "sync", "start", "review-and-start"]);
const SYNCHRONIZABLE_EXPERIMENT_STATES = new Set(["PREPARE_FOR_SUBMISSION", "REJECTED"]);
const VERIFIABLE_EXPERIMENT_STATES = new Set([
  ...SYNCHRONIZABLE_EXPERIMENT_STATES,
  "READY_FOR_REVIEW",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "ACCEPTED",
  "APPROVED",
  "COMPLETED",
  "STOPPED",
]);
const REVIEW_PENDING_EXPERIMENT_STATES = new Set([
  "READY_FOR_REVIEW",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "ACCEPTED",
]);
const ACTIVE_REVIEW_SUBMISSION_STATES = new Set([
  "READY_FOR_REVIEW",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "UNRESOLVED_ISSUES",
]);

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`Missing value for ${name}`);
  }
  return value;
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Required environment variable is empty: ${name}`);
  return value;
}

function createToken() {
  const issuerId = requiredEnvironment("ASC_ISSUER_ID");
  const keyId = requiredEnvironment("ASC_KEY_ID");
  const privateKeyText = requiredEnvironment("ASC_PRIVATE_KEY").replace(/\\n/g, "\n");
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({ iss: issuerId, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }),
  );
  const signingInput = `${header}.${payload}`;
  const signature = sign("sha256", Buffer.from(signingInput), {
    key: createPrivateKey(privateKeyText),
    dsaEncoding: "ieee-p1363",
  });
  return {
    value: `${signingInput}.${signature.toString("base64url")}`,
    refreshAt: (now + 13 * 60) * 1000,
  };
}

let token;

function authorizationToken() {
  if (!token || Date.now() >= token.refreshAt) token = createToken();
  return token.value;
}

async function apiRequest(resourcePath, { method = "GET", body } = {}) {
  const response = await fetch(new URL(resourcePath, API_BASE), {
    method,
    headers: {
      Authorization: `Bearer ${authorizationToken()}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(60_000),
  });

  const text = await response.text();
  const json = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const details = (json?.errors ?? [])
      .map((error) => [error.status, error.code, error.title, error.detail].filter(Boolean).join(" · "))
      .join(" | ");
    throw new Error(`${method} ${resourcePath} failed (${response.status}): ${details || text}`);
  }
  return json;
}

async function listAll(resourcePath) {
  const resources = [];
  let next = resourcePath;
  while (next) {
    const response = await apiRequest(next);
    resources.push(...(response.data ?? []));
    next = response.links?.next ?? null;
  }
  return resources;
}

function pngDimensions(buffer, filePath) {
  const signature = "89504e470d0a1a0a";
  if (buffer.subarray(0, 8).toString("hex") !== signature) {
    throw new Error(`Not a PNG file: ${filePath}`);
  }
  const width = buffer.readUInt32BE(16);
  const height = buffer.readUInt32BE(20);
  const colorType = buffer[25];
  const hasTransparencyChunk = buffer.includes(Buffer.from("tRNS"));
  return { width, height, colorType, hasTransparencyChunk };
}

async function desiredScreenshots(config, assetsDirectory, treatment) {
  const byLocale = new Map();
  for (const locale of config.locales) {
    const screenshots = [];
    for (const fileName of config.screenshots) {
      const filePath = path.join(assetsDirectory, treatment.directory, locale, fileName);
      const metadata = await stat(filePath);
      const contents = await readFile(filePath);
      const dimensions = pngDimensions(contents, filePath);
      if (dimensions.width !== 1320 || dimensions.height !== 2868) {
        throw new Error(
          `Unexpected dimensions for ${filePath}: ${dimensions.width}x${dimensions.height}`,
        );
      }
      if (
        dimensions.colorType === 4 ||
        dimensions.colorType === 6 ||
        dimensions.hasTransparencyChunk
      ) {
        throw new Error(`PNG must not contain an alpha channel: ${filePath}`);
      }
      screenshots.push({
        fileName,
        filePath,
        fileSize: metadata.size,
        checksum: createHash("md5").update(contents).digest("hex"),
        contents,
      });
    }
    byLocale.set(locale, screenshots);
  }
  return byLocale;
}

function assertConfig(config) {
  for (const key of [
    "appId",
    "experimentId",
    "experimentName",
    "platform",
    "trafficProportion",
    "displayType",
  ]) {
    if (!config[key]) throw new Error(`Missing config value: ${key}`);
  }
  if (config.locales?.length !== 4) throw new Error("Exactly four locales are required");
  if (config.screenshots?.length !== 8) throw new Error("Exactly eight screenshots are required");
  if (config.treatments?.length !== 2) throw new Error("Exactly two treatments are required");
}

async function ensureLocalization(treatmentId, locale, operation) {
  const localizations = await listAll(
    `/v1/appStoreVersionExperimentTreatments/${treatmentId}/appStoreVersionExperimentTreatmentLocalizations?limit=200`,
  );
  const matches = localizations.filter((item) => item.attributes?.locale === locale);
  if (matches.length > 1) throw new Error(`Multiple treatment localizations found for ${locale}`);
  if (matches.length === 1) return matches[0];
  if (operation !== "sync") throw new Error(`Missing treatment localization: ${locale}`);

  const response = await apiRequest("/v1/appStoreVersionExperimentTreatmentLocalizations", {
    method: "POST",
    body: {
      data: {
        type: "appStoreVersionExperimentTreatmentLocalizations",
        attributes: { locale },
        relationships: {
          appStoreVersionExperimentTreatment: {
            data: { type: "appStoreVersionExperimentTreatments", id: treatmentId },
          },
        },
      },
    },
  });
  console.log(`  created localization ${locale}`);
  return response.data;
}

async function ensureScreenshotSet(localizationId, displayType, operation) {
  const sets = await listAll(
    `/v1/appStoreVersionExperimentTreatmentLocalizations/${localizationId}/appScreenshotSets?filter%5BscreenshotDisplayType%5D=${encodeURIComponent(displayType)}&limit=200`,
  );
  const matches = sets.filter((item) => item.attributes?.screenshotDisplayType === displayType);
  if (matches.length > 1) throw new Error(`Multiple screenshot sets found for ${displayType}`);
  if (matches.length === 1) return matches[0];
  if (operation !== "sync") throw new Error(`Missing screenshot set: ${displayType}`);

  const response = await apiRequest("/v1/appScreenshotSets", {
    method: "POST",
    body: {
      data: {
        type: "appScreenshotSets",
        attributes: { screenshotDisplayType: displayType },
        relationships: {
          appStoreVersionExperimentTreatmentLocalization: {
            data: {
              type: "appStoreVersionExperimentTreatmentLocalizations",
              id: localizationId,
            },
          },
        },
      },
    },
  });
  console.log(`  created screenshot set ${displayType}`);
  return response.data;
}

async function listScreenshots(setId) {
  return listAll(`/v1/appScreenshotSets/${setId}/appScreenshots?limit=50`);
}

function screenshotState(item) {
  return item.attributes?.assetDeliveryState?.state ?? "UNKNOWN";
}

function matchesDesired(existing, desired) {
  return (
    existing.length === desired.length &&
    existing.every((item, index) =>
      item.attributes?.fileName === desired[index].fileName &&
      item.attributes?.sourceFileChecksum?.toLowerCase() === desired[index].checksum &&
      screenshotState(item) === "COMPLETE",
    )
  );
}

function screenshotSummary(existing) {
  return existing.map((item, index) => ({
    position: index + 1,
    fileName: item.attributes?.fileName ?? null,
    checksum: item.attributes?.sourceFileChecksum?.toLowerCase() ?? null,
    state: screenshotState(item),
  }));
}

async function waitForDesiredSet(setId, desired) {
  const deadline = Date.now() + 180_000;
  let existing = [];
  while (Date.now() < deadline) {
    existing = await listScreenshots(setId);
    if (matchesDesired(existing, desired)) return;
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }

  const expected = desired.map((item, index) => ({
    position: index + 1,
    fileName: item.fileName,
    checksum: item.checksum,
    state: "COMPLETE",
  }));
  throw new Error(
    `Final screenshot set did not converge: ${JSON.stringify({ actual: screenshotSummary(existing), expected })}`,
  );
}

async function uploadScreenshot(setId, screenshot) {
  const reservation = await apiRequest("/v1/appScreenshots", {
    method: "POST",
    body: {
      data: {
        type: "appScreenshots",
        attributes: { fileName: screenshot.fileName, fileSize: screenshot.fileSize },
        relationships: {
          appScreenshotSet: {
            data: { type: "appScreenshotSets", id: setId },
          },
        },
      },
    },
  });

  const screenshotId = reservation.data.id;
  const operations = reservation.data.attributes?.uploadOperations ?? [];
  if (operations.length === 0) throw new Error(`No upload operations returned for ${screenshot.fileName}`);

  for (const operation of operations) {
    const start = operation.offset;
    const end = start + operation.length;
    const headers = Object.fromEntries(
      (operation.requestHeaders ?? []).map((header) => [header.name, header.value]),
    );
    const response = await fetch(operation.url, {
      method: operation.method,
      headers,
      body: screenshot.contents.subarray(start, end),
      signal: AbortSignal.timeout(120_000),
    });
    if (!response.ok) {
      throw new Error(`Binary upload failed for ${screenshot.fileName} (${response.status})`);
    }
  }

  await apiRequest(`/v1/appScreenshots/${screenshotId}`, {
    method: "PATCH",
    body: {
      data: {
        type: "appScreenshots",
        id: screenshotId,
        attributes: { sourceFileChecksum: screenshot.checksum, uploaded: true },
      },
    },
  });

  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline) {
    const current = (await apiRequest(`/v1/appScreenshots/${screenshotId}`)).data;
    const state = screenshotState(current);
    if (state === "COMPLETE") return;
    if (state === "FAILED") {
      const errors = current.attributes?.assetDeliveryState?.errors ?? [];
      throw new Error(`Apple failed to process ${screenshot.fileName}: ${JSON.stringify(errors)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`Timed out processing ${screenshot.fileName}`);
}

async function synchronizeSet(setId, desired, operation) {
  let existing = await listScreenshots(setId);
  if (matchesDesired(existing, desired)) {
    console.log("  screenshots already match (8/8)");
    return;
  }
  if (operation !== "sync") {
    const actual = existing.map((item) => `${item.attributes?.fileName}:${screenshotState(item)}`);
    throw new Error(`Screenshot set differs: ${actual.join(", ") || "empty"}`);
  }

  console.log(`  replacing ${existing.length} existing screenshot(s)`);
  for (const item of existing) {
    await apiRequest(`/v1/appScreenshots/${item.id}`, { method: "DELETE" });
  }

  for (let index = 0; index < desired.length; index += 1) {
    const screenshot = desired[index];
    console.log(`  uploading ${index + 1}/${desired.length} ${screenshot.fileName}`);
    await uploadScreenshot(setId, screenshot);
  }

  await waitForDesiredSet(setId, desired);
  console.log("  verified screenshot order and checksums (8/8)");
}

async function startExperiment(config, experiment, { allowReviewPending = false } = {}) {
  const attributes = experiment.attributes ?? {};
  if (attributes.state === "APPROVED" && attributes.startDate) {
    console.log(`Experiment is already running since ${attributes.startDate}`);
    return experiment;
  }

  const response = await apiRequest(`/v2/appStoreVersionExperiments/${config.experimentId}`, {
    method: "PATCH",
    body: {
      data: {
        type: "appStoreVersionExperiments",
        id: config.experimentId,
        attributes: { started: true },
      },
    },
  });
  const updated = response.data.attributes ?? {};
  console.log(
    `Start requested: state=${updated.state}, reviewRequired=${updated.reviewRequired}, startDate=${updated.startDate ?? "pending"}`,
  );

  if (updated.state === "APPROVED" && updated.startDate) {
    console.log(`Experiment is running since ${updated.startDate}`);
    return response.data;
  }
  if (REVIEW_PENDING_EXPERIMENT_STATES.has(updated.state)) {
    const message =
      `Experiment start is pending App Review: state=${updated.state}, ` +
      `reviewRequired=${updated.reviewRequired}`;
    if (allowReviewPending) {
      console.log(message);
      return response.data;
    }
    throw new Error(message);
  }
  throw new Error(
    `Apple did not confirm the experiment start: state=${updated.state}, startDate=${updated.startDate ?? "missing"}`,
  );
}

function experimentItemId(item) {
  return (
    item.relationships?.appStoreVersionExperimentV2?.data?.id ??
    item.relationships?.appStoreVersionExperiment?.data?.id ??
    null
  );
}

async function activeReviewSubmissions(config) {
  const states = [...ACTIVE_REVIEW_SUBMISSION_STATES].join(",");
  return apiRequest(
    `/v1/apps/${config.appId}/reviewSubmissions?filter%5Bplatform%5D=IOS&filter%5Bstate%5D=${states}&limit=200`,
  );
}

async function reviewSubmissionItems(submissionId) {
  return listAll(
    `/v1/reviewSubmissions/${submissionId}/items?fields%5BreviewSubmissionItems%5D=state,appStoreVersionExperiment,appStoreVersionExperimentV2&limit=200`,
  );
}

async function assertPpoOnlyReviewSubmission(config, submissionId) {
  const items = await reviewSubmissionItems(submissionId);
  if (items.length !== 1 || experimentItemId(items[0]) !== config.experimentId) {
    const summary = items.map((item) => ({
      id: item.id,
      experimentId: experimentItemId(item),
    }));
    throw new Error(
      `Review submission must contain only the configured PPO experiment: ${JSON.stringify(summary)}`,
    );
  }
}

async function waitForSubmittedReview(submissionId) {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const submission = (await apiRequest(`/v1/reviewSubmissions/${submissionId}`)).data;
    const state = submission.attributes?.state;
    if (state === "WAITING_FOR_REVIEW" || state === "IN_REVIEW" || state === "COMPLETE") {
      return submission;
    }
    if (state === "UNRESOLVED_ISSUES") {
      throw new Error(`PPO review submission has unresolved issues: ${submissionId}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`Timed out waiting for PPO review submission ${submissionId}`);
}

async function submitExperimentForReview(config) {
  const response = await activeReviewSubmissions(config);
  const itemsBySubmissionId = new Map();
  for (const submission of response.data ?? []) {
    itemsBySubmissionId.set(submission.id, await reviewSubmissionItems(submission.id));
  }
  const matches = [];
  for (const submission of response.data ?? []) {
    const items = itemsBySubmissionId.get(submission.id) ?? [];
    if (items.some((item) => experimentItemId(item) === config.experimentId)) {
      matches.push(submission);
    }
  }
  if (matches.length > 1) {
    throw new Error("PPO experiment is attached to multiple active review submissions");
  }

  let submission = matches[0];
  if (!submission) {
    const emptyDrafts = (response.data ?? []).filter(
      (candidate) =>
        candidate.attributes?.state === "READY_FOR_REVIEW" &&
        (itemsBySubmissionId.get(candidate.id)?.length ?? 0) === 0,
    );
    if (emptyDrafts.length > 1) {
      throw new Error("Multiple empty review submission drafts found; refusing to choose one");
    }
    submission = emptyDrafts[0];
    if (submission) {
      console.log(`Reusing empty PPO review submission draft ${submission.id}`);
    } else {
      submission = (
        await apiRequest("/v1/reviewSubmissions", {
          method: "POST",
          body: {
            data: {
              type: "reviewSubmissions",
              attributes: { platform: "IOS" },
              relationships: {
                app: { data: { type: "apps", id: config.appId } },
              },
            },
          },
        })
      ).data;
      console.log(`Created PPO-only review submission ${submission.id}`);
    }

    await apiRequest("/v1/reviewSubmissionItems", {
      method: "POST",
      body: {
        data: {
          type: "reviewSubmissionItems",
          relationships: {
            reviewSubmission: {
              data: { type: "reviewSubmissions", id: submission.id },
            },
            appStoreVersionExperimentV2: {
              data: { type: "appStoreVersionExperiments", id: config.experimentId },
            },
          },
        },
      },
    });
    console.log("Added only the configured PPO experiment to the review submission");
  }

  await assertPpoOnlyReviewSubmission(config, submission.id);
  submission = (await apiRequest(`/v1/reviewSubmissions/${submission.id}`)).data;
  const state = submission.attributes?.state;
  if (state === "WAITING_FOR_REVIEW" || state === "IN_REVIEW") {
    console.log(`PPO review is already pending: ${state}`);
    return submission;
  }
  if (state !== "READY_FOR_REVIEW") {
    throw new Error(`PPO review submission cannot be submitted from state ${state}`);
  }

  const submitted = (
    await apiRequest(`/v1/reviewSubmissions/${submission.id}`, {
      method: "PATCH",
      body: {
        data: {
          type: "reviewSubmissions",
          id: submission.id,
          attributes: { submitted: true },
        },
      },
    })
  ).data;
  console.log(`Submitted PPO experiment for App Review: ${submitted.attributes?.state}`);
  return waitForSubmittedReview(submission.id);
}

async function reviewAndStart(config, experiment) {
  const state = experiment.attributes?.state;
  if (state === "COMPLETED" || state === "STOPPED") {
    console.log(`PPO experiment is in terminal state ${state}; no action required`);
    return;
  }
  if (state === "APPROVED" || state === "ACCEPTED") {
    await startExperiment(config, experiment);
    return;
  }
  if (state === "WAITING_FOR_REVIEW" || state === "IN_REVIEW") {
    console.log(`PPO experiment is pending App Review: ${state}`);
    return;
  }
  if (!new Set(["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "REJECTED"]).has(state)) {
    throw new Error(`PPO experiment cannot be reviewed or started from state ${state}`);
  }

  if (state === "PREPARE_FOR_SUBMISSION") {
    const startRequested = await startExperiment(config, experiment, {
      allowReviewPending: true,
    });
    const requestedState = startRequested.attributes?.state;
    if (requestedState === "APPROVED" && startRequested.attributes?.startDate) {
      return;
    }
    if (requestedState === "WAITING_FOR_REVIEW" || requestedState === "IN_REVIEW") {
      console.log(`PPO experiment is pending App Review: ${requestedState}`);
      return;
    }
  }

  const submission = await submitExperimentForReview(config);
  console.log(`PPO review submission state: ${submission.attributes?.state}`);
  const refreshed = (
    await apiRequest(`/v2/appStoreVersionExperiments/${config.experimentId}`)
  ).data;
  if (refreshed.attributes?.state === "ACCEPTED" || refreshed.attributes?.state === "APPROVED") {
    await startExperiment(config, refreshed);
  } else {
    console.log(`PPO start will resume after App Review: ${refreshed.attributes?.state}`);
  }
}

async function main() {
  const operation = argument("--operation", "validate");
  const configPath = path.resolve(argument("--config", DEFAULT_CONFIG));
  const assetsArgument = argument("--assets-dir", null);
  if (!VALID_OPERATIONS.has(operation)) {
    throw new Error(`Unsupported operation: ${operation}`);
  }
  if (!assetsArgument) throw new Error("--assets-dir is required");
  const assetsDirectory = path.resolve(assetsArgument);

  const config = JSON.parse(await readFile(configPath, "utf8"));
  assertConfig(config);
  const desiredByTreatment = new Map();
  for (const treatment of config.treatments) {
    desiredByTreatment.set(
      treatment.id,
      await desiredScreenshots(config, assetsDirectory, treatment),
    );
  }
  console.log(`Validated ${config.treatments.length * config.locales.length * config.screenshots.length} PNG assets`);
  if (operation === "validate") return;

  const experiment = (
    await apiRequest(
      `/v2/appStoreVersionExperiments/${config.experimentId}?include=app,appStoreVersionExperimentTreatments`,
    )
  ).data;
  const experimentState = experiment.attributes?.state;
  const allowedStates =
    operation === "sync" ? SYNCHRONIZABLE_EXPERIMENT_STATES : VERIFIABLE_EXPERIMENT_STATES;
  if (!allowedStates.has(experimentState)) {
    throw new Error(`Experiment state does not allow ${operation}: ${experimentState}`);
  }
  if (experiment.relationships?.app?.data?.id !== config.appId) {
    throw new Error(`Experiment does not belong to configured app ${config.appId}`);
  }
  if (
    experiment.attributes?.name !== config.experimentName ||
    experiment.attributes?.platform !== config.platform ||
    experiment.attributes?.trafficProportion !== config.trafficProportion
  ) {
    throw new Error("Experiment name, platform, or traffic proportion does not match config");
  }
  console.log(
    `Experiment: ${experiment.attributes?.name} (${experimentState}, ` +
      `reviewRequired=${experiment.attributes?.reviewRequired})`,
  );

  const experimentTreatmentIds = new Set(
    (experiment.relationships?.appStoreVersionExperimentTreatments?.data ?? []).map(
      (item) => item.id,
    ),
  );
  for (const treatment of config.treatments) {
    if (!experimentTreatmentIds.has(treatment.id)) {
      throw new Error(`Treatment ${treatment.id} does not belong to the configured experiment`);
    }
  }

  for (const treatment of config.treatments) {
    const remoteTreatment = (await apiRequest(`/v1/appStoreVersionExperimentTreatments/${treatment.id}`)).data;
    if (remoteTreatment.attributes?.name !== treatment.name) {
      throw new Error(
        `Treatment name mismatch for ${treatment.id}: ${remoteTreatment.attributes?.name}`,
      );
    }
    console.log(`Treatment: ${treatment.name}`);

    for (const locale of config.locales) {
      console.log(` ${locale}`);
      const localization = await ensureLocalization(treatment.id, locale, operation);
      const screenshotSet = await ensureScreenshotSet(localization.id, config.displayType, operation);
      try {
        await synchronizeSet(
          screenshotSet.id,
          desiredByTreatment.get(treatment.id).get(locale),
          operation,
        );
      } catch (error) {
        throw new Error(`${treatment.name}/${locale}: ${error.message}`, { cause: error });
      }
    }
  }

  if (operation === "start") {
    await startExperiment(config, experiment);
  } else if (operation === "review-and-start") {
    await reviewAndStart(config, experiment);
  }
}

main().catch((error) => {
  console.error(`::error::${error.message}`);
  process.exitCode = 1;
});
