import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = resolve(process.argv[2] || 'release');
const pkg = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
const tag = `v${pkg.version}`;
if (process.env.GITHUB_REF_TYPE === 'tag') {
  assert.equal(process.env.GITHUB_REF_NAME, tag, 'Tag must exactly match package.json');
}
assert.ok(!existsSync(output) || readdirSync(output).length === 0, 'Output directory must be empty; never replace release bytes');
mkdirSync(output, { recursive: true });
// A stale build file must not survive a deleted/renamed source. prepack is the only build.
rmSync(resolve(root, 'build'), { recursive: true, force: true });
const windows = process.platform === 'win32';
const npmCli = windows
  ? resolve(dirname(execFileSync('where.exe', ['npm.cmd'], { encoding: 'utf8' }).trim().split(/\r?\n/)[0]), 'node_modules/npm/bin/npm-cli.js')
  : null;
const args = ['pack', '--json', '--silent', '--pack-destination', output];
const packed = JSON.parse(execFileSync(windows ? process.execPath : 'npm',
  windows ? [npmCli, ...args] : args,
  { cwd: root, encoding: 'utf8', env: { ...process.env, npm_config_loglevel: 'silent' } }));
assert.equal(packed.length, 1);
const { filename, version } = packed[0];
assert.equal(version, pkg.version);
assert.match(filename, /^[a-zA-Z0-9._-]+\.tgz$/);
const sha256 = createHash('sha256').update(readFileSync(resolve(output, filename))).digest('hex');
const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const sourceDirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=no'], { cwd: root, encoding: 'utf8' }).trim() !== '';
writeFileSync(resolve(output, `${filename}.sha256`), `${sha256}  ${filename}\n`);
const metadata = { filename, version, tag, sourceCommit, sourceDirty, sha256 };
writeFileSync(resolve(output, 'release.json'), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(JSON.stringify(metadata, null, 2));
