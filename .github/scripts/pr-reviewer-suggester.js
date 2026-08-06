/**
 * PR Reviewer Suggester
 * ---------------------------------------------------------------------------
 * Analyzes the lines a pull request changes and suggests reviewer candidates
 * based on who contributed most to that code. It combines two signals:
 *
 *   - blame: who last touched the exact changed lines (recency / ownership)
 *   - log  : who has historically committed to the changed files (breadth)
 *
 * The two signals are normalized and merged into a single score, and the top
 * candidates are posted as a single, non-mention comment on the PR. Random
 * auto-assignment additionally skips members whose Slack profile status marks
 * them as on vacation.
 *
 * GitHub login resolution is delegated to the GitHub API (GraphQL blame +
 * REST listCommits) so we never have to map raw git emails to accounts.
 *
 * No external npm dependencies (mirrors pr-jira-bot.js). Requires Node 18+
 * for global `fetch`, and a full-history checkout (fetch-depth: 0).
 */

'use strict';

const { execFileSync } = require('node:child_process');

// ---- Tunables --------------------------------------------------------------

/** Weight of the blame signal in the final score. */
const BLAME_WEIGHT = 0.6;
/** Weight of the file-history (log) signal in the final score. */
const LOG_WEIGHT = 0.4;
/** Half-life (days) for recency decay applied to historical commits. */
const LOG_HALF_LIFE_DAYS = 90;
/** Pure additions have no blamed line; attribute them to the anchor line at a discount. */
const ADDITION_WEIGHT = 0.3;
/** Max number of changed files to analyze (bounds API calls on huge PRs). */
const MAX_FILES = 50;
/** Max number of score-based reviewer candidates to suggest. */
const TOP_N = 2;
/** Number of additional reviewers drawn at random from the server team. */
const RANDOM_N = 2;
/** Hidden marker so re-runs update the same comment instead of duplicating. */
const COMMENT_MARKER = '<!-- reviewer-suggester -->';

/** Org team whose members are eligible reviewers (both the contribution filter and the random pool). */
const TEAM_ORG = 'easi6dev';
const TEAM_SLUG = 'tada-backend-infra';
/** Repository that receives the periodic `[server] PR Stats Report` PRs. */
const STATS_OWNER = 'easi6dev';
const STATS_REPO = 'tada-pr-stats-report';
/** Title prefix identifying the server-team stats report PRs. */
const STATS_PR_TITLE = '[server] PR Stats Report';

/** Files that add noise rather than signal (generated / vendored / owned elsewhere). */
const SKIP_FILE_PATTERNS = [
  /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$/,
  /\.pb\.[a-z]+$/, // generated protobuf stubs
  /(^|\/)(build|dist|node_modules|generated)\//,
  /\.(png|jpe?g|gif|svg|ico|pdf|jar|zip|woff2?|ttf)$/,
];

/** GitHub accounts that should never be suggested as reviewers. */
const BOT_LOGINS = new Set(['dependabot', 'github-actions', 'web-flow']);

/** Team members to keep out of the random auto-assignment (e.g. opted out / on leave). */
const RANDOM_EXCLUDE_LOGINS = new Set(['jaden-ju']);

// ---- Slack vacation filter ---------------------------------------------------

const SLACK_API = 'https://slack.com/api';

/** Slack profile status that marks a member as on vacation (matching emoji OR text suffices). */
const VACATION_STATUS_EMOJI = ':palm_tree:';
const VACATION_STATUS_TEXTS = [/vacationing/i, /out sick \(vacation\)/i];

/**
 * GitHub login -> Slack user ID, used to look up each member's Slack profile
 * status. Members missing from this map are never vacation-filtered (they stay
 * in the random pool), so keep it in sync with the team roster.
 */
const GITHUB_TO_SLACK_IDS = {
  'spica': 'U02UUEFRE', // MK
  'yyhpys': 'UQR00S0DA', // Luka
  'parkmk': 'U0B6KQ29Q3F', // Revin
  'RappingWolf': 'U03AUU3NPU1', // Dean
  'fred16157': 'U02D92R4BV5', // Fred
  'WannyWanny': 'U071R3QKL8Y', // Wanny
  'pyjun01': 'U016QCCLVS4', // Justin
  'yvsc5020': 'U05PH4Y1U6P', // Van
  'wleo04': 'U06CKF35Y3U', // Chester
  'gwongibeom': 'U07KGQF9QJC', // Samuel
  'taegeunlee': 'UPKSTFK3N', // Kenny
  'kachosohrab': 'U08VAJQGJTT', // Kacho Sohrab
  'LudyPark': 'U0669GT2R4Y', // Ludy
  'vivekshinde45': 'U098Q7DJSMB', // Vivek
  '1O16': 'U0AUYA1AGB1', // Brad
  'charliemvl': 'U072XJVKUU8', // Charlie
  'jaden-ju': 'U07U97BU3U3', // Jaden
  'mvloliver': 'U0925BMFR1V', // Oliver
  'shawarma-and-debug': 'U0941ES9B41', // Shubham
  'vibincv': 'U09AJL59ZGQ', // Vibin
  'denisjoo': 'U09BBTHFGGH', // Denis
  'ibrahim-sid07': 'U09Q82LGS4V', // Ibrahim
  'rohitc-1998': 'U09QF45F5GU', // Rohit
  'rakhee-pl': 'U09RY80U128', // Rakhee
  'k-suresh-mvl': 'U0B1HQLDNH2', // Suresh
  'swadhin-maker': 'U0B2JFW2960', // Swadhin
  'keerthanvp-sketch': 'U0B5G272S4X', // Keerthan
};

// ---- Env -------------------------------------------------------------------

const {
  GITHUB_TOKEN,
  GITHUB_PULL_REQUEST_NUMBER,
  BASE_SHA,
  HEAD_SHA,
  PR_AUTHOR,
  OWNER,
  REPO,
  // Broader-scoped token (read:org + cross-repo read) for the org team API and
  // the separate stats-report repository. Falls back to GITHUB_TOKEN.
  ORG_GITHUB_ACTION_CI_TOKEN,
  // Slack bot token with `users:read` scope, used for the vacation filter.
  SLACK_BOT_TOKEN,
} = process.env;

/** Token used for org/cross-repo reads; the default GITHUB_TOKEN cannot see them. */
const ORG_TOKEN = ORG_GITHUB_ACTION_CI_TOKEN || GITHUB_TOKEN;

const GH_API = 'https://api.github.com';
const GH_GRAPHQL = 'https://api.github.com/graphql';

// ---- Git helpers -----------------------------------------------------------

/**
 * Runs a git command and returns its stdout as a trimmed string.
 *
 * @param {string[]} args - Arguments passed to `git`.
 * @returns {string} The command's stdout.
 */
const git = (args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trim();

/**
 * Resolves the true merge base of the PR so that we diff/blame against the
 * point the branch actually diverged (three-dot semantics).
 *
 * @returns {string} The merge-base commit SHA (falls back to BASE_SHA).
 */
const resolveMergeBase = () => {
  try {
    return git(['merge-base', BASE_SHA, HEAD_SHA]);
  } catch {
    return BASE_SHA;
  }
};

/**
 * Parses the unified diff into a per-file map of changed old-side line weights.
 * Modified/deleted lines (which exist in the base) get full weight and are
 * blameable. Pure additions get a discounted weight on their anchor line.
 *
 * @param {string} base - Base commit to diff from.
 * @param {string} head - Head commit to diff to.
 * @returns {Map<string, Map<number, number>>} file -> (oldLineNumber -> weight)
 */
const collectChangedLineWeights = (base, head) => {
  const raw = git(['diff', '--unified=0', '--no-color', '--diff-filter=d', `${base}..${head}`]);
  const perFile = new Map();

  let current = null; // weight map for the file currently being parsed
  for (const line of raw.split('\n')) {
    const fileMatch = /^\+\+\+ b\/(.+)$/.exec(line);
    if (fileMatch) {
      const path = fileMatch[1];
      if (shouldSkipFile(path)) {
        current = null;
        continue;
      }
      current = new Map();
      perFile.set(path, current);
      continue;
    }
    if (!current) continue;

    // @@ -oldStart[,oldCount] +newStart[,newCount] @@
    const hunk = /^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(line);
    if (!hunk) continue;

    const oldStart = Number(hunk[1]);
    const oldCount = hunk[2] === undefined ? 1 : Number(hunk[2]);
    const newCount = hunk[3] === undefined ? 1 : Number(hunk[3]);

    if (oldCount > 0) {
      // Lines that existed in base were modified/deleted -> blame them directly.
      for (let l = oldStart; l < oldStart + oldCount; l++) {
        current.set(l, (current.get(l) || 0) + 1);
      }
    } else if (oldStart >= 1) {
      // Pure insertion: attribute to the surrounding context line at a discount.
      const w = newCount * ADDITION_WEIGHT;
      current.set(oldStart, (current.get(oldStart) || 0) + w);
    }
  }

  return perFile;
};

/**
 * @param {string} path - Repository-relative file path.
 * @returns {boolean} True if the file should be excluded from analysis.
 */
const shouldSkipFile = (path) => SKIP_FILE_PATTERNS.some((re) => re.test(path));

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
        Accept: 'application/vnd.github.v3+json',
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
    if (!res.ok) {
      console.warn(`REST ${path} -> ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (e) {
    console.warn(`REST ${path} failed: ${e.message}`);
    return null;
  }
};

/**
 * Calls the GitHub GraphQL API.
 *
 * @param {string} query - GraphQL query string.
 * @param {Object} variables - Query variables.
 * @returns {Promise<any>} `data` field of the response, or null on error.
 */
const graphql = async (query, variables) => {
  try {
    const res = await fetch(GH_GRAPHQL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query, variables }),
    });
    const body = await res.json();
    if (body.errors) {
      console.warn(`GraphQL errors: ${JSON.stringify(body.errors)}`);
    }
    return body.data || null;
  } catch (e) {
    console.warn(`GraphQL failed: ${e.message}`);
    return null;
  }
};

const BLAME_QUERY = `
query($owner:String!,$repo:String!,$oid:GitObjectID!,$path:String!){
  repository(owner:$owner,name:$repo){
    object(oid:$oid){
      ... on Commit {
        blame(path:$path){
          ranges{
            startingLine
            endingLine
            commit{ author{ user{ login } } }
          }
        }
      }
    }
  }
}`;

/**
 * Accumulates blame-based scores for one file by intersecting the file's blame
 * ranges (at the base commit) with the PR's changed old-side lines.
 *
 * @param {string} path - File path.
 * @param {string} oid - Base commit SHA to blame against.
 * @param {Map<number, number>} lineWeights - oldLineNumber -> weight.
 * @param {Map<string, number>} acc - login -> accumulated blame score (mutated).
 */
const accumulateBlame = async (path, oid, lineWeights, acc) => {
  const data = await graphql(BLAME_QUERY, { owner: OWNER, repo: REPO, oid, path });
  const ranges = data?.repository?.object?.blame?.ranges;
  if (!ranges) return;

  for (const [oldLine, weight] of lineWeights) {
    const range = ranges.find((r) => oldLine >= r.startingLine && oldLine <= r.endingLine);
    const login = range?.commit?.author?.user?.login;
    if (login) acc.set(login, (acc.get(login) || 0) + weight);
  }
};

/**
 * Accumulates file-history scores for one file using recency-decayed commit
 * counts from the base commit backwards.
 *
 * @param {string} path - File path.
 * @param {string} sha - Base commit SHA (history endpoint).
 * @param {number} now - Reference timestamp (ms) for decay.
 * @param {Map<string, number>} acc - login -> accumulated log score (mutated).
 */
const accumulateLog = async (path, sha, now, acc) => {
  const commits = await rest(`/repos/${OWNER}/${REPO}/commits?path=${encodeURIComponent(path)}&sha=${sha}&per_page=100`);
  if (!Array.isArray(commits)) return;

  for (const c of commits) {
    const login = c?.author?.login;
    const dateStr = c?.commit?.author?.date;
    if (!login || !dateStr) continue;
    const ageDays = (now - new Date(dateStr).getTime()) / 86_400_000;
    const weight = Math.pow(0.5, ageDays / LOG_HALF_LIFE_DAYS);
    acc.set(login, (acc.get(login) || 0) + weight);
  }
};

// ---- Scoring & comment -----------------------------------------------------

/**
 * @param {string} login - GitHub login to test.
 * @returns {boolean} True if the login should be excluded from suggestions.
 */
const isExcluded = (login) =>
  login === PR_AUTHOR || login.endsWith('[bot]') || BOT_LOGINS.has(login);

/**
 * Merges blame and log signals into a single normalized, ranked candidate list,
 * restricted to current team members.
 *
 * @param {Map<string, number>} blame - login -> blame score.
 * @param {Map<string, number>} log - login -> log score.
 * @param {Set<string>} teamMembers - Current team logins; an empty set disables the membership filter.
 * @returns {Array<{login:string,score:number,blame:number,log:number}>}
 */
const rankCandidates = (blame, log, teamMembers) => {
  // Only suggest current team members so ex-teammates who still appear in blame /
  // history are dropped. When the roster is unavailable (empty set) we keep every
  // candidate rather than suppress the whole feature.
  const onTeam = (login) => teamMembers.size === 0 || teamMembers.has(login);
  const logins = new Set(
    [...blame.keys(), ...log.keys()].filter((l) => !isExcluded(l) && onTeam(l)),
  );
  const blameMax = Math.max(0, ...blame.values());
  const logMax = Math.max(0, ...log.values());

  return [...logins]
    .map((login) => {
      const b = blame.get(login) || 0;
      const l = log.get(login) || 0;
      const norm = (BLAME_WEIGHT * (blameMax ? b / blameMax : 0)) + (LOG_WEIGHT * (logMax ? l / logMax : 0));
      return { login, score: norm, blame: b, log: l };
    })
    .filter((c) => c.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, TOP_N);
};

/**
 * Calls a fully-qualified GitHub REST URL with the given token.
 *
 * @param {string} url - Absolute API URL.
 * @param {string} token - Bearer token to authorize with.
 * @returns {Promise<any>} Parsed JSON body, or null on error.
 */
const apiJson = async (url, token) => {
  try {
    const res = await fetch(url, {
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
    if (!res.ok) {
      console.warn(`GET ${url} -> ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (e) {
    console.warn(`GET ${url} failed: ${e.message}`);
    return null;
  }
};

/**
 * Fetches the current team roster: every member of the org team. This roster
 * is both the contribution-candidate filter and the random-pick pool. Requires
 * a token with `read:org` scope.
 *
 * @returns {Promise<string[]>} Member logins (empty on failure).
 */
const fetchTeamMembers = async () => {
  const logins = [];
  for (let page = 1; page <= 5; page++) {
    const url = `${GH_API}/orgs/${TEAM_ORG}/teams/${TEAM_SLUG}/members?per_page=100&page=${page}`;
    const members = await apiJson(url, ORG_TOKEN);
    if (!Array.isArray(members) || members.length === 0) break;
    for (const m of members) if (m?.login) logins.push(m.login);
    if (members.length < 100) break;
  }
  return logins;
};

/**
 * Parses the stats markdown table into login -> total-reviews. Column positions
 * are resolved from the header row so the parser survives column reordering.
 *
 * @param {string} markdown - Comment body containing the stats table.
 * @returns {Map<string, number>} login -> total reviews over the report window.
 */
const parseReviewTable = (markdown) => {
  const counts = new Map();
  const rows = markdown.split('\n').filter((l) => l.trim().startsWith('|'));
  if (rows.length < 3) return counts; // header + separator + at least one row

  const cells = (row) => row.split('|').slice(1, -1).map((c) => c.trim());
  const header = cells(rows[0]).map((h) => h.toLowerCase());
  const reviewsCol = header.findIndex((h) => h.includes('total reviews'));
  if (reviewsCol === -1) return counts;

  // rows[1] is the |---|---| separator; data rows start at rows[2].
  for (const row of rows.slice(2)) {
    const login = /github\.com\/([A-Za-z0-9-]+)/.exec(row)?.[1];
    const reviews = Number(/(\d+)/.exec(cells(row)[reviewsCol] || '')?.[1] || 0);
    if (login) counts.set(login, reviews);
  }
  return counts;
};

/**
 * Finds the latest `[server] PR Stats Report` PR and parses its first comment
 * (where the stats table lives) into a per-login review-count map. Returns an
 * empty map if the report is unavailable — callers then fall back to uniform.
 *
 * @returns {Promise<Map<string, number>>} login -> recent total reviews.
 */
const fetchReviewCounts = async () => {
  const empty = new Map();

  // Locate the most recent server report PR by title. The pulls endpoint draws
  // from the generous core rate limit and is immediately consistent (no Search
  // indexing lag). Reports land in 4 platform variants/day, so the latest
  // `[server]` one is always within the newest page; client-side title filter.
  const url = `${GH_API}/repos/${STATS_OWNER}/${STATS_REPO}/pulls?state=all&sort=created&direction=desc&per_page=20`;
  const prs = await apiJson(url, ORG_TOKEN);
  const pr = Array.isArray(prs) ? prs.find((p) => p.title?.startsWith(STATS_PR_TITLE)) : null;
  if (!pr) {
    console.warn('No server PR Stats Report found; random picks will be uniform.');
    return empty;
  }

  // The stats table is posted as the first issue comment on the report PR.
  const comments = await apiJson(
    `${GH_API}/repos/${STATS_OWNER}/${STATS_REPO}/issues/${pr.number}/comments?per_page=10`,
    ORG_TOKEN,
  );
  const body = Array.isArray(comments) ? comments[0]?.body : null;
  if (!body) {
    console.warn(`Report PR #${pr.number} has no parsable comment; random picks will be uniform.`);
    return empty;
  }
  return parseReviewTable(body);
};

/**
 * Weighted-random sampling (without replacement) of `n` logins. Each item's
 * weight is its relative chance of being drawn.
 *
 * @param {Array<{login:string, weight:number}>} items - Candidates with weights.
 * @param {number} n - How many to draw.
 * @returns {string[]} Selected logins (fewer than n if the pool is smaller).
 */
const weightedSample = (items, n) => {
  const pool = items.slice();
  const picks = [];
  for (let i = 0; i < Math.min(n, pool.length); i++) {
    const total = pool.reduce((sum, it) => sum + it.weight, 0);
    let r = Math.random() * total;
    let idx = 0;
    while (idx < pool.length - 1 && (r -= pool[idx].weight) > 0) idx++;
    picks.push(pool[idx].login);
    pool.splice(idx, 1); // sampling without replacement
  }
  return picks;
};

/**
 * Fetches the logins already requested as reviewers on the PR so re-runs (e.g.
 * a draft toggled back to ready) don't re-assign and accumulate the same people.
 *
 * @returns {Promise<string[]>} Currently-requested reviewer logins (empty on failure).
 */
const fetchRequestedReviewers = async () => {
  const data = await rest(`/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/requested_reviewers`);
  const users = data?.users;
  return Array.isArray(users) ? users.map((u) => u?.login).filter(Boolean) : [];
};

/**
 * @param {string|undefined} emoji - Slack profile status emoji (e.g. ':palm_tree:').
 * @param {string|undefined} text - Slack profile status text.
 * @returns {boolean} True if the status marks the member as on vacation.
 */
const isVacationStatus = (emoji, text) =>
  emoji === VACATION_STATUS_EMOJI || VACATION_STATUS_TEXTS.some((re) => re.test(text || ''));

/**
 * Checks each login's Slack profile status and returns those currently on
 * vacation. Fails open: a missing token, an unmapped login, or any Slack API
 * problem leaves the member in the pool rather than blocking assignment.
 *
 * @param {string[]} logins - GitHub logins to check.
 * @returns {Promise<Set<string>>} Logins currently on vacation.
 */
const fetchVacationingLogins = async (logins) => {
  const vacationing = new Set();
  if (!SLACK_BOT_TOKEN) {
    console.warn('SLACK_BOT_TOKEN not set; skipping the vacation filter.');
    return vacationing;
  }

  for (const login of logins) {
    const slackId = GITHUB_TO_SLACK_IDS[login];
    if (!slackId) {
      console.warn(`No Slack mapping for ${login}; vacation status not checked.`);
      continue;
    }
    try {
      const res = await fetch(`${SLACK_API}/users.info?user=${encodeURIComponent(slackId)}`, {
        headers: { Authorization: `Bearer ${SLACK_BOT_TOKEN}` },
      });
      const body = await res.json();
      if (!body.ok) {
        console.warn(`Slack users.info(${login}=${slackId}) -> ${body.error}`);
        // Token-level errors will fail every remaining call too; stop probing.
        if (['not_authed', 'invalid_auth', 'account_inactive', 'token_revoked', 'missing_scope'].includes(body.error)) {
          break;
        }
        continue;
      }
      const profile = body.user?.profile || {};
      if (isVacationStatus(profile.status_emoji, profile.status_text)) {
        vacationing.add(login);
      }
    } catch (e) {
      console.warn(`Slack users.info(${login}) failed: ${e.message}`);
    }
  }
  return vacationing;
};

/**
 * Picks N reviewers from the org team, biased toward those with the fewest
 * recent reviews to balance review load. Team members absent from the stats
 * report are treated as 0 reviews and are therefore the most likely to be
 * drawn. Excludes the PR author, the score-based picks, anyone already
 * requested as a reviewer, and members whose Slack status says they are on
 * vacation. If the stats report is unavailable, weights collapse to uniform.
 *
 * @param {Array<{login:string}>} chosen - Already-selected score-based candidates.
 * @param {number} n - How many random reviewers to draw.
 * @param {Set<string>} teamMembers - Current team logins (the candidate pool).
 * @returns {Promise<string[]>} Randomly selected logins.
 */
const pickRandomReviewers = async (chosen, n, teamMembers) => {
  if (teamMembers.size === 0) {
    console.warn('Could not fetch team members; skipping random picks.');
    return [];
  }

  const alreadyRequested = await fetchRequestedReviewers();
  const taken = new Set([
    ...chosen.map((c) => c.login),
    ...alreadyRequested,
    ...RANDOM_EXCLUDE_LOGINS,
    ...(PR_AUTHOR ? [PR_AUTHOR] : []),
  ]);
  const eligible = [...teamMembers].filter((login) => !taken.has(login) && !isExcluded(login));
  if (eligible.length === 0) return [];

  // Vacation status is only looked up for the actual pool to bound Slack calls.
  const onVacation = await fetchVacationingLogins(eligible);
  if (onVacation.size > 0) {
    console.info(`On vacation, excluded from random picks: ${[...onVacation].join(', ')}`);
  }
  const available = eligible.filter((login) => !onVacation.has(login));
  if (available.length === 0) return [];

  const reviews = await fetchReviewCounts();
  // Inverse weight: fewer reviews -> higher chance. 0 reviews (including members
  // with no recent activity, who are absent from the report) get the maximum
  // weight of 1. With no report data every weight is 1 -> uniform random.
  const weighted = available.map((login) => ({ login, weight: 1 / ((reviews.get(login) || 0) + 1) }));
  return weightedSample(weighted, n);
};

/**
 * Renders the PR comment body. Score-based candidates are wrapped in backticks
 * so they read as plain text and do NOT ping anyone (reference only). The
 * auto-assigned reviewers are @-mentioned so they get a direct notification.
 *
 * @param {Array<{login:string,score:number,blame:number,log:number}>} candidates
 * @param {string[]} randomPicks - Reviewers auto-assigned (requested) from the server team.
 * @returns {string} Markdown comment body.
 */
const renderComment = (candidates, randomPicks) => {
  const lines = [
    '## 🧐 Suggested Reviewers',
    'Based on contribution analysis of the changed code (for reference only, not mandatory).',
    '',
  ];

  if (candidates.length > 0) {
    const rows = candidates
      .map((c) => {
        const reasons = [];
        if (c.blame > 0) reasons.push(`changed-line contribution ${c.blame.toFixed(1)}`);
        if (c.log > 0) reasons.push(`file-history contribution ${c.log.toFixed(1)}`);
        return `| \`${c.login}\` | ${c.score.toFixed(2)} | ${reasons.join(', ')} |`;
      })
      .join('\n');

    lines.push(
      '### By contribution score',
      '',
      '| Candidate | Score | Rationale |',
      '| --- | --- | --- |',
      rows,
      '',
    );
  }

  if (randomPicks.length > 0) {
    lines.push(
      '### Auto-assigned from the server team',
      '_Automatically requested as reviewers, biased toward members with fewer recent reviews to balance review load._',
      '',
      randomPicks.map((login) => `@${login}`).join(', '),
      '',
    );
  }

  lines.push(COMMENT_MARKER);
  return lines.join('\n');
};

/**
 * Creates the suggestion comment, or updates the existing one if a previous
 * run already posted (keeps the PR free of duplicates on re-runs).
 *
 * @param {string} body - Comment body.
 */
const upsertComment = async (body) => {
  const issue = `/repos/${OWNER}/${REPO}/issues/${GITHUB_PULL_REQUEST_NUMBER}`;
  const existing = await rest(`${issue}/comments?per_page=100`);
  const prev = Array.isArray(existing) && existing.find((c) => c.body?.includes(COMMENT_MARKER));

  const url = prev ? `${GH_API}/repos/${OWNER}/${REPO}/issues/comments/${prev.id}` : `${GH_API}${issue}/comments`;
  const res = await fetch(url, {
    method: prev ? 'PATCH' : 'POST',
    headers: {
      Accept: 'application/vnd.github.v3+json',
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: JSON.stringify({ body }),
  });
  console.info(`Comment ${prev ? 'updated' : 'created'} -> ${res.status}`);
};

/**
 * Assigns the given logins as real review requests on the PR (they show up in
 * the Reviewers panel and notify the users), not just a comment mention. A
 * single un-assignable login makes the whole request 422, so failures are
 * logged and swallowed rather than aborting the run.
 *
 * @param {string[]} logins - Reviewer logins to request.
 */
const requestReviewers = async (logins) => {
  if (logins.length === 0) return;
  const url = `${GH_API}/repos/${OWNER}/${REPO}/pulls/${GITHUB_PULL_REQUEST_NUMBER}/requested_reviewers`;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Accept: 'application/vnd.github.v3+json',
        Authorization: `Bearer ${GITHUB_TOKEN}`,
        'Content-Type': 'application/json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      body: JSON.stringify({ reviewers: logins }),
    });
    if (!res.ok) {
      console.warn(`Request reviewers -> ${res.status}: ${await res.text()}`);
      return;
    }
    console.info(`Requested reviewers: ${logins.join(', ')}`);
  } catch (e) {
    console.warn(`Request reviewers failed: ${e.message}`);
  }
};

// ---- Main ------------------------------------------------------------------

/**
 * Orchestrates the full pipeline: diff -> blame + log -> rank -> assign + comment.
 */
async function run() {
  if (!GITHUB_TOKEN || !GITHUB_PULL_REQUEST_NUMBER || !BASE_SHA || !HEAD_SHA) {
    console.error('Missing required environment variables. Aborting.');
    return;
  }

  const base = resolveMergeBase();
  console.info(`Analyzing ${base.slice(0, 8)}..${HEAD_SHA.slice(0, 8)}`);

  const perFile = collectChangedLineWeights(base, HEAD_SHA);
  const files = [...perFile.keys()].slice(0, MAX_FILES);
  if (files.length === 0) {
    console.info('No analyzable files changed. Skipping.');
    return;
  }
  if (perFile.size > MAX_FILES) {
    console.info(`Diff touches ${perFile.size} files; analyzing the first ${MAX_FILES}.`);
  }

  const blameScores = new Map();
  const logScores = new Map();
  const now = Date.now();

  for (const path of files) {
    await accumulateBlame(path, base, perFile.get(path), blameScores);
    await accumulateLog(path, base, now, logScores);
  }

  // Fetch the team roster once: it both filters the contribution candidates
  // (so ex-teammates no longer surface) and serves as the random-pick pool.
  const teamMembers = new Set(await fetchTeamMembers());
  if (teamMembers.size === 0) {
    console.warn('Team roster unavailable; contribution candidates are not membership-filtered and random picks are skipped.');
  }

  const candidates = rankCandidates(blameScores, logScores, teamMembers);
  const randomPicks = await pickRandomReviewers(candidates, RANDOM_N, teamMembers);

  if (candidates.length === 0 && randomPicks.length === 0) {
    console.info('No reviewer candidates found. Skipping comment.');
    return;
  }

  console.info(`Top candidates: ${candidates.map((c) => `${c.login}(${c.score.toFixed(2)})`).join(', ') || '(none)'}`);
  console.info(`Random picks: ${randomPicks.join(', ') || '(none)'}`);
  // Force-assign the random picks as real reviewers; the score-based candidates
  // stay comment-only suggestions.
  await requestReviewers(randomPicks);
  await upsertComment(renderComment(candidates, randomPicks));
}

run();
