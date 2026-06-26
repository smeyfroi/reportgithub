const meta: ScriptMeta = {
  title: "Report on a CloudFormation resource's parameters",
  phase: "check",
  apiVersion: 1,
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
async function main(): Promise<void> {
  const { glob, resourceType } = job.params;
  const repos = await gh.listOrgRepos();
  job.progress(`scanning ${repos.length} repo(s) for ${resourceType}`);

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

      let reported = false;
      for (const path of files) {
        const text = await gh.getContent(repo, path);
        if (text === null) continue;

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
    } catch (e) {
      job.error(repo, String(e));
    }
  }

  job.progress("scan complete");
}
