#!/usr/bin/env ts-node

/**
 * Simple sitemap audit script:
 *  - Fetches sitemap.xml for a given site
 *  - Verifies HTTP status codes and basic headers
 *  - Ensures robots.txt does not block crawlers
 *  - Spot-checks URLs from the sitemap for crawlability blockers
 */

import { exit, argv } from 'node:process';
import { URL } from 'node:url';

type IssueLevel = 'error' | 'warning';

interface Issue {
  level: IssueLevel;
  subject: string;
  detail: string;
}

interface FetchOutcome {
  ok: boolean;
  status: number;
  statusText: string;
  headers: Headers;
  body?: string;
}

interface RobotsRules {
  allows: string[];
  disallows: string[];
}

const BLOCKING_ROBOTS_TOKENS = ['noindex', 'nofollow', 'none', 'noarchive'];
const MAX_URLS_TO_CHECK = 50;
const CONCURRENCY = 5;

if (!argv[2]) {
  console.error('Usage: ts-node sitemap-audit.tsx <https://example.com>');
  exit(1);
}

async function main(): Promise<void> {
  const inputUrl = ensureAbsolute(argv[2]);
  if (!inputUrl) {
    console.error('Please provide a fully-qualified URL, e.g. https://example.com');
    exit(1);
  }

  const issues: Issue[] = [];
  const notes: string[] = [];
  const sitemapUrl = new URL('/sitemap.xml', inputUrl).toString();

  console.log(`🔍 Auditing sitemap for ${inputUrl}`);
  console.log(`→ Sitemap: ${sitemapUrl}`);

  const sitemapResponse = await safeFetch(sitemapUrl);
  if (!sitemapResponse.ok) {
    issues.push({
      level: 'error',
      subject: 'sitemap.xml',
      detail: `Fetch failed with status ${sitemapResponse.status} ${sitemapResponse.statusText}`,
    });
    report(issues, notes);
    return;
  }

  if (!isXmlContentType(sitemapResponse.headers.get('content-type'))) {
    issues.push({
      level: 'warning',
      subject: 'sitemap.xml',
      detail: `Unexpected Content-Type "${sitemapResponse.headers.get('content-type')}"`,
    });
  }

  const sitemapXml = sitemapResponse.body ?? '';
  const urlsFromSitemap = await collectSitemapUrls(sitemapXml, sitemapUrl);
  if (urlsFromSitemap.length === 0) {
    issues.push({
      level: 'warning',
      subject: 'sitemap.xml',
      detail: 'No <loc> entries found; Google may ignore empty sitemaps.',
    });
  } else {
    notes.push(`Found ${urlsFromSitemap.length} URL(s) in sitemap (checking up to ${MAX_URLS_TO_CHECK}).`);
  }

  const robotsReport = await inspectRobots(inputUrl, urlsFromSitemap);
  issues.push(...robotsReport.issues);
  notes.push(...robotsReport.notes);

  const urlsToCheck = urlsFromSitemap.slice(0, MAX_URLS_TO_CHECK);
  const pageChecks = await auditUrlBatch(urlsToCheck);
  issues.push(...pageChecks.issues);
  notes.push(...pageChecks.notes);

  report(issues, notes);
}

function ensureAbsolute(raw: string): string | null {
  try {
    const url = new URL(raw);
    if (!url.protocol.startsWith('http')) return null;
    url.hash = '';
    return url.toString();
  } catch {
    return null;
  }
}

async function safeFetch(target: string, init?: RequestInit): Promise<FetchOutcome> {
  try {
    const response = await fetch(target, init);
    const headers = response.headers;
    const status = response.status;
    const statusText = response.statusText;
    let body: string | undefined;

    if (!shouldSkipBody(init)) {
      body = await response.text();
    }

    return {
      ok: response.ok,
      status,
      statusText,
      headers,
      body,
    };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      statusText: error instanceof Error ? error.message : 'Unknown error',
      headers: new Headers(),
    };
  }
}

function shouldSkipBody(init?: RequestInit): boolean {
  if (!init || !init.method) return false;
  return init.method.toUpperCase() === 'HEAD';
}

function isXmlContentType(contentType: string | null): boolean {
  if (!contentType) return false;
  return /application\/xml|text\/xml/i.test(contentType);
}

async function collectSitemapUrls(xml: string, sitemapUrl: string, visited = new Set<string>()): Promise<string[]> {
  if (visited.has(sitemapUrl)) return [];
  visited.add(sitemapUrl);

  const urls: string[] = [];
  const locs = extractLocs(xml);

  const isIndex = /<\s*sitemapindex[\s>]/i.test(xml);
  if (isIndex) {
    for (const loc of locs) {
      if (!visited.has(loc) && loc.endsWith('.xml')) {
        const nested = await safeFetch(loc);
        if (nested.ok && nested.body) {
          urls.push(...await collectSitemapUrls(nested.body, loc, visited));
        }
      }
    }
  } else {
    urls.push(...locs);
  }

  return uniqueUrls(urls);
}

function extractLocs(xml: string): string[] {
  const matches: string[] = [];
  const locRegex = /<\s*loc\s*>\s*<!\[CDATA\[(.*?)\]\]>|<\s*loc\s*>(.*?)<\/\s*loc\s*>/gi;
  let match: RegExpExecArray | null;
  while ((match = locRegex.exec(xml)) !== null) {
    const loc = decodeXml(match[1] ?? match[2] ?? '').trim();
    if (!loc) continue;
    try {
      matches.push(new URL(loc).toString());
    } catch {
      // Ignore invalid URLs inside sitemap.
    }
  }
  return matches;
}

function decodeXml(value: string): string {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

function uniqueUrls(urls: string[]): string[] {
  return [...new Set(urls)];
}

async function inspectRobots(baseUrl: string, urls: string[]): Promise<{ issues: Issue[]; notes: string[] }> {
  const robotsUrl = new URL('/robots.txt', baseUrl).toString();
  const issues: Issue[] = [];
  const notes: string[] = [];

  const robotsResponse = await safeFetch(robotsUrl);
  if (!robotsResponse.ok) {
    issues.push({
      level: 'warning',
      subject: 'robots.txt',
      detail: `Fetch failed with status ${robotsResponse.status} ${robotsResponse.statusText}. A missing robots.txt defaults to allow but is worth fixing.`,
    });
    return { issues, notes };
  }

  notes.push('robots.txt fetched successfully.');

  const rules = parseRobots(robotsResponse.body ?? '');
  if (rules.disallows.includes('/')) {
    issues.push({
      level: 'error',
      subject: 'robots.txt',
      detail: 'robots.txt contains "Disallow: /" for User-agent "*", which blocks all crawling.',
    });
    return { issues, notes };
  }

  const blockedUrls: string[] = [];
  for (const url of urls.slice(0, MAX_URLS_TO_CHECK)) {
    const path = new URL(url).pathname;
    if (isPathDisallowed(path, rules)) {
      blockedUrls.push(url);
    }
  }

  if (blockedUrls.length > 0) {
    issues.push({
      level: 'error',
      subject: 'robots.txt',
      detail: `robots.txt disallows ${blockedUrls.length} URL(s) present in the sitemap.`,
    });
  }

  return { issues, notes };
}

function parseRobots(content: string): RobotsRules {
  const lines = content.split(/\r?\n/);
  const normalized: RobotsRules = { allows: [], disallows: [] };
  const userAgentLabel = /^user-agent\s*:\s*(.+)$/i;
  const disallowLabel = /^disallow\s*:\s*(.*)$/i;
  const allowLabel = /^allow\s*:\s*(.*)$/i;

  let inGlobalSection = false;
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;

    const uaMatch = userAgentLabel.exec(line);
    if (uaMatch) {
      inGlobalSection = uaMatch[1].trim() === '*';
      continue;
    }

    if (!inGlobalSection) continue;

    const disallowMatch = disallowLabel.exec(line);
    if (disallowMatch) {
      normalized.disallows.push(disallowMatch[1].trim() || '/');
      continue;
    }

    const allowMatch = allowLabel.exec(line);
    if (allowMatch) {
      normalized.allows.push(allowMatch[1].trim());
    }
  }

  return normalized;
}

function isPathDisallowed(pathname: string, rules: RobotsRules): boolean {
  // Evaluate using "longest match wins" rule.
  const disallowMatchLength = longestMatchLength(pathname, rules.disallows);
  const allowMatchLength = longestMatchLength(pathname, rules.allows);
  if (disallowMatchLength === 0) return false;
  return disallowMatchLength > allowMatchLength;
}

function longestMatchLength(pathname: string, patterns: string[]): number {
  let longest = 0;
  for (const pattern of patterns) {
    if (!pattern) continue;
    const normalizedPattern = pattern.endsWith('$') ? pattern.slice(0, -1) : pattern;
    if (pathname.startsWith(normalizedPattern)) {
      longest = Math.max(longest, normalizedPattern.length);
    }
  }
  return longest;
}

async function auditUrlBatch(urls: string[]): Promise<{ issues: Issue[]; notes: string[] }> {
  const issues: Issue[] = [];
  const notes: string[] = [];

  if (urls.length === 0) {
    return { issues, notes };
  }

  console.log(`Checking ${urls.length} sitemap URL(s)...`);
  const results = await runWithConcurrency(urls, CONCURRENCY, async (url) => ({
    url,
    result: await safeFetch(url),
  }));

  for (const { url, result } of results) {
    if (!result.ok) {
      issues.push({
        level: 'error',
        subject: url,
        detail: `Fetch failed with status ${result.status} ${result.statusText}`,
      });
      continue;
    }

    if (result.status >= 300) {
      issues.push({
        level: 'warning',
        subject: url,
        detail: `Returned HTTP ${result.status}; Google prefers 200 responses.`,
      });
    }

    const xRobots = result.headers.get('x-robots-tag');
    if (xRobots && containsBlockingRobotsValue(xRobots)) {
      issues.push({
        level: 'error',
        subject: url,
        detail: `X-Robots-Tag header "${xRobots}" tells Google not to index.`,
      });
    }

    if (result.body) {
      const meta = extractMetaRobots(result.body);
      if (meta && containsBlockingRobotsValue(meta)) {
        issues.push({
          level: 'error',
          subject: url,
          detail: `<meta name="robots" content="${meta}"> blocks indexing.`,
        });
      }
    }
  }

  notes.push('URL spot check completed.');
  return { issues, notes };
}

function containsBlockingRobotsValue(value: string): boolean {
  const normalized = value.toLowerCase();
  return BLOCKING_ROBOTS_TOKENS.some((token) => normalized.includes(token));
}

function extractMetaRobots(html: string): string | null {
  const match = /<meta\s+[^>]*name=["']robots["'][^>]*content=["']([^"']+)["'][^>]*>/i.exec(html);
  return match ? match[1] : null;
}

async function runWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = [];
  let currentIndex = 0;

  async function next(): Promise<void> {
    if (currentIndex >= items.length) return;
    const index = currentIndex++;
    results[index] = await worker(items[index], index);
    await next();
  }

  const runners = Array.from({ length: Math.min(concurrency, items.length) }, () => next());
  await Promise.all(runners);
  return results;
}

function report(issues: Issue[], notes: string[]): void {
  const sorted = issues.sort((a, b) => (a.level === b.level ? 0 : a.level === 'error' ? -1 : 1));

  if (sorted.length === 0) {
    console.log('✅ No critical blockers detected. Review notes below:');
  } else {
    console.log('⚠️ Potential issues detected:');
    for (const issue of sorted) {
      console.log(`  [${issue.level.toUpperCase()}] ${issue.subject}: ${issue.detail}`);
    }
  }

  if (notes.length > 0) {
    console.log('\nAdditional notes:');
    for (const note of notes) {
      console.log(`  - ${note}`);
    }
  }
}

main().catch((error) => {
  console.error(`Unexpected error: ${error instanceof Error ? error.stack : String(error)}`);
  exit(1);
});

