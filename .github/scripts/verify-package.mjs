import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
assert.ok(process.argv[2] && process.argv[3], 'Usage: verify-package.mjs <tarball> <new external consumer directory>');
const tarball = realpathSync(process.argv[2]);
const consumer = resolve(process.argv[3]);
const inside = (parent, child) => {
  const rel = relative(parent, child);
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel));
};
assert.ok(!inside(root, consumer) && !inside(consumer, root), 'Consumer must be outside the checkout');
assert.ok(!existsSync(consumer), 'Consumer directory must not already exist');
mkdirSync(consumer, { recursive: true });
assert.ok(!inside(realpathSync(root), realpathSync(consumer)), 'Consumer cannot symlink into checkout');
const env = {
  ...process.env, NODE_PATH: '', CI: '1', EXPO_OFFLINE: '1', EXPO_NO_TELEMETRY: '1',
  CLOUDKIT_CONTAINER_ID: 'iCloud.com.example.transportci', CLOUDKIT_BUNDLE_ID: 'com.example.transportci',
  CLOUDKIT_ENVIRONMENT: 'Development', EXPO_PUBLIC_CI_SMOKE: '1',
};
const npmCli = process.platform === 'win32'
  ? resolve(dirname(execFileSync('where.exe', ['npm.cmd'], { encoding: 'utf8' }).trim().split(/\r?\n/)[0]), 'node_modules/npm/bin/npm-cli.js')
  : null;
function run(command, args, capture = false) {
  const useNpmCli = npmCli && command === 'npm';
  const result = spawnSync(useNpmCli ? process.execPath : command,
    useNpmCli ? [npmCli, ...args] : args,
    { cwd: consumer, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: capture ? 'pipe' : 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    if (capture) console.error(result.stdout, result.stderr);
    throw new Error(`${command} ${args.join(' ')} failed (${result.status})`);
  }
  return result.stdout;
}
function json(path) { return JSON.parse(readFileSync(path, 'utf8')); }
function save(path, value) { writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`); }
function files(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = resolve(directory, entry.name);
    return entry.isDirectory() ? files(path) : [path];
  });
}
// Copy only the fixture, not its node_modules, generated files or source link.
for (const file of ['App.tsx', 'index.ts', 'app.config.js', 'tsconfig.json', 'package.json', 'package-lock.json']) {
  copyFileSync(resolve(root, 'example-transport', file), resolve(consumer, file));
}
const localAsset = resolve(consumer, basename(tarball));
copyFileSync(tarball, localAsset);
run('tar', ['-xzf', localAsset, '-C', consumer]);
const extracted = resolve(consumer, 'package');
const packed = json(resolve(extracted, 'package.json'));
assert.equal(packed.name, 'expo-cloudkit');
for (const hook of ['prepare', 'preinstall', 'install', 'postinstall']) {
  assert.ok(!packed.scripts?.[hook], `Consumer-side ${hook} hook is forbidden`);
}
for (const peer of ['zod', 'tsl-apple-cloudkit']) {
  assert.equal(packed.peerDependenciesMeta?.[peer]?.optional, true, `${peer} must remain optional`);
  assert.ok(!packed.dependencies?.[peer], `${peer} must not become a required dependency`);
}
const app = json(resolve(consumer, 'package.json'));
const lock = json(resolve(consumer, 'package-lock.json'));
const spec = `file:./${basename(tarball)}`;
app.dependencies['expo-cloudkit'] = spec;
// The packed layout does not need source-link React singleton inclusion.
delete app.expo;
lock.packages[''].dependencies['expo-cloudkit'] = spec;
delete lock.packages['..'];
const integrity = `sha512-${createHash('sha512').update(readFileSync(localAsset)).digest('base64')}`;
lock.packages['node_modules/expo-cloudkit'] = {
  version: packed.version, resolved: spec, integrity, license: packed.license,
  ...(packed.dependencies ? { dependencies: packed.dependencies } : {}),
  peerDependencies: packed.peerDependencies, peerDependenciesMeta: packed.peerDependenciesMeta,
};
save(resolve(consumer, 'package.json'), app);
save(resolve(consumer, 'package-lock.json'), lock);
// All third-party versions/integrities remain the example's locked versions. No library dev dependencies.
run('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund']);
const require = createRequire(resolve(consumer, 'package.json'));
const installed = dirname(require.resolve('expo-cloudkit/package.json'));
assert.ok(inside(consumer, realpathSync(installed)) && !lstatSync(installed).isSymbolicLink());
for (const file of files(extracted)) {
  const target = resolve(installed, relative(extracted, file));
  assert.ok(existsSync(target), `Missing installed ${target}`);
  assert.deepEqual(readFileSync(target), readFileSync(file), `Installation changed packed ${target}`);
}
for (const devOnly of ['jest', 'ts-jest', 'eslint', '@testing-library/react']) {
  assert.ok(!existsSync(resolve(consumer, 'node_modules', devOnly)), `Library dev dependency leaked: ${devOnly}`);
}
for (const singleton of ['react', 'react-native', 'expo', 'expo-modules-core']) {
  const locations = Object.keys(lock.packages).filter(key => key === `node_modules/${singleton}` || key.endsWith(`/node_modules/${singleton}`));
  assert.deepEqual(locations, [`node_modules/${singleton}`], `Duplicate ${singleton} installation`);
  assert.equal(createRequire(resolve(installed, 'package.json')).resolve(`${singleton}/package.json`), require.resolve(`${singleton}/package.json`));
}
assert.equal(require('expo/package.json').version, '57.0.12');
assert.equal(require('react-native/package.json').version, '0.86.2');
assert.equal(typeof require('expo-cloudkit/transport').createTransportSession, 'function');
assert.ok(!require.cache[require.resolve('expo-cloudkit')], 'Transport imported legacy entry');

// Audit every compiled JS/declaration reference in the actual installed archive, not just files[].
const ts = require('typescript');
const declared = { ...packed.dependencies, ...packed.peerDependencies };
const tsOptions = { moduleResolution: ts.ModuleResolutionKind.Node10, allowJs: true };
for (const file of files(installed).filter(file => /\.(js|ts)$/.test(file))) {
  const source = ts.createSourceFile(file, readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  function check(specifier) {
    if (!specifier.startsWith('.')) {
      const name = specifier.startsWith('@') ? specifier.split('/').slice(0, 2).join('/') : specifier.split('/')[0];
      if (builtinModules.includes(specifier) || specifier.startsWith('node:')) return;
      assert.ok(declared[name], `Undeclared runtime/type dependency ${specifier} in ${relative(installed, file)}`);
      if (packed.peerDependenciesMeta?.[name]?.optional) return;
    }
    const resolved = file.endsWith('.d.ts')
      ? ts.resolveModuleName(specifier, file, tsOptions, ts.sys).resolvedModule?.resolvedFileName
      : createRequire(file).resolve(specifier);
    assert.ok(resolved && existsSync(resolved), `Unresolved ${specifier} in ${file}`);
    assert.ok(inside(consumer, realpathSync(resolved)), `Reference escaped consumer: ${resolved}`);
  }
  function visit(node) {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) check(node.moduleSpecifier.text);
    if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument) && ts.isStringLiteral(node.argument.literal)) check(node.argument.literal.text);
    if (ts.isCallExpression(node) && (node.expression.kind === ts.SyntaxKind.ImportKeyword || (ts.isIdentifier(node.expression) && node.expression.text === 'require')) && node.arguments.length === 1 && ts.isStringLiteral(node.arguments[0])) check(node.arguments[0].text);
    ts.forEachChild(node, visit);
  }
  visit(source);
}
assert.ok(existsSync(require.resolve(`expo-cloudkit/${packed.main}`)));
assert.ok(existsSync(require.resolve(`expo-cloudkit/${packed.types}`)));
const metadata = require('expo-cloudkit/expo-module.config.json');
assert.ok(existsSync(resolve(installed, metadata.apple.podspecPath)));
assert.ok(existsSync(require.resolve(`expo-cloudkit/${metadata.plugin}`)));
for (const module of ['ExpoCloudKitModule', 'ExpoCloudKitTransportModule']) {
  assert.ok(metadata.apple.modules.includes(module));
  assert.ok(existsSync(resolve(installed, 'ios', `${module}.swift`)));
}
// Exercise real declarations with the existing transport app and real plugin through Expo CLI.
run(process.execPath, [require.resolve('typescript/bin/tsc'), '--noEmit']);
const expo = require.resolve('expo/bin/cli');
run(process.execPath, [expo, 'install', '--check']);
const config = JSON.parse(run(process.execPath, [expo, 'config', '--type', 'introspect', '--json'], true));
save(resolve(consumer, 'config-introspection.json'), config);
const entitlements = config._internal?.modResults?.ios?.entitlements;
assert.ok(entitlements?.['com.apple.developer.icloud-container-identifiers']?.includes(env.CLOUDKIT_CONTAINER_ID), 'Installed config plugin did not produce container entitlement');
assert.deepEqual(entitlements['com.apple.developer.icloud-services'], ['CloudKit']);
const autolinking = JSON.parse(run(process.execPath, [require.resolve('expo/bin/autolinking'), 'resolve', '--platform', 'apple', '--json'], true));
save(resolve(consumer, 'autolinking.json'), autolinking);
const native = autolinking.modules.find(module => module.packageName === 'expo-cloudkit');
assert.ok(native, 'iOS autolinking missed expo-cloudkit');
for (const name of ['ExpoCloudKitModule', 'ExpoCloudKitTransportModule']) {
  assert.ok(native.modules.some(module => module.class === name), `Autolinking missed ${name}`);
}
assert.ok(native.pods.some(pod => pod.podName === 'ExpoCloudKit' && realpathSync(pod.podspecDir) === realpathSync(installed)), 'Autolinking must select installed podspec');
run(process.execPath, [expo, 'export', '--platform', 'ios', '--source-maps', '--no-bytecode', '--max-workers', '2', '--output-dir', 'dist']);
const sources = [];
function collect(map) {
  sources.push(...(map.sources || []));
  for (const section of map.sections || []) collect(section.map);
}
for (const file of files(resolve(consumer, 'dist')).filter(file => file.endsWith('.map'))) collect(json(file));
const normalized = sources.map(source => source.replaceAll('\\', '/'));
assert.ok(normalized.some(source => source.endsWith('/expo-cloudkit/build/transport.js')), 'iOS export omitted transport');
assert.ok(!normalized.some(source => /\/expo-cloudkit\/(?:build\/)?(?:index|ExpoCloudKit(?:\.native|\.web|\.android)?|hooks|CloudKitProvider)\.js$/.test(source)), 'iOS export pulled in legacy high-level entry');
for (const singleton of ['react', 'react-native', 'expo', 'expo-modules-core']) {
  const roots = new Set(normalized.flatMap(source => {
    const marker = `/node_modules/${singleton}/`;
    const index = source.lastIndexOf(marker);
    return index < 0 ? [] : [source.slice(0, index + marker.length)];
  }));
  assert.equal(roots.size, 1, `iOS export must contain exactly one ${singleton} copy: ${[...roots]}`);
}
assert.ok(!normalized.some(source => source.includes(root.replaceAll('\\', '/'))), 'Export resolved source from checkout');
console.log(`PASS: ${packed.name}@${packed.version} installed without hooks/dev dependencies; JS/declarations, plugin, autolinking and isolated iOS export verified at ${consumer}`);
