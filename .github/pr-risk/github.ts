/**
 * Minimal GitHub REST client. Paths are relative to https://api.github.com and
 * requests authenticate with the GITHUB_TOKEN env var.
 */
export async function github<T = any>(
	path: string,
	{ method = "GET", body, accept = "application/vnd.github+json" }: { method?: string; body?: unknown; accept?: string } = {},
): Promise<T> {
	const res = await fetch(`https://api.github.com${path}`, {
		method,
		headers: {
			Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
			Accept: accept,
			"X-GitHub-Api-Version": "2022-11-28",
			...(body ? { "Content-Type": "application/json" } : {}),
		},
		body: body ? JSON.stringify(body) : undefined,
	});
	if (!res.ok) throw new Error(`GitHub ${method} ${path}: ${res.status} ${await res.text()}`);
	return res.status === 204 ? (undefined as T) : res.json();
}

/** Fetches every page of a list endpoint, stopping early once `limit` items are in. */
export async function githubAll<T>(path: string, limit = Infinity): Promise<T[]> {
	const items: T[] = [];
	for (let page = 1; items.length < limit; page++) {
		const sep = path.includes("?") ? "&" : "?";
		const batch = await github<T[]>(`${path}${sep}per_page=100&page=${page}`);
		items.push(...batch);
		if (batch.length < 100) break;
	}
	return items.slice(0, limit);
}
