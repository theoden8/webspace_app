// The Linux jobs build in a Debian sid container, whose WPE WebKit is new
// enough for the plugin, and the install step fails rather than build
// against an older one (INTEG-002).
//
// A source gate (rung 5): a workflow is text, and the version check runs
// only in CI's container. What this holds is that every job building the
// Linux app uses that container and that toolchain, and that the toolchain
// installs the packages the plugin and Flutter's Linux build need and
// stops below WPE WebKit 2.50.

const test = require('node:test');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const workflow = YAML.parse(read('.github/workflows/build-and-test.yml'));
const action = YAML.parse(read('.github/actions/linux-toolchain/action.yml'));
const install = action.runs.steps.find((s) => /\bapt-get install\b/.test(s.run ?? ''));

const toolchainJobs = Object.entries(workflow.jobs).filter(([, job]) =>
  (job.steps ?? []).some((s) => s.uses === './.github/actions/linux-toolchain'));

const sidImage = /^debian:sid-(\d{8})-slim$/;
const imageOf = (job) => job.container?.image ?? job.container;

test('INTEG-002: the Linux build jobs run in a dated debian sid container', () => {
  assert.ok(toolchainJobs.length >= 1, 'some job builds with the Linux toolchain');
  for (const [name, job] of toolchainJobs) {
    assert.match(String(imageOf(job)), sidImage, `${name} builds in the sid container`);
  }
});

// The floating sid-slim tag moves past the apt snapshot the jobs install
// from, and then its packages are newer than any the snapshot offers, so
// the first apt-get install fails before checkout.
test('INTEG-002: no sid container image is newer than the apt snapshot', () => {
  const snapshot = /^(\d{8})T\d{6}Z$/.exec(workflow.env.DEBIAN_SNAPSHOT)?.[1];
  assert.ok(snapshot, 'DEBIAN_SNAPSHOT is a snapshot.debian.org timestamp');
  const sidJobs = Object.entries(workflow.jobs)
    .filter(([, job]) => String(imageOf(job) ?? '').startsWith('debian:sid'));
  assert.ok(sidJobs.length >= toolchainJobs.length);
  for (const [name, job] of sidJobs) {
    const date = sidImage.exec(String(imageOf(job)))?.[1];
    assert.ok(date, `${name} names a dated image, not the floating tag`);
    assert.ok(date <= snapshot, `${name}'s image ${date} is not after the snapshot ${snapshot}`);
  }
});

test('INTEG-002: the toolchain installs the WPE, GTK and support packages', () => {
  assert.ok(install, 'the toolchain has an apt-get install step');
  for (const pkg of [
    'libwpewebkit-2.0-dev', 'libwpebackend-fdo-1.0-dev', 'libwpe-1.0-dev',
    'libgtk-3-dev', 'liblzma-dev', 'libsecret-1-dev', 'libepoxy-dev',
  ]) {
    assert.match(install.run, new RegExp(`\\s${pkg.replace(/[.]/g, '\\.')}\\s`), `installs ${pkg}`);
  }
});

test('INTEG-002: the install fails below WPE WebKit 2.50', () => {
  assert.match(install.run, /wpe="\$\(pkg-config --modversion wpe-webkit-2\.0\)"/);
  assert.match(install.run,
    /dpkg --compare-versions "\$wpe" ge 2\.50\.0 \|\|\s*\{[^}]*exit 1; \}/,
    'a version below 2.50.0 stops the step');
});
