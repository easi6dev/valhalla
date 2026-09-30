/**
 * PR DB Reviewer
 * ---------------------------------------------------------------------------
 * Managed centrally in easi6dev/tada-server-common-source — do not edit in
 * target repositories (it is overwritten by the Sync workflow).
 *
 * Requests a review from the DB owner when a pull request changes either:
 *
 * 1. MongoDB-related source code. Detection is CONTENT-based, not path-based:
 *    a changed `.kt`/`.java` file counts as MongoDB-related when it references
 *    Spring Data MongoDB (`org.springframework.data.mongodb`), the MongoDB
 *    driver (`com.mongodb.*`), or BSON types (`org.bson.*`). That covers
 *    `@Document`, `MongoRepository`/`ReactiveMongoRepository`, `MongoTemplate`,
 *    raw driver/aggregation/`ObjectId` code, etc., and (unlike a CODEOWNERS
 *    glob) also catches files whose names do not follow the `*Document.kt`
 *    convention. Spring config files (`application*.yml` etc.) count when the
 *    PR's added/removed lines mention mongo (e.g. a `mongodb-uri` change).
 *
 * 2. Queries against HOT RDB tables (e.g. `ride_entity`, which is queried
 *    100M+ times a day). The list's single source of truth is
 *    `.github/db-reviewer/hot-tables.json` in easi6dev/tada-server-common-source
 *    (HOT_TABLES_SOURCE), read at run time so additions apply without a Sync.
 *    If it cannot be read, the job fails visibly and this rule is skipped.
 *    Two stages:
 *    a. Deterministic: keep only non-test query-layer files, picked by the
 *       Spring/JPA naming convention (`*Repository*`, `*Dao*`,
 *       `*Specification*`, `*QueryHelper*`, `*Mapper*`, `*Entity*`).
 *    b. An LLM (via LiteLLM) reads those diffs and decides whether they change
 *       the SQL issued against a hot table (e.g. a predicate edit) versus
 *       comment/formatting changes or queries on other tables.
 *    When the LLM cannot decide (missing config, failure, oversized diff),
 *    the review is requested only if a query file is named after a hot entity
 *    or its diff hunks name the entity/Q-type or the table.
 *
 * `.sql` / Liquibase changelog changes are routed by CODEOWNERS, not here.
 *
 * No external npm dependencies (mirrors pr-jira-bot.js / pr-reviewer-suggester.js).
 * Requires Node 18+ for global `fetch`.
 */

'use strict';

// ---- Tunables --------------------------------------------------------------

/** GitHub login that owns DB (MongoDB and hot-table query) review. */
const DB_OWNER_LOGIN = 'simonkim-sungwon';
/** Source files whose content is inspected for DB signals. */
const SOURCE_EXT_RE = /\.(kt|java)$/;
/** Content signal: Spring Data MongoDB, the MongoDB driver, or BSON types. */
const MONGO_SIGNAL_RE = /org\.springframework\.data\.mongodb|com\.mongodb\.|org\.bson\./;
/** Spring config files, inspected line-by-line rather than by content. */
const CONFIG_FILE_RE = /(^|\/)(application|bootstrap)[^/]*\.(ya?ml|properties)$/;
/** Signal for config files: any mention of mongo on a changed line. */
const CONFIG_SIGNAL_RE = /mongo/i;
/** Central hot-table list (see .github/db-reviewer/README.md in the source repository). */
const HOT_TABLES_SOURCE = {
  owner: 'easi6dev',
  repo: 'tada-server-common-source',
  path: '.github/db-reviewer/hot-tables.json',
};
/** Allowed hot-table names; they are interpolated into regexes and the LLM prompt. */
const TABLE_NAME_RE = /^[a-z0-9_]+$/;
const ENTITY_NAME_RE = /^[A-Z][A-Za-z0-9]*$/;
/** Query-layer source files by Spring/JPA naming convention (matched against the basename). */
const QUERY_FILE_RE = /(Repository|Dao|Specification|QueryHelper|Mapper|Entity)[A-Za-z]*\.(kt|java)$/;
/** Test source sets are excluded from the hot-table query rule. */
const TEST_PATH_RE = /(^|\/)src\/(test|testFixtures|integrationTest)[^/]*\//;
/** Max number of changed files to inspect (bounds API calls on huge PRs). */
const MAX_FILES = 300;
/** Max characters of query-file diffs sent to the LLM; above this, the hot-table name match decides. */
const LLM_MAX_INPUT_CHARS = 100_000;
const LLM_DEFAULT_MODEL = 'global.openai.gpt-5.6-terra';
const LLM_MAX_TOKENS = 1024;
const LLM_TIMEOUT_MS = 60_000;
const LLM_RETRY_COUNT = 1;
const LLM_RETRY_DELAY_MS = 2_000;

// ---- Env -------------------------------------------------------------------

const {
  GITHUB_TOKEN,
  GITHUB_PULL_REQUEST_NUMBER,
  OWNER,
  REPO,
  HEAD_SHA,
  PR_AUTHOR,
  LITELLM_API_KEY,
  LITELLM_BASE_URL,
  LITELLM_MODEL,
  HOT_TABLES_TOKEN,
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
 * Whether a changed file belongs to the query layer, by Spring/JPA naming
 * convention. Only these files' diffs are sent to the LLM.
 *
 * @param {{filename:string}} file
 * @returns {boolean}
 */
const isQueryFile = (file) =>
  !TEST_PATH_RE.test(file.filename) && QUERY_FILE_RE.test(file.filename.split('/').pop());

/**
 * Parses and validates the central hot-table list.
 *
 * Names are validated strictly because they are interpolated into regexes
 * and the LLM prompt.
 *
 * @param {string} raw - Contents of hot-tables.json.
 * @returns {Array<{table:string,entity:string}>}
 * @throws when the JSON is malformed, empty, or has an invalid entry.
 */
const parseHotTables = (raw) => {
  const tables = JSON.parse(raw);
  if (!Array.isArray(tables) || tables.length === 0) throw new Error('hot table list must be a non-empty array');
  return tables.map((t, i) => {
    if (!TABLE_NAME_RE.test(t?.table ?? '') || !ENTITY_NAME_RE.test(t?.entity ?? '')) {
      throw new Error(`invalid hot table entry #${i}: ${JSON.stringify(t)}`);
    }
    return { table: t.table, entity: t.entity };
  });
};

/**
 * Reads the hot-table list from the central repository's default branch.
 *
 * `GITHUB_TOKEN` is scoped to the running repository and cannot read the
 * private central repository, so an org token (HOT_TABLES_TOKEN) is used.
 *
 * @returns {Promise<Array<{table:string,entity:string}>>}
 * @throws when the token is missing, the file cannot be read, or it is invalid.
 */
const loadHotTables = async () => {
  if (!HOT_TABLES_TOKEN) throw new Error('HOT_TABLES_TOKEN is not set');
  const { owner, repo, path } = HOT_TABLES_SOURCE;
  const res = await fetch(`${GH_API}/repos/${owner}/${repo}/contents/${path}`, {
    headers: {
      Accept: 'application/vnd.github.raw+json',
      Authorization: `Bearer ${HOT_TABLES_TOKEN}`,
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (!res.ok) throw new Error(`GET ${owner}/${repo}/${path} -> ${res.status}`);
  return parseHotTables(await res.text());
};

/**
 * Fallback used only when the LLM cannot decide: whether a query file names
 * a hot table.
 *
 * The full file content at HEAD is NOT consulted: nearly every file in a
 * service that owns a hot table imports its entity, so a content match would
 * flag everything. The whole hunk (context lines included) is matched
 * instead, because a multi-line `@Query("""...""")` or Criteria/QueryDSL edit
 * often changes only a middle line that does not itself name the entity. A
 * file named after the hot entity counts on its own, which also covers diffs
 * too large for GitHub to return a `patch`.
 *
 * The entity name is matched case-sensitively (so `rideEntity` locals do
 * not match) and the table name case-insensitively (SQL is often upper-case).
 *
 * @param {{filename:string,patch?:string}} file
 * @param {Array<{table:string,entity:string}>} hotTables
 * @returns {boolean}
 */
const mentionsHotTable = (file, hotTables) => {
  const basename = file.filename.split('/').pop();
  return hotTables.some(({ table, entity }) => {
    if (new RegExp(`^Q?${entity}(?![a-z])`).test(basename)) return true;
    if (!file.patch) return false;
    return new RegExp(`\\bQ?${entity}\\b`).test(file.patch) ||
      new RegExp(`\\b${table}\\b`, 'i').test(file.patch);
  });
};

// ---- LLM judgment ----------------------------------------------------------

/**
 * Builds the LLM system prompt for the given hot tables.
 *
 * @param {Array<{table:string,entity:string}>} hotTables
 * @returns {string}
 */
const buildSystemPrompt = (hotTables) => `You are a PostgreSQL performance reviewer for a ride-hailing backend built with Spring Boot, Spring Data JPA/Hibernate and PostgreSQL (queries are written with derived query methods, @Query JPQL/native SQL, Specifications, the Criteria API, QueryDSL, or JdbcTemplate; schema changes go through Liquibase).

The following tables are extremely hot (queried 100M+ times per day). Any change to the SQL issued against them can overload the database:
${hotTables.map(({ table, entity }) => `- table \`${table}\` (JPA entity \`${entity}\`)`).join('\n')}

You receive diff hunks of query-layer files (repositories, DAOs, specifications, query helpers, mappers, entities) from a pull request. Answer true only if BOTH hold:
1. The change can alter the SQL that is executed, or how often it runs. This INCLUDES, for example:
   - WHERE/JOIN/ORDER BY/GROUP BY/LIMIT/pagination changes, such as adding an OR branch or changing range bounds, including rewrites that are logically equivalent (e.g. \`lt(X)\` -> \`le(X) and ne(X)\`), since they can change the planner's row estimates and index choice
   - adding, removing, or renaming a query method, or switching which query method is called
   - entity mapping changes that change the shape of generated queries: relations, fetch type, entity graphs, @Where/@Filter/soft-delete conditions, inheritance
   - locking, batch/fetch size, projections
   It EXCLUDES changes that only add, remove, or rename plain columns (the query's conditions, joins, and plan stay the same), @Index/@Table DDL hints (the schema is managed by Liquibase), validation annotations, comments, formatting, logging, and code that does not build or run queries.
2. The affected SQL reads or writes a hot table listed above, directly or through a join/subquery, OR the change is in a shared query utility (e.g. SpecificationUtil, a query helper, a base repository) that queries on hot tables may use.

Queries that touch only other tables are false. If unsure whether a hot table is involved, answer true.

Respond with ONLY a JSON object: {"requiresReview": <true|false>, "reason": "<one short English sentence>"}`;

/**
 * Builds the user message for the LLM from query-layer files.
 *
 * @param {Array<{filename:string,patch?:string}>} queryFiles
 * @returns {string|null} The message, or null when it exceeds LLM_MAX_INPUT_CHARS.
 */
const buildLlmInput = (queryFiles) => {
  const input = queryFiles
    .map((file) => `### ${file.filename}\n${file.patch ? `\`\`\`diff\n${file.patch}\n\`\`\`` : '(diff not available: too large)'}`)
    .join('\n\n');
  return input.length > LLM_MAX_INPUT_CHARS ? null : input;
};

/**
 * Extracts the first balanced JSON object from text (the model may wrap it in prose or fences).
 *
 * @param {string} text
 * @returns {string|null}
 */
const extractFirstJsonObject = (text) => {
  const start = text.indexOf('{');
  if (start === -1) return null;
  let depth = 0;
  let inString = false;
  let escape = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch === '\\') {
      escape = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
};

/**
 * Parses the model's verdict.
 *
 * @param {string} content - Raw assistant message content.
 * @returns {{requiresReview:boolean,reason:string}|null} Null when malformed.
 */
const parseVerdict = (content) => {
  const jsonText = extractFirstJsonObject(content);
  if (!jsonText) return null;
  try {
    const parsed = JSON.parse(jsonText);
    if (typeof parsed.requiresReview !== 'boolean') return null;
    return { requiresReview: parsed.requiresReview, reason: String(parsed.reason ?? '') };
  } catch {
    return null;
  }
};

/**
 * Asks the LLM whether the query-file diffs change hot-table queries.
 *
 * @param {string} input - Output of buildLlmInput.
 * @param {Array<{table:string,entity:string}>} hotTables
 * @returns {Promise<{requiresReview:boolean,reason:string}>}
 * @throws when LiteLLM is not configured or every attempt fails; callers fall back to hot-table name matching.
 */
const judgeWithLlm = async (input, hotTables) => {
  if (!LITELLM_API_KEY || !LITELLM_BASE_URL) throw new Error('LiteLLM is not configured');
  if (!/^https:\/\//i.test(LITELLM_BASE_URL)) throw new Error('LITELLM_BASE_URL must use https://');
  const url = new URL('v1/chat/completions', LITELLM_BASE_URL.endsWith('/') ? LITELLM_BASE_URL : `${LITELLM_BASE_URL}/`);
  const body = JSON.stringify({
    model: LITELLM_MODEL || LLM_DEFAULT_MODEL,
    max_tokens: LLM_MAX_TOKENS,
    messages: [
      { role: 'system', content: buildSystemPrompt(hotTables) },
      { role: 'user', content: input },
    ],
  });

  let lastError;
  for (let attempt = 0; attempt <= LLM_RETRY_COUNT; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${LITELLM_API_KEY}`, 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(LLM_TIMEOUT_MS),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
      const content = (await res.json()).choices?.[0]?.message?.content ?? '';
      const verdict = parseVerdict(content);
      if (!verdict) throw new Error(`Unexpected response format: ${content.slice(0, 200)}`);
      return verdict;
    } catch (e) {
      lastError = e;
      if (attempt < LLM_RETRY_COUNT) await new Promise((r) => setTimeout(r, LLM_RETRY_DELAY_MS));
    }
  }
  throw lastError;
};

// ---- Review request --------------------------------------------------------

/**
 * Whether the DB owner is already (or was ever) engaged on the PR, so we
 * should not request again: currently a pending requested reviewer, has
 * already reviewed, or had a review request earlier that a human removed —
 * re-adding that one on the next `synchronize` would nag.
 *
 * @returns {Promise<boolean>}
 */
const reviewerAlreadyInvolved = async () => {
  const pr = await rest(`/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}`);
  if ((pr?.requested_reviewers || []).some((r) => r.login === DB_OWNER_LOGIN)) return true;

  const reviews = await rest(
    `/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/reviews?per_page=100`,
  );
  if (Array.isArray(reviews) && reviews.some((r) => r.user?.login === DB_OWNER_LOGIN)) return true;

  // The timeline keeps `review_requested` events even after the request was
  // fulfilled or removed; any earlier request means this PR was already routed.
  for (let page = 1; page <= 3; page++) {
    const events = await rest(
      `/repos/${OWNER}/${REPO}/issues/${GITHUB_PULL_REQUEST_NUMBER}/timeline?per_page=100&page=${page}`,
    );
    if (!Array.isArray(events) || events.length === 0) break;
    if (events.some((e) => e.event === 'review_requested' && e.requested_reviewer?.login === DB_OWNER_LOGIN)) {
      return true;
    }
    if (events.length < 100) break;
  }
  return false;
};

/**
 * Requests a review from the DB owner.
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
    body: JSON.stringify({ reviewers: [DB_OWNER_LOGIN] }),
  });
  if (res.ok) {
    console.info(`Requested review from ${DB_OWNER_LOGIN} -> ${res.status}`);
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
  if (PR_AUTHOR === DB_OWNER_LOGIN) {
    console.info(`PR author is ${DB_OWNER_LOGIN}; nothing to request.`);
    return;
  }

  const files = await listChangedFiles();
  if (files.length === 0) {
    console.info('No changed files found. Skipping.');
    return;
  }

  let mongoHit = null;
  for (const file of files) {
    if (await isMongoRelated(file)) {
      mongoHit = file.filename;
      break;
    }
  }
  const queryFiles = mongoHit ? [] : files.filter(isQueryFile);

  if (mongoHit) {
    console.info(`MongoDB-related change detected in "${mongoHit}".`);
  } else if (queryFiles.length > 0) {
    console.info(`Query-layer files changed: ${queryFiles.map((f) => f.filename).join(', ')}`);
  } else {
    console.info('No DB-related changes detected. Skipping.');
    return;
  }

  // Checked before the LLM call so later pushes to an already-routed PR cost no LLM call.
  if (await reviewerAlreadyInvolved()) {
    console.info(`${DB_OWNER_LOGIN} is already requested or has reviewed. Skipping.`);
    return;
  }

  if (!mongoHit) {
    let hotTables;
    try {
      hotTables = await loadHotTables();
    } catch (e) {
      // Fail the job so the broken central list is noticed instead of silently skipping every PR.
      console.error(`Cannot load the hot table list (${e.message}); skipping the hot-table query rule.`);
      process.exitCode = 1;
      return;
    }
    if (!(await queryChangeNeedsReview(queryFiles, hotTables))) return;
  }

  await requestReviewer();
}

/**
 * Decides whether query-layer changes need DB owner review: the LLM decides,
 * and when it cannot (oversized diff, missing config, failure), a hot-table
 * name match in the query files decides instead.
 *
 * @param {Array<{filename:string,patch?:string}>} queryFiles
 * @param {Array<{table:string,entity:string}>} hotTables
 * @returns {Promise<boolean>}
 */
async function queryChangeNeedsReview(queryFiles, hotTables) {
  const input = buildLlmInput(queryFiles);
  if (input == null) {
    console.info('Query-file diffs exceed the LLM input budget; falling back to hot-table name matching.');
  } else {
    try {
      const verdict = await judgeWithLlm(input, hotTables);
      console.info(`LLM verdict: requiresReview=${verdict.requiresReview} (${verdict.reason})`);
      return verdict.requiresReview;
    } catch (e) {
      console.warn(`LLM judgment failed (${e.message}); falling back to hot-table name matching.`);
    }
  }
  const hotHit = queryFiles.find((file) => mentionsHotTable(file, hotTables));
  console.info(hotHit ? `Hot table referenced in "${hotHit.filename}".` : 'No hot table referenced. Skipping.');
  return Boolean(hotHit);
}

module.exports = {
  isQueryFile,
  parseHotTables,
  mentionsHotTable,
  buildSystemPrompt,
  buildLlmInput,
  parseVerdict,
};

if (require.main === module) run();
