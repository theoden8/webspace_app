// The Linux containers install from one dated sid snapshot, so a transition
// in live sid cannot break every PR's install at once. Rung 5: a workflow is
// text, and no type says which archive apt reads.
const test = require('node:test');
const assert = require('node:assert/strict');
const YAML = require('yaml');
const { read } = require('./helpers/source');

const workflow = YAML.parse(read('.github/workflows/build-and-test.yml'));
const sidJobs = Object.entries(workflow.jobs)
  .filter(([, job]) => /^debian:sid/.test(job.container?.image ?? job.container ?? ''));

test('the snapshot is named once, as a full snapshot.debian.org timestamp', () => {
  assert.match(workflow.env.DEBIAN_SNAPSHOT, /^\d{8}T\d{6}Z$/);
  assert.ok(sidJobs.length >= 1, 'some job runs in a sid container');
});

for (const [name, job] of sidJobs) {
  test(`${name} writes the snapshot's sources before its first apt-get`, () => {
    const runs = job.steps.map((s) => s.run ?? '');
    const first = runs.findIndex((r) => /\bapt-get\b/.test(r));
    assert.ok(first >= 0, `${name} installs with apt`);
    const script = runs[first];
    const pin = script.indexOf('snapshot.debian.org/archive/debian/%s/');
    assert.ok(pin >= 0 && pin < script.search(/\bapt-get\b/),
      'the sources are rewritten before apt reads them');
    assert.match(script, /"\$DEBIAN_SNAPSHOT" >\/etc\/apt\/sources\.list\.d\/debian\.sources/);
    assert.equal(job.env?.DEBIAN_SNAPSHOT, undefined, 'no job names its own date');
  });
}
