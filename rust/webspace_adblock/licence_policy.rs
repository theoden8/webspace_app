// LICENSE-001 for the crates this library links. Each crate's licence
// expression is held to openspec/specs/legal/licences.tsv, the table
// test/js/licence_policy.test.js holds every other component to. This
// reading of the table is held to licence_cases.tsv on every build, the
// cases the JavaScript reading is held to, so the two cannot drift apart.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// How a component ships: linked in or beside the app, or only as a
/// shared library the user can replace.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Ships {
    Linked,
    Shared,
}

impl Ships {
    fn parse(text: &str, at: &Path) -> Ships {
        match text.trim() {
            "linked" => Ships::Linked,
            "shared" => Ships::Shared,
            other => panic!("{}: `{other}` is neither linked nor shared", at.display()),
        }
    }
}

struct Licence {
    ships: Ships,
    only: Option<Vec<String>>,
}

pub struct Policy {
    licences: HashMap<String, Licence>,
}

fn rows(text: &str) -> impl Iterator<Item = Vec<&str>> {
    text.lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|l| l.split('\t').collect())
}

fn read(path: &Path) -> String {
    println!("cargo:rerun-if-changed={}", path.display());
    fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn legal(name: &str) -> PathBuf {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set");
    Path::new(&manifest).join("../../openspec/specs/legal").join(name)
}

impl Policy {
    /// The policy as licences.tsv states it, after this reading of it gave
    /// every case its stated verdict.
    pub fn checked() -> Policy {
        let at = legal("licences.tsv");
        let text = read(&at);
        let mut licences = HashMap::new();
        for cols in rows(&text) {
            let only = cols
                .get(2)
                .map(|s| s.split_whitespace().map(String::from).collect::<Vec<_>>())
                .filter(|o| !o.is_empty());
            let ships = Ships::parse(cols.get(1).copied().unwrap_or(""), &at);
            licences.insert(cols[0].trim().to_string(), Licence { ships, only });
        }
        let policy = Policy { licences };
        policy.hold_to_cases(&legal("licence_cases.tsv"));
        policy
    }

    fn hold_to_cases(&self, at: &Path) {
        let text = read(at);
        let mut wrong = Vec::new();
        for cols in rows(&text) {
            let [expression, ships, component, verdict] = cols[..] else {
                panic!("{}: a case is four columns: {cols:?}", at.display());
            };
            let want = match verdict.trim() {
                "allowed" => true,
                "refused" => false,
                other => panic!("{}: `{other}` is neither allowed nor refused", at.display()),
            };
            if self.allows(expression, Ships::parse(ships, at), component.trim()) != want {
                wrong.push(format!("{expression} {ships} {component}: {verdict}"));
            }
        }
        assert!(
            wrong.is_empty(),
            "licence_policy.rs reads {} otherwise than {} states: {wrong:?}",
            legal("licences.tsv").display(),
            at.display()
        );
    }

    /// Whether [expression] lets [component] ship as [ships]: some
    /// alternative of every OR whose terms are all allowed.
    pub fn allows(&self, expression: &str, ships: Ships, component: &str) -> bool {
        let tokens: Vec<String> = expression
            .replace('/', " OR ")
            .replace('(', " ( ")
            .replace(')', " ) ")
            .split_whitespace()
            .map(String::from)
            .collect();
        if tokens.is_empty() {
            return false;
        }
        let mut p = Parser { tokens: &tokens, at: 0, policy: self, ships, component };
        let v = p.or();
        p.at == tokens.len() && v
    }
}

struct Parser<'a> {
    tokens: &'a [String],
    at: usize,
    policy: &'a Policy,
    ships: Ships,
    component: &'a str,
}

impl Parser<'_> {
    fn next_is(&self, token: &str) -> bool {
        self.tokens.get(self.at).is_some_and(|t| t == token)
    }

    fn leaf(&mut self) -> bool {
        let Some(id) = self.tokens.get(self.at) else { return false };
        let mut id = id.clone();
        self.at += 1;
        if self.next_is("WITH") {
            id = format!("{id} WITH {}", self.tokens.get(self.at + 1).map_or("", String::as_str));
            self.at += 2;
        }
        match self.policy.licences.get(&id) {
            Some(l) if l.only.as_ref().is_none_or(|o| o.iter().any(|c| c == self.component)) => {
                l.ships == Ships::Linked || self.ships == Ships::Shared
            }
            _ => false,
        }
    }

    fn factor(&mut self) -> bool {
        if !self.next_is("(") {
            return self.leaf();
        }
        self.at += 1;
        let v = self.or();
        self.at += 1;
        v
    }

    fn and(&mut self) -> bool {
        let mut v = self.factor();
        while self.next_is("AND") {
            self.at += 1;
            v = self.factor() && v;
        }
        v
    }

    fn or(&mut self) -> bool {
        let mut v = self.and();
        while self.next_is("OR") {
            self.at += 1;
            v = self.and() || v;
        }
        v
    }
}

/// The ids of the packages the library links: the crates its normal
/// dependencies reach from the root, not its build or dev dependencies.
pub fn linked(metadata: &serde_json::Value) -> std::collections::HashSet<String> {
    let resolve = &metadata["resolve"];
    let nodes: HashMap<&str, &serde_json::Value> = resolve["nodes"]
        .as_array()
        .expect("cargo metadata has no resolve graph")
        .iter()
        .filter_map(|n| Some((n["id"].as_str()?, n)))
        .collect();
    let mut out = std::collections::HashSet::new();
    let mut stack = vec![resolve["root"].as_str().expect("cargo metadata names no root").to_string()];
    while let Some(id) = stack.pop() {
        if !out.insert(id.clone()) {
            continue;
        }
        for dep in nodes[id.as_str()]["deps"].as_array().into_iter().flatten() {
            let normal = dep["dep_kinds"]
                .as_array()
                .is_some_and(|kinds| kinds.iter().any(|k| k["kind"].is_null()));
            if let (true, Some(pkg)) = (normal, dep["pkg"].as_str()) {
                stack.push(pkg.to_string());
            }
        }
    }
    out
}

const GNU_HEADINGS: [&str; 6] = [
    "gnu general public license version 2 june 1991",
    "gnu general public license version 3 29 june 2007",
    "gnu library general public license version 2 june 1991",
    "gnu lesser general public license version 2 1 february 1999",
    "gnu lesser general public license version 3 29 june 2007",
    "gnu affero general public license version 3 19 november 2007",
];

/// The files under [dir] that carry a GNU licence's heading or notice, a
/// crate's label notwithstanding; its tests, benches and examples are not
/// compiled in and are not read.
pub fn gnu_text_in(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        let Ok(entries) = fs::read_dir(&at) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if path.is_dir() {
                if !matches!(name.as_str(), "tests" | "benches" | "examples" | "target" | ".git") {
                    stack.push(path);
                }
                continue;
            }
            let Ok(bytes) = fs::read(&path) else { continue };
            let head = &bytes[..bytes.len().min(1 << 16)];
            if head[..head.len().min(8000)].contains(&0) {
                continue;
            }
            // Letters and digits only, so a notice split across comment
            // lines (`//`, ` *`, `#`) reads as one sentence.
            let text: String = String::from_utf8_lossy(head)
                .to_lowercase()
                .chars()
                .map(|c| if c.is_alphanumeric() { c } else { ' ' })
                .collect();
            let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
            let notice = text.contains("general public license")
                && text.contains("as published by the free software foundation");
            // A GNU licence's own heading carries its date; MPL-2.0 names
            // the same licences, undated, as its Secondary Licenses.
            let heading = GNU_HEADINGS.iter().any(|h| text.contains(h));
            if notice || heading {
                out.push(path.strip_prefix(dir).unwrap_or(&path).display().to_string());
            }
        }
    }
    out.sort();
    out
}
