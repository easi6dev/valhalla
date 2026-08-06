/**
 * PR Mongo Reviewer
 * ---------------------------------------------------------------------------
 * Managed centrally in easi6dev/tada-server-common-source — do not edit in
 * target repositories (it is overwritten by the Sync workflow).
 *
 * Requests a review from the MongoDB owner when a pull request changes
 * MongoDB-related source code. Detection is CONTENT-based, not path-based:
 * a changed `.kt`/`.java` file counts as MongoDB-related when it references
 * Spring Data MongoDB (`org.springframework.data.mongodb`), the MongoDB
 * driver (`com.mongodb.*`), or BSON types (`org.bson.*`). That covers
 * `@Document`, `MongoRepository`/`ReactiveMongoRepository`, `MongoTemplate`,
 * raw driver/aggregation/`ObjectId` code, etc., and (unlike a CODEOWNERS
 * glob) also catches files whose names do not follow the `*Document.kt`
 * convention. Spring config files (`application*.yml` etc.) count when the
 * PR's added/removed lines mention mongo (e.g. a `mongodb-uri` change).
 *
 * No external npm dependencies (mirrors pr-jira-bot.js / pr-reviewer-suggester.js).
 * Requires Node 18+ for global `fetch`.
 */

'use strict';

// ---- Tunables --------------------------------------------------------------

/** GitHub login that owns MongoDB review. */
const MONGO_OWNER_LOGIN = 'simonkim-sungwon';
/** Source files whose content is inspected for the MongoDB signal. */
const SOURCE_EXT_RE = /\.(kt|java)$/;
/** Content signal: Spring Data MongoDB, the MongoDB driver, or BSON types. */
const MONGO_SIGNAL_RE = /org\.springframework\.data\.mongodb|com\.mongodb\.|org\.bson\./;
/** Spring config files, inspected line-by-line rather than by content. */
const CONFIG_FILE_RE = /(^|\/)(application|bootstrap)[^/]*\.(ya?ml|properties)$/;
/** Signal for config files: any mention of mongo on a changed line. */
const CONFIG_SIGNAL_RE = /mongo/i;
/** Max number of changed files to inspect (bounds API calls on huge PRs). */
const MAX_FILES = 300;

// ---- Env -------------------------------------------------------------------

const {
  GITHUB_TOKEN,
  GITHUB_PULL_REQUEST_NUMBER,
  OWNER,
  REPO,
  HEAD_SHA,
  PR_AUTHOR,
} = process.env;

const GH_API = 'https://api.github.com';

// ---- GitHub API helpers ----------------------------------------------------

/**
 * Calls the GitHub REST API and returns the parsed JSON body.
 *
 * @param {string} path - API path beginning with '/'.
 * @returns {Promise<any>} Parsed response, or null on error.
 */
const rest = async (path) => {
  try {
    const res = await fetch(`${GH_API}${path}`, {
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
    if (!res.ok) {
      console.warn(`GET ${path} -> ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (e) {
    console.warn(`GET ${path} failed: ${e.message}`);
    return null;
  }
};

/**
 * Fetches a file's raw content at a given ref via the contents API.
 *
 * @param {string} path - Repository-relative file path.
 * @param {string} ref - Commit SHA / ref to read the file at.
 * @returns {Promise<string|null>} Raw file content, or null if unavailable.
 */
const fetchRaw = async (path, ref) => {
  const encoded = path.split('/').map(encodeURIComponent).join('/');
  const url = `${GH_API}/repos/${OWNER}/${REPO}/contents/${encoded}?ref=${encodeURIComponent(ref)}`;
  try {
    const res = await fetch(url, {
      headers: {
        Accept: 'application/vnd.github.raw+json',
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
    if (!res.ok) {
      console.warn(`GET contents/${path} -> ${res.status}`);
      return null;
    }
    return await res.text();
  } catch (e) {
    console.warn(`GET contents/${path} failed: ${e.message}`);
    return null;
  }
};

// ---- Detection -------------------------------------------------------------

/**
 * Lists the PR's changed files (paginated, capped at MAX_FILES).
 *
 * @returns {Promise<Array<{filename:string,status:string,patch?:string}>>}
 */
const listChangedFiles = async () => {
  const files = [];
  for (let page = 1; page <= Math.ceil(MAX_FILES / 100); page++) {
    const batch = await rest(
      `/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/files?per_page=100&page=${page}`,
    );
    if (!Array.isArray(batch) || batch.length === 0) break;
    files.push(...batch);
    if (batch.length < 100) break;
  }
  if (files.length >= MAX_FILES) {
    console.info(`Large PR; inspecting only the first ${MAX_FILES} changed files.`);
  }
  return files.slice(0, MAX_FILES);
};

/**
 * Decides whether a changed file is MongoDB-related.
 *
 * Source files: the diff hunk (`patch`) is checked first since it is already
 * in hand and also covers deleted files (their removed lines still carry the
 * signal). For added/modified/renamed files whose hunk does not show the
 * signal, the file's full content at HEAD is fetched — a Mongo repository
 * edited far from its imports would otherwise be missed.
 *
 * Config files: only the added/removed lines decide. A hunk's context lines
 * (or the rest of the file) may configure mongo while the actual change is
 * unrelated, so neither the raw patch nor the full content is matched.
 *
 * @param {{filename:string,status:string,patch?:string}} file
 * @returns {Promise<boolean>}
 */
const isMongoRelated = async (file) => {
  if (CONFIG_FILE_RE.test(file.filename)) {
    return Boolean(file.patch) &&
      file.patch.split('\n').some((line) => /^[+-]/.test(line) && CONFIG_SIGNAL_RE.test(line));
  }
  if (!SOURCE_EXT_RE.test(file.filename)) return false;
  if (file.patch && MONGO_SIGNAL_RE.test(file.patch)) return true;
  if (file.status === 'removed') return false; // no HEAD content; patch already checked
  const content = await fetchRaw(file.filename, HEAD_SHA);
  return content != null && MONGO_SIGNAL_RE.test(content);
};

/**
 * Whether the Mongo owner is already (or was ever) engaged on the PR, so we
 * should not request again: currently a pending requested reviewer, has
 * already reviewed, or had a review request earlier that a human removed —
 * re-adding that one on the next `synchronize` would nag.
 *
 * @returns {Promise<boolean>}
 */
const reviewerAlreadyInvolved = async () => {
  const pr = await rest(`/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}`);
  if ((pr?.requested_reviewers || []).some((r) => r.login === MONGO_OWNER_LOGIN)) return true;

  const reviews = await rest(
    `/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/reviews?per_page=100`,
  );
  if (Array.isArray(reviews) && reviews.some((r) => r.user?.login === MONGO_OWNER_LOGIN)) return true;

  // The timeline keeps `review_requested` events even after the request was
  // fulfilled or removed; any earlier request means this PR was already routed.
  for (let page = 1; page <= 3; page++) {
    const events = await rest(
      `/repos/${OWNER}/${REPO}/issues/${GITHUB_PULL_REQUEST_NUMBER}/timeline?per_page=100&page=${page}`,
    );
    if (!Array.isArray(events) || events.length === 0) break;
    if (events.some((e) => e.event === 'review_requested' && e.requested_reviewer?.login === MONGO_OWNER_LOGIN)) {
      return true;
    }
    if (events.length < 100) break;
  }
  return false;
};

/**
 * Requests a review from the Mongo owner.
 */
const requestReviewer = async () => {
  const url = `${GH_API}/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/requested_reviewers`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify({ reviewers: [MONGO_OWNER_LOGIN] }),
  });
  if (res.ok) {
    console.info(`Requested review from ${MONGO_OWNER_LOGIN} -> ${res.status}`);
  } else {
    console.warn(`Failed to request reviewer -> ${res.status}: ${await res.text()}`);
  }
};

// ---- Main ------------------------------------------------------------------

async function run() {
  if (!GITHUB_TOKEN || !GITHUB_PULL_REQUEST_NUMBER || !OWNER || !REPO || !HEAD_SHA || !PR_AUTHOR) {
    console.error('Missing required environment variables. Aborting.');
    return;
  }

  // The author cannot be a reviewer of their own PR (GitHub returns 422).
  if (PR_AUTHOR === MONGO_OWNER_LOGIN) {
    console.info(`PR author is ${MONGO_OWNER_LOGIN}; nothing to request.`);
    return;
  }

  const files = await listChangedFiles();
  if (files.length === 0) {
    console.info('No changed files found. Skipping.');
    return;
  }

  let hit = null;
  for (const file of files) {
    if (await isMongoRelated(file)) {
      hit = file.filename;
      break;
    }
  }

  if (!hit) {
    console.info('No MongoDB-related changes detected. Skipping.');
    return;
  }
  console.info(`MongoDB-related change detected in "${hit}".`);

  if (await reviewerAlreadyInvolved()) {
    console.info(`${MONGO_OWNER_LOGIN} is already requested or has reviewed. Skipping.`);
    return;
  }

  await requestReviewer();
}

run();
