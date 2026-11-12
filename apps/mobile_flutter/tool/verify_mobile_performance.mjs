import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { gzipSync } from 'node:zlib';

// Repeatable release-size guard. Browser timings/FPS are measured separately;
// neither bundle size nor widget counts are substitutes for frame profiling.
const directory = path.resolve(process.argv[2] || 'build/web');
const main = fs.readFileSync(path.join(directory, 'main.dart.js'));
const html = fs.readFileSync(path.join(directory, 'index.html'), 'utf8');
const chunks = fs.readdirSync(directory).filter(name => name.endsWith('.part.js'));
assert(main.length <= 4_800_000, 'Initial JS exceeds the mobile release budget.');
assert(gzipSync(main).length <= 1_400_000, 'Compressed initial JS exceeds budget.');
assert(chunks.length > 0, 'Deferred image-processing chunks must be shipped.');
for (const chunk of chunks) {
  assert(fs.statSync(path.join(directory, chunk)).size > 0, `Empty deferred chunk: ${chunk}`);
}
assert(html.includes('as="script" href="main.dart.js"'), 'Missing early app-script discovery.');
console.log(JSON.stringify({
  initialJavaScriptBytes: main.length,
  initialJavaScriptGzipBytes: gzipSync(main).length,
  deferredChunks: chunks.map(file => ({ file, bytes: fs.statSync(path.join(directory, file)).size })),
  status: 'Mobile release-size budget passed',
}, null, 2));
