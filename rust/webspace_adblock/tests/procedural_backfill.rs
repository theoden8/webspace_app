// Pins the upstream-crate behaviour the Dart-side procedural-rule
// backfill relies on (see lib/services/procedural_action_backfill.dart).
//
// If adblock-rust ever:
//   * stops rejecting generic procedural rules at parse time, OR
//   * changes the JSON shape of procedural_actions, OR
//   * changes which actions it recognises
// the assertions here flip and we know to revisit the backfill
// strategy. Without these, an upgrade would silently restore the
// gap and we'd re-discover it via user-visible regressions.
//
// Run with: cargo test --test procedural_backfill

use adblock::Engine;
use adblock::lists::{FilterSet, ParseOptions};

fn engine(rules: &str) -> Engine {
    let mut set = FilterSet::new(false);
    set.add_filter_list(rules, ParseOptions::default());
    Engine::from_filter_set(set, false)
}

fn procedurals(eng: &Engine, url: &str) -> Vec<String> {
    let mut v: Vec<String> = eng
        .url_cosmetic_resources(url)
        .procedural_actions
        .into_iter()
        .collect();
    v.sort();
    v
}

fn hides(eng: &Engine, url: &str) -> Vec<String> {
    let mut v: Vec<String> = eng
        .url_cosmetic_resources(url)
        .hide_selectors
        .into_iter()
        .collect();
    v.sort();
    v
}

/// The premise of the backfill: adblock-rust drops generic procedural
/// rules. If this ever flips to "kept", we should retire the backfill.
#[test]
fn generic_procedural_rules_are_dropped_at_parse_time() {
    for rule in [
        "##.foo:remove()",
        "##.foo:remove-attr(data-x)",
        "##.foo:remove-class(adsbygoogle)",
        "##.foo:style(height: 1px)",
        "##.foo:has-text(X):remove()",
    ] {
        let eng = engine(rule);
        let proc = procedurals(&eng, "https://example.com/");
        let hide = hides(&eng, "https://example.com/");
        let classes = eng.hidden_class_id_selectors(
            std::iter::once("foo"),
            std::iter::empty::<&str>(),
            &std::collections::HashSet::new(),
        );
        assert!(
            proc.is_empty() && hide.is_empty() && classes.is_empty(),
            "rule {:?} unexpectedly surfaced via some path — \
             procedural={:?} hide={:?} class={:?}",
            rule, proc, hide, classes,
        );
    }
}

/// Prefixing a generic rule with a synthetic hostname bypasses the
/// parse-time rejection and surfaces the rule via the normal
/// domain-scoped procedural_actions path. This is the load-bearing
/// behaviour our Dart-side rewriter depends on.
#[test]
fn synthetic_host_prefix_recovers_generic_procedurals() {
    // The Dart side uses `localhost` — keep these in sync.
    let synth = "localhost";
    let rule = format!("{}##.foo:remove()", synth);
    let eng = engine(&rule);

    let on_synth = procedurals(&eng, &format!("https://{}/", synth));
    assert_eq!(on_synth.len(), 1, "expected one procedural for {}", synth);
    let json = &on_synth[0];

    // Shape match — Dart side decodes this with the same JSON shape
    // that ContentBlockerService already consumes for domain-scoped
    // procedurals returned by url_cosmetic_resources.
    assert!(json.contains("\"type\":\"css-selector\""), "got: {}", json);
    assert!(json.contains("\".foo\""), "got: {}", json);
    assert!(json.contains("\"action\":{\"type\":\"remove\"}") ||
            json.contains("\"action\":\"remove\""), "got: {}", json);

    // Isolation: querying a different host must not return our
    // synthetic-anchored rule.
    let on_other = procedurals(&eng, "https://example.com/");
    assert!(on_other.is_empty(), "synth rule leaked to example.com: {:?}", on_other);
}

/// All four action shapes the backfill rewrites round-trip correctly.
#[test]
fn synthetic_host_supports_every_action_shape() {
    let synth = "localhost";
    let rules = [
        ("remove",       format!("{}##.r:remove()", synth)),
        ("remove-attr",  format!("{}##.ra:remove-attr(data-x)", synth)),
        ("remove-class", format!("{}##.rc:remove-class(adsbygoogle)", synth)),
        ("style",        format!("{}##.s:style(height: 1px)", synth)),
    ];
    for (label, rule) in &rules {
        let eng = engine(rule);
        let proc = procedurals(&eng, &format!("https://{}/", synth));
        assert_eq!(proc.len(), 1, "{} produced {} procedurals: {:?}", label, proc.len(), proc);
        assert!(proc[0].contains(label), "{} action not in payload: {}", label, proc[0]);
    }
}

/// Domain-scoped procedurals (`example.com##.foo:remove()`) already
/// work without the backfill — guard against accidentally regressing
/// that path with our rewrite. Test using a real-looking domain that
/// passes through unchanged.
#[test]
fn domain_scoped_procedurals_still_work_unrewritten() {
    let rule = "example.com##.dom-proc:remove()";
    let eng = engine(rule);
    let proc = procedurals(&eng, "https://example.com/");
    assert_eq!(proc.len(), 1, "expected one procedural for example.com");
    assert!(proc[0].contains(".dom-proc"), "got: {}", proc[0]);
}

/// Filter-pseudo rules WITHOUT an action (`##.foo:has-text(X)`) are
/// default-hide in uBO syntax. The Dart rewriter wraps them with
/// `:style(display: none !important)` so the crate stores them as a
/// procedural style action; otherwise the crate stores the selector
/// as a hide selector with the procedural pseudo embedded inside,
/// which then can't be matched as plain CSS.
#[test]
fn filter_pseudo_with_synthetic_hide_action_routes_to_procedural() {
    let synth = "localhost";
    // The Dart-side rewriter normalizes :contains() / :-abp-contains()
    // to :has-text() and :-abp-has() to native :has() before reaching
    // adblock-rust, because the crate's css-validation rejects the
    // ABP-syntax aliases. The test feeds the post-normalization form
    // so it asserts what the engine actually sees.
    let rules = [
        (":has-text",      format!("{}##.fp_ht:has-text(SponsoredX):style(display: none !important)", synth)),
        (":upward",        format!("{}##.fp_up:has-text(MARKER):upward(1):style(display: none !important)", synth)),
    ];
    for (label, rule) in &rules {
        let eng = engine(rule);
        let proc = procedurals(&eng, &format!("https://{}/", synth));
        assert_eq!(proc.len(), 1,
                   "{}: expected one procedural, got {:?}", label, proc);
        assert!(proc[0].contains("\"action\":{\"type\":\"style\""),
                "{}: expected style action in payload, got {}", label, proc[0]);
        assert!(proc[0].contains("display: none"),
                "{}: expected display:none in style arg, got {}", label, proc[0]);
    }
}
