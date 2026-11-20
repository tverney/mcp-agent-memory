#!/usr/bin/env node
/**
 * Prints Markdown release notes for the commits between two refs, grouped by Conventional Commit type.
 *
 * Usage: node release-notes.mjs <prevTag|""> <toRef> <newTag> <owner/repo>
 */
import { execFileSync } from 'node:child_process';

const [prevTag, toRef, newTag, repo] = process.argv.slice(2);
if (!toRef || !newTag || !repo) {
  console.error('Usage: release-notes.mjs <prevTag|""> <toRef> <newTag> <owner/repo>');
  process.exit(2);
}

const range = prevTag ? `${prevTag}..${toRef}` : toRef;
const SEP = '\x1f';
const END = '\x1e';
const raw = execFileSync(
  'git',
  ['log', '--first-parent', `--pretty=format:%s${SEP}%b${END}`, range],
  { encoding: 'utf8' },
);

const sections = {
  breaking: { title: 'Breaking Changes', items: [] },
  feat: { title: 'Features', items: [] },
  fix: { title: 'Fixes', items: [] },
  changes: { title: 'Changes', items: [] },
  docs: { title: 'Docs', items: [] },
};
const deps = new Map(); // package -> { from, to, prs: [] }
const depLines = []; // dependency commits that are not a single "bump X from A to B"

const CONVENTIONAL = /^(\w+)(?:\(([^)]+)\))?(!)?:\s*(.+)$/;
const BUMP = /\bbump\s+(\S+)\s+from\s+(\S+)\s+to\s+(\S+)/i;
const PR_SUFFIX = /\s*\(#(\d+)\)\s*$/;
const MERGE_PR = /^Merge pull request #(\d+) from \S+/;

// git log is newest-first; walk oldest-first so dependency ranges read from -> to.
const commits = raw.split(END).map((c) => c.trim()).filter(Boolean).reverse();

for (const commit of commits) {
  let [subject, body = ''] = commit.split(SEP);
  subject = subject.trim();
  body = body.trim();

  // Merge commits: use the PR title (first body line) as the subject.
  const merge = subject.match(MERGE_PR);
  if (merge) {
    const title = body.split('\n')[0].trim();
    if (!title) continue;
    subject = `${title} (#${merge[1]})`;
    body = body.split('\n').slice(1).join('\n');
  } else if (subject.startsWith('Merge ')) {
    continue;
  }

  let pr = '';
  const prMatch = subject.match(PR_SUFFIX);
  if (prMatch) {
    pr = prMatch[1];
    subject = subject.replace(PR_SUFFIX, '');
  }
  const prRef = pr ? ` (#${pr})` : '';

  const cc = subject.match(CONVENTIONAL);
  const type = cc ? cc[1].toLowerCase() : '';
  const scope = cc?.[2];
  const description = cc ? cc[4] : subject;

  // Skip the version-bump commit itself.
  if (/^chore(\(.+\))?: release v?\d/i.test(subject)) continue;

  const bump = subject.match(BUMP);
  if (bump) {
    const [, name, from, to] = bump;
    const entry = deps.get(name) ?? { from, to, prs: [] };
    entry.to = to;
    if (pr) entry.prs.push(`#${pr}`);
    deps.set(name, entry);
    continue;
  }

  if (scope === 'deps' || scope === 'deps-dev') {
    depLines.push(`- ${description}${prRef}`);
    continue;
  }

  const line = `- ${scope ? `**${scope}:** ` : ''}${description}${prRef}`;
  if (cc?.[3] || /^BREAKING[ -]CHANGE:/m.test(body)) sections.breaking.items.push(line);
  else if (type === 'feat') sections.feat.items.push(line);
  else if (type === 'fix') sections.fix.items.push(line);
  else if (type === 'docs') sections.docs.items.push(line);
  else sections.changes.items.push(line);
}

const out = ["## What's Changed", ''];
let empty = true;
for (const { title, items } of Object.values(sections)) {
  if (!items.length) continue;
  empty = false;
  out.push(`### ${title}`, ...items, '');
}
if (deps.size || depLines.length) {
  empty = false;
  out.push('### Dependencies');
  for (const [name, { from, to, prs }] of deps) {
    out.push(`- Bump \`${name}\` from ${from} to ${to}${prs.length ? ` (${prs.join(', ')})` : ''}`);
  }
  out.push(...depLines, '');
}
if (empty) out.push('_No user-facing changes._', '');

out.push(
  prevTag
    ? `**Full Changelog:** https://github.com/${repo}/compare/${prevTag}...${newTag}`
    : `**Full Changelog:** https://github.com/${repo}/commits/${newTag}`,
);

process.stdout.write(out.join('\n') + '\n');
