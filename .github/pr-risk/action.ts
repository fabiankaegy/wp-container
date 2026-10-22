/**
 * The GitHub Action entry point: assesses the PR, then labels it, keeps one
 * comment up to date, and approves it unless something needs a human.
 *
 * Runs from .github/workflows/pr-risk.yml on `pull_request_target`, so this
 * code and policy.ts always come from the base branch: a PR can't edit its own
 * gate. PR code is never checked out or executed; diffs are only read as data.
 *
 * Local dry run (no labels, comments or reviews are written):
 *   DRY_RUN=1 GITHUB_REPOSITORY=owner/repo PR_NUMBER=123 \
 *   GITHUB_TOKEN=$(gh auth token) TYPESAFE_API_KEY=... node action.ts
 */
import { assessPullRequest, type Assessment, type Outcome } from "./assess.ts";
import { github, githubAll } from "./github.ts";

// Marks the bot's comment so reruns update it instead of adding new ones.
const COMMENT_MARKER = "<!-- pr-risk -->";
const BOT_LOGIN = "github-actions[bot]";

const LABELS: Record<Outcome, string> = {
	approve: "pr-risk: approved",
	flag: "pr-risk: flagged",
	block: "pr-risk: needs review",
};

const HEADINGS: Record<Outcome, string> = {
	approve: "✅ Auto-approved",
	flag: "⚠️ Auto-approved with flags: worth a look after merging",
	block: "🛑 Human review required",
};

const repo = process.env.GITHUB_REPOSITORY!;
const prNumber = Number(process.env.PR_NUMBER);
const base = `/repos/${repo}`;

/** Renders the assessment as the PR comment. */
function renderComment({ outcome, findings, headSha }: Assessment): string {
	const icon = { block: "🛑", flag: "⚠️" };
	const list = findings
		.map((f) => `- ${icon[f.severity]} \`${f.file}\`: ${f.reason} (${Math.round(f.probability * 100)}%)`)
		.join("\n");
	return [COMMENT_MARKER, `### ${HEADINGS[outcome]}`, list, `<sub>Assessed by Jev at ${headSha.slice(0, 7)}</sub>`]
		.filter(Boolean)
		.join("\n\n");
}

const assessment = await assessPullRequest(repo, prNumber);

// Only authors with write access can be auto-approved, so outside PRs can't
// talk their way past review.
const pr = await github(`${base}/pulls/${prNumber}`);
const { permission } = await github(`${base}/collaborators/${pr.user.login}/permission`);
if (!["admin", "maintain", "write"].includes(permission)) {
	assessment.outcome = "block";
	assessment.findings.unshift({ file: "", reason: "Author doesn't have write access", probability: 1, severity: "block" });
}

const comment = renderComment(assessment);
console.log(comment);

if (!process.env.DRY_RUN) {
	// Swap the outcome label.
	for (const label of Object.values(LABELS).filter((l) => l !== LABELS[assessment.outcome])) {
		await github(`${base}/issues/${prNumber}/labels/${encodeURIComponent(label)}`, { method: "DELETE" }).catch(() => {});
	}
	await github(`${base}/issues/${prNumber}/labels`, { method: "POST", body: { labels: [LABELS[assessment.outcome]] } });

	// The comment is the single source of truth for the assessment; it's
	// updated on every run, while review bodies stay frozen in the timeline.
	const comments = await githubAll<any>(`${base}/issues/${prNumber}/comments`);
	const existing = comments.find((c) => c.user?.login === BOT_LOGIN && c.body?.includes(COMMENT_MARKER));
	if (existing) await github(`${base}/issues/comments/${existing.id}`, { method: "PATCH", body: { body: comment } });
	else await github(`${base}/issues/${prNumber}/comments`, { method: "POST", body: { body: comment } });

	if (assessment.outcome !== "block") {
		await github(`${base}/pulls/${prNumber}/reviews`, {
			method: "POST",
			body: { event: "APPROVE", commit_id: assessment.headSha, body: `Auto-approved by pr-risk at ${assessment.headSha.slice(0, 7)}.` },
		});
	} else {
		// Withdraw earlier approvals, e.g. when a new push added a blocking change.
		const reviews = await githubAll<any>(`${base}/pulls/${prNumber}/reviews`);
		for (const review of reviews.filter((r) => r.user?.login === BOT_LOGIN && r.state === "APPROVED")) {
			await github(`${base}/pulls/${prNumber}/reviews/${review.id}/dismissals`, {
				method: "PUT",
				body: { message: "Re-assessed: human review required." },
			});
		}
	}
}
