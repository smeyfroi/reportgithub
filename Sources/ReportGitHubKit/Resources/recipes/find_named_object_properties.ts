const meta: ScriptMeta = {
  title: "Find a named object and report its properties",
  phase: "check",
  apiVersion: 1,
  params: {
    glob: "deploy/*.template",
    namePattern: "*Bucket",
  },
};

// Find/extract script for the Report step: in each repo, find the first object
// under a template's `Resources` whose logical name matches `namePattern` (a
// simple glob, e.g. "*Bucket"), and extract that object's Type plus its
// Properties — flattened to dotted-path scalar fields so the Report step can
// align and compare them across repos.
function nameMatches(name: string, pattern: string): boolean {
  const escaped = pattern
    .split("*")
    .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*");
  return new RegExp("^" + escaped + "$").test(name);
}

// Flatten a parsed object into dotted-path scalar entries. Scalars and arrays
// of scalars are recorded as-is; nested objects recurse; arrays of objects are
// indexed. Keeps the report's fields flat (the host requires scalar values).
function flatten(value: any, prefix: string, out: Record<string, FindingValue>): void {
  if (value === null || value === undefined) {
    out[prefix] = null;
    return;
  }
  if (Array.isArray(value)) {
    if (value.every((v) => v === null || typeof v !== "object")) {
      out[prefix] = value as FindingValue;
    } else {
      value.forEach((v, i) => flatten(v, `${prefix}[${i}]`, out));
    }
    return;
  }
  if (typeof value === "object") {
    for (const key of Object.keys(value)) {
      flatten(value[key], prefix ? `${prefix}.${key}` : key, out);
    }
    return;
  }
  out[prefix] = value as FindingValue;
}

// Reads are batched: the per-repo listFiles tree walk stays serial (GraphQL
// can't batch a recursive tree), but every candidate template across every repo
// is fetched in ONE gh.getContentBatch call, on GitHub's separate GraphQL quota
// pool. A per-repo fetch error is surfaced with job.error, not dropped.
async function main(): Promise<void> {
  const { glob, namePattern } = job.params;
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for an object named ${namePattern}`);

  // Phase 1 — per repo, list candidate files (the tree walk can't be batched).
  const pending: { repo: Repo; paths: string[] }[] = [];
  const candidates: { repo: Repo | string; path: string }[] = [];
  for (const repo of repos) {
    if (repo.archived) {
      job.skip(repo, "archived");
      continue;
    }
    try {
      const files = await gh.listFiles(repo, glob);
      if (files.length === 0) {
        job.skip(repo, `no files matching ${glob}`);
        continue;
      }
      pending.push({ repo, paths: files });
      for (const path of files) candidates.push({ repo, path });
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  // Phase 2 — one batched read for every candidate file across all repos.
  const contents = await gh.getContentBatch(candidates);

  // Phase 3 — regroup by repo (a running cursor slices each repo's results) and
  // evaluate: a fetch error fails the repo, otherwise the first matching object
  // wins.
  let cursor = 0;
  for (const { repo, paths } of pending) {
    const slice = contents.slice(cursor, cursor + paths.length);
    cursor += paths.length;

    const failed = slice.find((r) => r.error !== null);
    if (failed) {
      job.error(repo, failed.error ?? "fetch failed");
      continue;
    }

    let reported = false;
    for (let i = 0; i < slice.length; i++) {
      const text = slice[i].content;
      if (text === null) continue;
      const path = paths[i];

      const doc = parse.yaml(text) as { Resources?: Record<string, any> } | null;
      const resources = doc && doc.Resources ? doc.Resources : {};

      for (const logicalId of Object.keys(resources)) {
        if (!nameMatches(logicalId, namePattern)) continue;
        const object = resources[logicalId] || {};

        const fields: Record<string, FindingValue> = {
          ObjectName: logicalId,
        };
        if (object.Type !== undefined) fields.Type = String(object.Type);
        if (object.Properties && typeof object.Properties === "object") {
          flatten(object.Properties, "Properties", fields);
        }

        job.reportMatch(repo, {
          path,
          excerpt: `  ${logicalId}:\n    Type: ${object.Type ?? "(unset)"}`,
          explanation: `${logicalId} (${object.Type ?? "object"}) in ${path}`,
          fields,
        });
        reported = true;
        break;
      }
      if (reported) break;
    }

    if (!reported) job.skip(repo, `no object named ${namePattern}`);
  }

  job.progress("scan complete");
}
