// The log scan over a deployment's logs: no token a test used may appear.
//
//   vercel logs --json --since 1h | node scripts/scan-logs.mjs <secrets-file>
//
// Exit 0: lines were read and none holds a secret. Exit 1: a secret was found.
// Exit 3: no line was read, so nothing was observed (a green with nothing in it
// is not a green).

import { readFileSync } from 'node:fs';
import { leaksIn } from '../lib/log.js';

const file = process.argv[2];
if (!file) {
  console.error('usage: <logs> | node scripts/scan-logs.mjs <secrets-file>');
  process.exit(2);
}
const secrets = readFileSync(file, 'utf8').split('\n').map((s) => s.trim()).filter(Boolean);
const text = readFileSync(0, 'utf8');
const lines = text.split('\n').filter((l) => l.trim());
const relayLines = lines.filter((l) => l.includes('relay')).length;
const leaks = leaksIn(text, secrets);
console.log(`${lines.length} log lines read (${relayLines} from the relay), ${secrets.length} secrets looked for`);
if (leaks.length) {
  console.log(`✗ ${leaks.length} secrets found in the logs (first 6 characters: ${leaks.map((s) => s.slice(0, 6)).join(', ')})`);
  process.exit(1);
}
if (relayLines === 0) {
  console.log('⚠ no relay line in the logs: nothing was observed');
  process.exit(3);
}
console.log('✓ no secret in the logs');
