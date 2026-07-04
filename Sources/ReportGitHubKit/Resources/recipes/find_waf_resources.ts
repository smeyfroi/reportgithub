const meta: ScriptMeta = {
  title: "Report on a CloudFormation resource",
  phase: "check",
  apiVersion: 1,
  prompt: "report on repos that define a WAF resource in cloudformation: give me the different parameters that are in use",
  icon: "shield.lefthalf.filled",
  params: {
    glob: "**/*.template",
    resourceType: "AWS::WAFv2::WebACL",
  },
};

// Find/extract script for the Report step: it verifies a match (the named
// CloudFormation resource exists) AND, in the SAME document walk, extracts the
// comparison-relevant parameters into evidence.fields. The Report step then
// aggregates those fields into a comparison matrix across repos — no file
// content is ever sent to the report LLM, only these verified scalar values.
//
// Reads are batched: the per-repo listFiles tree walk stays serial (GraphQL
// can't batch a recursive tree), but every candidate template across every repo
// is fetched in ONE gh.getContentBatch call, on GitHub's separate GraphQL quota
// pool — so an org-wide scan costs a handful of GraphQL requests instead of one
// REST GET per template. A per-repo fetch error is surfaced with job.error, not
// dropped silently.
async function main(): Promise<void> {
  const { glob, resourceType } = job.params;
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for ${resourceType}`);

  // Phase 1 — per repo, list candidate template files. The tree walk can't be
  // batched, so a repo that errors here is surfaced immediately.
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
        job.skip(repo, "no CloudFormation template files");
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

  // Phase 3 — regroup by repo (candidates keep repo order, so a running cursor
  // slices out each repo's results) and evaluate: a fetch error fails the repo,
  // otherwise the first matching resource wins.
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
        const resource = resources[logicalId];
        if (!resource || resource.Type !== resourceType) continue;

        const props: Record<string, any> = resource.Properties || {};
        const scope = props.Scope !== undefined ? String(props.Scope) : "(unset)";
        const actionKeys = props.DefaultAction ? Object.keys(props.DefaultAction) : [];
        const defaultAction = actionKeys.length > 0 ? String(actionKeys[0]) : "(unset)";

        const rules: any[] = Array.isArray(props.Rules) ? props.Rules : [];
        const managedRuleGroups: string[] = [];
        for (const rule of rules) {
          const statement = rule && rule.Statement ? rule.Statement : {};
          const managed = statement.ManagedRuleGroupStatement;
          if (managed && managed.Name) managedRuleGroups.push(String(managed.Name));
        }

        job.reportMatch(repo, {
          path,
          excerpt: `  ${logicalId}:\n    Type: ${resourceType}`,
          explanation: `${logicalId}: ${scope}, default ${defaultAction}, ${managedRuleGroups.length} managed rule group(s)`,
          fields: {
            Scope: scope,
            DefaultAction: defaultAction,
            ManagedRuleGroups: managedRuleGroups,
            RuleCount: rules.length,
          },
        });
        reported = true;
        break;
      }
      if (reported) break;
    }

    if (!reported) job.skip(repo, `no ${resourceType} resource`);
  }

  job.progress("scan complete");
}
