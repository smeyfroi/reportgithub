const meta: ScriptMeta = {
  title: "Report custom properties across repos",
  phase: "check",
  apiVersion: 1,
  params: {
    // Optional: limit to repos that set this property (blank = every repo that
    // has any custom property set).
    property: "",
  },
};

// Reports GitHub custom properties — org-level metadata (e.g. ProjectType,
// Tier) that lives on the repo, not in a file. listOrgProperties is the
// authoritative bulk read (real stored values, no search-index staleness), and
// reading it lets us reportMatch each repo with its properties as fields — no
// file fetch needed.
async function main(): Promise<void> {
  const { property } = job.params;
  const all = await gh.listOrgProperties();
  job.progress(`scanning ${all.length} repo(s) for custom properties`);

  for (const { repo, properties } of all) {
    const names = Object.keys(properties).filter(
      (name) => properties[name] !== null && properties[name] !== undefined
    );

    if (property) {
      if (properties[property] === null || properties[property] === undefined) {
        job.skip(repo, `${property} unset`);
        continue;
      }
    } else if (names.length === 0) {
      job.skip(repo, "no custom properties set");
      continue;
    }

    const fields: Record<string, FindingValue> = {};
    const parts: string[] = [];
    for (const name of names) {
      const value = properties[name];
      fields[name] = value as FindingValue;
      parts.push(`${name} = ${Array.isArray(value) ? value.join(", ") : String(value)}`);
    }

    job.reportMatch(repo, {
      path: "custom properties",
      excerpt: parts.join("\n"),
      explanation: parts.join("; "),
      fields,
    });
  }

  job.progress("scan complete");
}
