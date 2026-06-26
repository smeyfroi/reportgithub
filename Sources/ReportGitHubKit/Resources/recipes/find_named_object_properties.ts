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

async function main(): Promise<void> {
  const { glob, namePattern } = job.params;
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for an object named ${namePattern}`);

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

      let reported = false;
      for (const path of files) {
        const text = await gh.getContent(repo, path);
        if (text === null) continue;

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
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("scan complete");
}
