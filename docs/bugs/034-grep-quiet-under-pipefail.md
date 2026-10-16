# BUG-034 — A match reads as a miss when a script pipes into `grep -q`

Status: closed

**Gate:** [test/js/shell_grep_quiet_pipe.test.js](../../test/js/shell_grep_quiet_pipe.test.js)

## Symptom

A CI check that found what it looked for reports that it did not: a planted
mistake TLC caught reads as missed (`activation_recapture.cfg did not
produce expected outcome`), a method present in the dex reads as missing.
It passes locally and fails on the runner, or the other way round, from one
run to the next.

## Root mechanism

`writer | grep -q pattern` under `set -o pipefail`, which every script here
sets, and GitHub sets for a step that names `shell: bash`. `grep -q` exits at its first match; once the
writer's output passes the pipe buffer (64 KiB on Linux), its next write
gets SIGPIPE and it exits 141. `pipefail` makes that the pipeline's status,
so `if` takes the branch for no match. It only happens when the output is
long and the match comes early, which is why it looks like a flake: a TLC
counterexample through four flows, a logcat dump, an APK listing. A
here-string (`grep -q pattern <<<"$out"`) has no writer to kill, and in an
`sh` script, which has no here-string, `writer | grep pattern >/dev/null`
reads the whole input instead of stopping at the first match.

## Fix attempts

1. **2026-07-25, 5bf1cad6 (#516).** `formal/proofs/check_proofs.sh` captures
   tlapm's output and matches it afterwards, with a comment naming the
   SIGPIPE. *Why:* tlapm's output was long enough to trip it. *Why partial:*
   fixed the one script it was seen in; `formal/check.sh` kept the pattern.
2. **2026-10-08, e1cae3ec (#680).** `scripts/check_jni_intact.sh` matches a
   here-string, with the same comment. *Why:* the dex listing tripped it.
   *Why partial:* again one script; every other site kept the pattern.
3. **2026-10-11, PR #696.** Every site under `formal/`, `scripts/`, `tool/`
   and the workflow matches a here-string, and a gate fails on any pipe
   into `grep -q` or `grep --quiet`. *Why:* `formal/check.sh` reported the
   `recapture` mutant uncaught on CI once its counterexample grew past the
   buffer. *Why partial:* it put a here-string in a workflow step that runs
   in the Linux job's container, where an unnamed shell is `sh -e` (dash),
   and the step died on `Syntax error: redirection unexpected`.
4. **2026-10-11, PR #696.** That step reads the whole input
   (`| grep '^sec' >/dev/null`), and `test/js/workflow_shell_syntax.test.js`
   now parses every `run:` block with the shell that runs it (its own
   `shell`, the job's or workflow's default, else `sh` in a container job
   and `bash` on the runner), so a bash-only form in an `sh` step fails
   there, not when the step runs. *Why:* attempt 3's fix was itself only
   checked by the runner. This closes the class: a pipe into `grep -q`
   fails the grep gate, and a fix in the wrong shell fails the parse gate.

## Known open gaps

None for `grep -q`. Any reader that stops early has the same shape
(`head -1`, `grep -m1` feeding nothing after it); the gate does not look
for those.
