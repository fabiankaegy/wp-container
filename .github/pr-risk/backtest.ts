/**
 * Replays the policy over a repo's recently merged PRs to show how often it
 * would approve, flag or block, before trusting its thresholds. Writes nothing
 * to the repo.
 *
 * Usage: node backtest.ts owner/repo [count]
 * Needs GITHUB_TOKEN (read access to the repo) and TYPESAFE_API_KEY. In Actions,
 * run the "PR risk backtest" workflow; the report lands in the run summary.
 */
import { appendFileSync } from "node:fs";
import { assessPullRequest, type Assessment, type Outcome } from "./assess.ts";
import { githubAll } from "./github.ts";

const [repo, countArg = "100"] = process.argv.slice(2);
if (!repo) throw new Error("Usage: node backtest.ts owner/repo [count]");
const count = Number(countArg);

const ICONS: Record<Outcome, string> = { approve: "✅", flag: "⚠️", block: "🛑" };

// Closed PRs include unmerged ones, so over-fetch and keep the merged ones.
const closed = await githubAll<any>(`/repos/${repo}/pulls?state=closed&sort=updated&direction=desc`, count * 2);
const merged = closed.filter((pr) => pr.merged_at).slice(0, count);

const rows: string[] = [];
const totals: Record<Outcome | "error", number> = { approve: 0, flag: 0, block: 0, error: 0 };

for (const pr of merged) {
	let assessment: Assessment;
	try {
		assessment = await assessPullRequest(repo, pr.number);
	} catch (error) {
		totals.error++;
		rows.push(`| #${pr.number} | ${pr.title} | ❌ | ${(error as Error).message.slice(0, 120)} |`);
		continue;
	}
	totals[assessment.outcome]++;
	const findings = assessment.findings
		.map((f) => `${ICONS[f.severity]} \`${f.file}\` ${f.reason} (${Math.round(f.probability * 100)}%)`)
		.join("<br>");
	rows.push(`| [#${pr.number}](${pr.html_url}) | ${pr.title.replaceAll("|", "\\|")} | ${ICONS[assessment.outcome]} | ${findings} |`);
	console.error(`#${pr.number} ${assessment.outcome}`);
}

const pct = (n: number) => `${Math.round((n / merged.length) * 100)}%`;
const report = [
	`## pr-risk backtest: ${repo}, last ${merged.length} merged PRs`,
	`✅ approved ${totals.approve} (${pct(totals.approve)}) · ⚠️ flagged ${totals.flag} (${pct(totals.flag)}) · 🛑 blocked ${totals.block} (${pct(totals.block)})` +
		(totals.error ? ` · ❌ errors ${totals.error}` : ""),
	"| PR | Title | Outcome | Findings |\n|---|---|---|---|\n" + rows.join("\n"),
].join("\n\n");

console.log(report);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, report + "\n");
