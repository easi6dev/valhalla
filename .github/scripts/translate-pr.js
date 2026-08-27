// Translates PR content (body, comments, review comments, review bodies)
// bidirectionally via LiteLLM (Claude). Designed to run inside
// actions/github-script@v7, which provides `github`, `context`, `core`.
//
// Marker state machine for any PR-attached content (body/comment/review):
//
//   [no marker]            → translate, write TRANSLATING marker, then write
//                            TRANSLATED block + TRANSLATED marker
//   [TRANSLATED marker]    → skip (already translated). To force re-
//                            translation, manually delete the
//                            <!-- translated-by-claude --> marker
//                            (the bot will pick it up on next event).
//   [TRANSLATING marker]   → leftover from a cancelled run; gets cleaned up
//                            and retried automatically on next event
//
// On translation failure: the original body is restored and the failure
// is logged via core.warning + core.summary (NOT written to the PR body).
//
// Required env: LITELLM_API_KEY, LITELLM_BASE_URL
// Optional env: LITELLM_MODEL

const fs = require("fs");
const https = require("https");
const path = require("path");

const CONFIG = {
  TIMEOUT_MS: 90000,
  MAX_TOKENS: 8192,
  MAX_INPUT_CHARS: 16000,
  RETRY_COUNT: 1,
  RETRY_DELAY_MS: 2000,
  PER_PAGE: 100,
  DEFAULT_MODEL: "claude-haiku-4-5-20251001",
};

const MARKERS = {
  TRANSLATED: "<!-- translated-by-claude -->",
  TRANSLATING: "<!-- translation-in-progress -->",
};

// Logins excluded from translation entirely (checked by prefix, since the
// default GITHUB_TOKEN posts as "github-actions[bot]").
const EXCLUDED_AUTHOR_PREFIXES = ["github-actions"];

function isExcludedAuthor(login) {
  if (!login) return false;
  return EXCLUDED_AUTHOR_PREFIXES.some((prefix) => login.startsWith(prefix));
}

const TRANSLATING_LABEL = `\n\n🔴 **Translating...**\n${MARKERS.TRANSLATING}`;

const TRANSLATION_DETAILS_OPEN = '<details data-tada-translation="true">';

const SYSTEM_PROMPT = fs.readFileSync(
  path.join(__dirname, "..", "prompts", "translate_pr_role.md"),
  "utf-8",
);

// --- URL builder with protocol & path-preserving normalization ---
function buildLiteLlmUrl(base) {
  if (!base) {
    throw new Error("LITELLM_BASE_URL is not set");
  }
  if (!/^https:\/\//i.test(base)) {
    throw new Error(
      `LITELLM_BASE_URL must use https:// (got: ${base.replace(/\/\/.*$/, "//[redacted]")})`,
    );
  }
  const normalized = base.endsWith("/") ? base : base + "/";
  return new URL("v1/chat/completions", normalized);
}

// --- First balanced JSON object extractor (avoids greedy regex pitfalls) ---
function extractFirstJsonObject(text) {
  const start = text.indexOf("{");
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
    if (ch === "\\") {
      escape = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

// --- HTTP helper with timeout ---
function httpRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => {
        clearTimeout(timer);
        try {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(JSON.parse(data));
          } else {
            reject(new Error(`HTTP ${res.statusCode}: ${data}`));
          }
        } catch (e) {
          reject(new Error(`Failed to parse response: ${e.message}`));
        }
      });
    });

    const timer = setTimeout(() => {
      req.destroy();
      reject(new Error(`Request timed out after ${CONFIG.TIMEOUT_MS}ms`));
    }, CONFIG.TIMEOUT_MS);

    req.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    if (body) req.write(body);
    req.end();
  });
}

// --- Generic retry wrapper ---
//
// Callers decide what `fn` covers. In `translateText` below, it wraps the
// LLM call plus response validation and JSON parsing — NOT the surrounding
// input-length check, which is a deterministic failure that would fail
// identically on retry and just waste an LLM call + delay.
async function withRetry(fn) {
  let lastError;
  for (let attempt = 0; attempt <= CONFIG.RETRY_COUNT; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastError = e;
      if (attempt < CONFIG.RETRY_COUNT) {
        await new Promise((r) => setTimeout(r, CONFIG.RETRY_DELAY_MS));
      }
    }
  }
  throw lastError;
}

// --- Translation helper ---
async function translateText(text) {
  // Input length check is OUTSIDE retry — no point retrying with the same
  // (oversized) input.
  if (text.length > CONFIG.MAX_INPUT_CHARS) {
    throw new Error(
      `Input too long for translation (${text.length} > ${CONFIG.MAX_INPUT_CHARS} chars)`,
    );
  }

  const url = buildLiteLlmUrl(process.env.LITELLM_BASE_URL);
  const model = process.env.LITELLM_MODEL || CONFIG.DEFAULT_MODEL;

  const llmBody = JSON.stringify({
    model,
    max_tokens: CONFIG.MAX_TOKENS,
    messages: [
      {
        role: "system",
        content: SYSTEM_PROMPT,
      },
      {
        role: "user",
        content: `<user_text>\n${text}\n</user_text>`,
      },
    ],
  });

  // Retry around the entire LLM call + response validation + JSON parse.
  // The LLM is non-deterministic, so transient invalid-JSON / unexpected-
  // format failures often succeed on a second try. The cost of a redundant
  // retry on truly deterministic failures (max_tokens=length, empty
  // translation) is one extra LLM call + 2s, acceptable.
  return withRetry(async () => {
    const llmResult = await httpRequest(
      {
        hostname: url.hostname,
        port: url.port || 443,
        path: url.pathname,
        method: "POST",
        headers: {
          Authorization: `Bearer ${process.env.LITELLM_API_KEY}`,
          "content-type": "application/json",
        },
      },
      llmBody,
    );

    const choice = llmResult.choices && llmResult.choices[0];
    if (!choice) {
      throw new Error("LLM response missing choices");
    }
    if (choice.finish_reason === "length") {
      throw new Error("LLM response truncated (max_tokens reached)");
    }
    const content = ((choice.message && choice.message.content) || "").trim();
    const jsonText = extractFirstJsonObject(content);
    if (!jsonText) {
      throw new Error(`Unexpected response format: ${content.slice(0, 200)}`);
    }
    const parsed = JSON.parse(jsonText);
    if (!parsed.translation || !parsed.translation.trim()) {
      throw new Error("empty translation");
    }
    return parsed;
  });
}

// --- Body builders ---
function buildTranslatingBody(original) {
  return `${original}${TRANSLATING_LABEL}`;
}

function buildTranslatedBody(original, result) {
  const isEnglish =
    result.language && result.language.toLowerCase() === "english";
  if (isEnglish) {
    return `${original}\n\n${TRANSLATION_DETAILS_OPEN}\n<summary>Korean</summary>\n\n${result.translation}\n\n</details>\n${MARKERS.TRANSLATED}`;
  }
  return `${MARKERS.TRANSLATED}\n${result.translation}\n\n${TRANSLATION_DETAILS_OPEN}\n<summary>${result.language}</summary>\n\n${original}\n\n</details>`;
}

// --- Strip helpers ---
function stripArtifacts(body) {
  if (!body) return body;
  // Strip in-progress label & markers, plus the bot-authored translation
  // <details> block (anchored on the data-tada-translation sentinel so
  // user-authored <details> blocks are preserved).
  return body
    .replace(/\n*🔴 \*\*Translating\.\.\.\*\*/g, "")
    .replace(new RegExp(MARKERS.TRANSLATING, "g"), "")
    .replace(new RegExp(MARKERS.TRANSLATED, "g"), "")
    .replace(
      /\n*<details data-tada-translation="true">[\s\S]*?<\/details>\n*/g,
      "",
    )
    .trim();
}

function needsTranslation(body) {
  if (!body) return false;
  // Already translated → skip. To force re-translation, manually delete
  // the TRANSLATED marker (the bot picks it up on the next event).
  if (body.includes(MARKERS.TRANSLATED)) return false;
  // TRANSLATING marker is allowed (recovery from cancelled runs).
  const noWhitespace = body.replace(/[\s\n\r]/g, "");
  if (!noWhitespace) return false;
  const text = body
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/<(img|video|source|picture)\b[^>]*>/gi, "")
    .replace(/<\/?[a-z][^>]*>/gi, "")
    .replace(/@[\w-]+/g, "")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/[\p{Emoji_Presentation}\p{Extended_Pictographic}️‍]/gu, "");
  return /\p{L}/u.test(text);
}

// --- Generic translate-and-update flow ---
//
// adapter shape:
//   {
//     label: string,                              // for logs / summary
//     getBody(): string,                          // raw body of the item
//     update(body): Promise<void>,                // write a new body
//     supportsInProgressMarker: boolean,          // false for PR review bodies
//   }
async function translateAndUpdate(adapter, core) {
  const rawBody = adapter.getBody();
  if (!needsTranslation(rawBody)) return false;

  const original = stripArtifacts(rawBody);
  if (!original) return false;

  if (adapter.supportsInProgressMarker) {
    await adapter.update(buildTranslatingBody(original));
  }

  try {
    const result = await translateText(original);
    await adapter.update(buildTranslatedBody(original, result));
    console.log(`${adapter.label} translated.`);
    return true;
  } catch (e) {
    const message = e.message || String(e);
    core.warning(`Failed to translate ${adapter.label}: ${message}`);
    // Restore original (without failure marker in PR body) so the next
    // event can retry cleanly.
    if (adapter.supportsInProgressMarker) {
      try {
        await adapter.update(original);
      } catch (restoreError) {
        core.warning(
          `Failed to restore ${adapter.label}: ${restoreError.message}`,
        );
      }
    }
    return { failed: true, label: adapter.label, message };
  }
}

// --- Adapters per item type ---
function prBodyAdapter(github, owner, repo, prNumber, pr) {
  return {
    label: `PR #${prNumber} body`,
    getBody: () => pr.body,
    update: (body) =>
      github.rest.pulls.update({ owner, repo, pull_number: prNumber, body }),
    supportsInProgressMarker: true,
  };
}

function issueCommentAdapter(github, owner, repo, comment) {
  return {
    label: `issue comment ${comment.id}`,
    getBody: () => comment.body,
    update: (body) =>
      github.rest.issues.updateComment({
        owner,
        repo,
        comment_id: comment.id,
        body,
      }),
    supportsInProgressMarker: true,
  };
}

function reviewCommentAdapter(github, owner, repo, comment) {
  return {
    label: `review comment ${comment.id}`,
    getBody: () => comment.body,
    update: (body) =>
      github.rest.pulls.updateReviewComment({
        owner,
        repo,
        comment_id: comment.id,
        body,
      }),
    supportsInProgressMarker: true,
  };
}

function reviewAdapter(github, owner, repo, prNumber, review) {
  return {
    label: `review ${review.id}`,
    getBody: () => review.body,
    // pulls.updateReview posts a new timeline event for every body update,
    // so we deliberately skip the "Translating..." in-progress write here
    // to avoid duplicating timeline noise.
    update: (body) =>
      github.rest.pulls.updateReview({
        owner,
        repo,
        pull_number: prNumber,
        review_id: review.id,
        body,
      }),
    supportsInProgressMarker: false,
  };
}

// --- Main entry point ---
//
// Note: items authored by `github-actions[bot]` (isExcludedAuthor) are
// skipped entirely — that identity covers every workflow bot in this repo
// (Claude reviewer, reviewer-suggester, review-request pings, etc.), all
// posted via the default GITHUB_TOKEN, so there is no way to translate one
// without translating them all. Other bot identities (e.g. a dedicated Jira
// sync bot) are still translated. The `<!-- translated-by-claude -->` marker
// prevents re-translating any item we have already touched. The only
// self-loop surface is the `pull_request: edited` event when we update the
// PR body, which is gated at the YAML `if:` level via `sender.login`.
async function main({ github, context, core }) {
  const owner = context.repo.owner;
  const repo = context.repo.repo;

  // Resolve PR number from any of the supported event payloads.
  const payload = context.payload;
  const prNumber =
    (context.eventName === "pull_request" && payload.pull_request?.number) ||
    payload.issue?.number ||
    payload.pull_request?.number;

  if (!prNumber) {
    console.log("Could not determine PR number. Skipping.");
    return;
  }
  console.log(`Processing PR #${prNumber}`);

  let translated = 0;
  const failures = [];

  const recordResult = (result) => {
    if (result === true) {
      translated++;
    } else if (result && result.failed) {
      failures.push(result);
    }
  };

  // 1. PR body
  const { data: pr } = await github.rest.pulls.get({
    owner,
    repo,
    pull_number: prNumber,
  });
  if (!isExcludedAuthor(pr.user?.login)) {
    recordResult(
      await translateAndUpdate(
        prBodyAdapter(github, owner, repo, prNumber, pr),
        core,
      ),
    );
  }

  // 2. Issue comments (PR conversation)
  const issueComments = await github.paginate(
    github.rest.issues.listComments,
    { owner, repo, issue_number: prNumber, per_page: CONFIG.PER_PAGE },
  );
  for (const comment of issueComments) {
    if (isExcludedAuthor(comment.user?.login)) continue;
    recordResult(
      await translateAndUpdate(
        issueCommentAdapter(github, owner, repo, comment),
        core,
      ),
    );
  }

  // 3. Review comments (inline code comments)
  const reviewComments = await github.paginate(
    github.rest.pulls.listReviewComments,
    { owner, repo, pull_number: prNumber, per_page: CONFIG.PER_PAGE },
  );
  for (const comment of reviewComments) {
    if (isExcludedAuthor(comment.user?.login)) continue;
    recordResult(
      await translateAndUpdate(
        reviewCommentAdapter(github, owner, repo, comment),
        core,
      ),
    );
  }

  // 4. PR review bodies (Approve / Request changes / Comment reviews)
  // Skip dismissed/pending — updating them would resurrect them in the timeline.
  const ALLOWED_REVIEW_STATES = new Set([
    "APPROVED",
    "CHANGES_REQUESTED",
    "COMMENTED",
  ]);
  const reviews = await github.paginate(github.rest.pulls.listReviews, {
    owner,
    repo,
    pull_number: prNumber,
    per_page: CONFIG.PER_PAGE,
  });
  for (const review of reviews) {
    if (!review.body) continue;
    if (!ALLOWED_REVIEW_STATES.has(review.state)) continue;
    if (isExcludedAuthor(review.user?.login)) continue;
    recordResult(
      await translateAndUpdate(
        reviewAdapter(github, owner, repo, prNumber, review),
        core,
      ),
    );
  }

  console.log(`Done. Translated ${translated} item(s).`);
  core.setOutput("translated_count", String(translated));
  core.setOutput("failure_count", String(failures.length));

  // Job summary instead of polluting the PR with failure messages.
  const summary = core.summary
    .addHeading("Translate PR")
    .addRaw(`PR #${prNumber} — translated ${translated} item(s).`)
    .addEOL();
  if (failures.length > 0) {
    summary.addHeading("Failures", 2).addList(
      failures.map((f) => `${f.label}: ${f.message}`),
    );
  }
  await summary.write();
}

module.exports = {
  main,
  // Pure helpers exposed for the standalone quality test harness. Not part
  // of the production API — do not import from other workflow scripts.
  __test: {
    needsTranslation,
    stripArtifacts,
    buildTranslatedBody,
    extractFirstJsonObject,
    buildLiteLlmUrl,
    isExcludedAuthor,
  },
};
