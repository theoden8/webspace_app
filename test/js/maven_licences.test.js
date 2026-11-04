// LICENSE-001 over the Maven artifacts the Android build links: the build
// lists them with their POMs' licences (android/app/maven_licences.gradle),
// CI holds them to the policy after the build (tool/check_maven_licences.js),
// and each rule here is caught on the mistake it is for. Rung 5 for the
// wiring: which Gradle files and CI steps run is text no type sees.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');
const M = require('../../tool/check_maven_licences');

const art = (group, artifact, ...licences) => ({ group, artifact, version: '1.0', licences });
const apache = { name: 'The Apache Software License, Version 2.0', url: 'http://www.apache.org/licenses/LICENSE-2.0.txt' };

test('LICENSE-001 a Maven artifact under the GPL is refused, its Classpath exception only for desugar_jdk_libs', () => {
  const classpath = { name: 'GNU General Public License, version 2, with the Classpath Exception', url: '' };
  assert.deepEqual(M.refusals([
    art('androidx.core', 'core', apache),
    art('com.android.tools', 'desugar_jdk_libs', classpath),
    art('org.example', 'shim', classpath),
    art('org.example', 'gpl', { name: 'GNU General Public License v3.0', url: '' }),
    art('org.example', 'lgpl', { name: 'GNU Lesser General Public License', url: '' }),
    art('org.example', 'dual', apache, { name: 'Eclipse Public License 2.0', url: '' }),
  ]), [
    'org.example:shim:1.0: GPL-2.0-only WITH Classpath-exception-2.0',
    'org.example:gpl:1.0: GPL',
    'org.example:lgpl:1.0: LGPL',
    'org.example:dual:1.0: Apache-2.0 AND EPL',
  ]);
});

test('LICENSE-001 a POM licence no row reads, or none, is refused until read by hand', () => {
  assert.deepEqual(M.refusals([
    art('org.example', 'odd', { name: 'Some Custom Terms', url: '' }),
    art('org.example', 'bare'),
  ]), [
    `org.example:odd:1.0: Some Custom Terms is a licence ${M.PATTERNS} does not read`,
    `org.example:bare:1.0: its POM names no licence; read it by hand into ${M.PATTERNS}`,
  ]);
  const rows = M.table('gradle:org.example:bare\tMIT\tits README, which the POM omits\n\\bmit\\b\tMIT\n');
  assert.deepEqual(M.refusals([art('org.example', 'bare')], { rows }), [], 'an artifact read by hand');
});

test('LICENSE-001 the Android build lists what it links and CI holds it to the policy', () => {
  assert.match(read('android/app/build.gradle'), /^apply from: 'maven_licences\.gradle'$/m,
    'android/app/build.gradle does not apply maven_licences.gradle');
  const script = read('android/app/maven_licences.gradle');
  assert.match(script, /'ReleaseRuntimeClasspath'/, 'the script does not read the release runtime classpaths');
  assert.match(script, /rootProject\.file\('\.\.\/assets\/native_notices\/maven\.json'\)/,
    'the script writes the list somewhere pubspec.yaml does not bundle');
  assert.match(script, /it\.name\.startsWith\('compileFlutterBuild'\)[\s\S]*dependsOn mavenLicences/,
    'Flutter could bundle the assets before the list is written');
  const workflow = read('.github/workflows/build-and-test.yml');
  const build = workflow.indexOf('flutter build apk --release --flavor fdroid');
  const check = workflow.indexOf('node tool/check_maven_licences.js assets/native_notices/maven.json');
  assert.ok(build >= 0 && check > build, 'CI does not check the list after it builds the APK');
});
