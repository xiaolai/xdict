//! etymology-db: explicit ancestry only. A `group_derived_root` is a chain walked in `parent_position` order;
//! `has_root` links a term to its root and is never a chain step. Affixes, cognates, doublets and "related" rows
//! are not ancestry. English `*_with_root` rows give modern derivations.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::Emit;
use crate::error::{PackError, PackErrorKind, PackResult};
use crate::json::Value;
use crate::limits::{
    ETY_ANCESTRY, ETY_COLUMNS, ETY_DROPPED, ETY_ENGLISH, ETY_GROUP, ETY_ROOT, ETY_WITH_ROOT, MAX_ETYMOLOGY_BLOCK_ROWS,
    MAX_GRAPH_EDGES, MAX_GRAPH_NODES, lookup,
};
use crate::record::{FieldValue, RawRecord};
use crate::skips::{Skips, sample};
use crate::sources::Csv;
use crate::text::strip_gloss;

/// One etymology-db row, its columns in [`ETY_COLUMNS`] order.
#[derive(Debug, Clone)]
struct Row {
    line: u64,
    term_id: String,
    lang: String,
    term: String,
    reltype: String,
    rid: String,
    rlang: String,
    rterm: String,
    tag: String,
    parent: String,
    ppos: String,
}

/// One node's ancestry edges: the parent it comes from, and the relation of that edge.
type Edge = (Box<str>, Box<str>);

/// Every node's ancestry edges, by child.
type Parents = BTreeMap<Box<str>, BTreeSet<Edge>>;

/// The ancestry graph parsed from etymology-db: node ids are `ety:<term_id>`.
#[derive(Debug, Default)]
pub struct EtymologyGraph {
    nodes: BTreeMap<Box<str>, (Box<str>, Box<str>)>,
    heads: BTreeMap<Box<str>, Box<str>>,
    parents: Parents,
    derivations: Vec<RawRecord>,
    skips: Skips,
    /// Distinct edges, kept as a counter so the bound costs one comparison rather than a walk.
    edges: u64,
}

impl EtymologyGraph {
    fn skip(&mut self, reason: &str, row: Option<&Row>) {
        let held = row.map(|row| sample(vec![("line", Value::Int(row.line)), ("word", Value::str(row.term.clone()))]));
        self.skips.record(reason, held);
    }

    fn node(&mut self, node: &str, language: &str, form: &str) {
        let value = (Box::from(language), Box::from(form));
        match self.nodes.get_mut(node) {
            Some(current) if value < *current => *current = value,
            Some(_) => {}
            None => {
                self.nodes.insert(Box::from(node), value);
            }
        }
    }

    fn edge(&mut self, child: &str, parent: &str, relation: &str) {
        if child == parent {
            self.skip("self-edge", None);
            return;
        }
        if self.parents.entry(Box::from(child)).or_default().insert((Box::from(parent), Box::from(relation))) {
            self.edges += 1;
        }
    }

    /// `bound` when the graph is past what one build may hold (plan-local-word-pack decision 4).
    fn within_bounds(&self) -> PackResult<()> {
        let nodes = self.nodes.len() as u64;
        if nodes > MAX_GRAPH_NODES || self.edges > MAX_GRAPH_EDGES {
            return Err(PackError::new(
                PackErrorKind::Bound,
                format!(
                    "the ancestry graph holds {nodes} nodes and {} edges, over {MAX_GRAPH_NODES} and {MAX_GRAPH_EDGES}",
                    self.edges
                ),
            ));
        }
        Ok(())
    }

    /// The rows skipped while parsing, by reason.
    pub fn skips(&self) -> &Skips {
        &self.skips
    }

    /// How many ancestry nodes the graph holds.
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    /// How many distinct edges the graph holds.
    pub fn edge_count(&self) -> u64 {
        self.edges
    }
}

/// etymology-db CSV text to an [`EtymologyGraph`] of explicit ancestry.
///
/// Rows come in contiguous blocks per `term_id`; a row's `parent_tag` must name a group of its own block. An
/// unknown `reltype` fails after the whole file is read, with every unknown type and its count.
pub fn parse_etymology_csv<R: Read>(reader: R, source: &str, cancel: &AtomicBool) -> PackResult<EtymologyGraph> {
    let mut csv = Csv::new(reader, source);
    let mut graph = EtymologyGraph::default();
    let mut unknown: BTreeMap<String, u64> = BTreeMap::new();
    let Some(header) = csv.next_record()? else {
        return Err(PackError::at(PackErrorKind::Malformed, source, 1, "empty file"));
    };
    let mut sorted_header = header.fields.clone();
    sorted_header.sort();
    let mut expected: Vec<String> = ETY_COLUMNS.iter().map(|name| (*name).to_string()).collect();
    expected.sort();
    if sorted_header != expected {
        return Err(PackError::at(
            PackErrorKind::Version,
            source,
            1,
            format!("unexpected columns {:?}", header.fields),
        ));
    }
    let mut order: Vec<usize> = Vec::with_capacity(ETY_COLUMNS.len());
    for name in ETY_COLUMNS {
        let Some(at) = header.fields.iter().position(|column| column == name) else {
            return Err(PackError::at(PackErrorKind::Version, source, 1, "an expected column is missing"));
        };
        order.push(at);
    }
    let mut block: Vec<Row> = Vec::new();
    let mut seen: u64 = 0;
    while let Some(record) = csv.next_record()? {
        seen += 1;
        if seen.is_multiple_of(65_536) && cancel.load(Ordering::Relaxed) {
            return Err(PackError::new(PackErrorKind::Cancelled, "the build was cancelled"));
        }
        if record.fields.len() != ETY_COLUMNS.len() {
            return Err(PackError::at(
                PackErrorKind::Malformed,
                source,
                record.line,
                format!("{} fields, expected {}", record.fields.len(), ETY_COLUMNS.len()),
            ));
        }
        let column = |index: usize| -> String {
            order.get(index).and_then(|at| record.fields.get(*at)).cloned().unwrap_or_default()
        };
        let row = Row {
            line: record.line,
            term_id: column(0),
            lang: column(1),
            term: column(2),
            reltype: column(3),
            rid: column(4),
            rlang: column(5),
            rterm: column(6),
            tag: column(8),
            parent: column(9),
            ppos: column(10),
        };
        let starts_a_block = block.first().is_some_and(|first| first.term_id != row.term_id);
        if starts_a_block {
            let done = std::mem::take(&mut block);
            ety_block(&done, &mut graph, source, &mut unknown)?;
            graph.within_bounds()?;
        }
        block.push(row);
        // A block is one term's rows; one that never ends is not a file this reader will hold while it finds out.
        if block.len() > MAX_ETYMOLOGY_BLOCK_ROWS {
            return Err(PackError::at(
                PackErrorKind::Bound,
                source,
                seen,
                format!("a term block over {MAX_ETYMOLOGY_BLOCK_ROWS} rows"),
            ));
        }
        if seen.is_multiple_of(4_096) {
            graph.within_bounds()?;
        }
    }
    if !block.is_empty() {
        ety_block(&block, &mut graph, source, &mut unknown)?;
    }
    graph.within_bounds()?;
    if !unknown.is_empty() {
        let listed = unknown.iter().map(|(name, count)| format!("{name} ({count})")).collect::<Vec<_>>().join(", ");
        return Err(PackError::at_source(PackErrorKind::Version, source, format!("unknown relation types: {listed}")));
    }
    Ok(graph)
}

fn ancestry(reltype: &str) -> Option<&'static str> {
    lookup(&ETY_ANCESTRY, reltype)
}

fn ety_block(
    rows: &[Row],
    graph: &mut EtymologyGraph,
    source: &str,
    unknown: &mut BTreeMap<String, u64>,
) -> PackResult<()> {
    let malformed = |line: u64, message: String| PackError::at(PackErrorKind::Malformed, source, line, message);
    let Some(first) = rows.first() else { return Ok(()) };
    let head = format!("ety:{}", first.term_id);
    let mut groups: BTreeMap<&str, usize> = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        let known = ancestry(&row.reltype).is_some()
            || ETY_ROOT.contains(&row.reltype.as_str())
            || ETY_WITH_ROOT.contains(&row.reltype.as_str());
        let grouped = ETY_GROUP.contains(&row.reltype.as_str());
        if !(known || grouped || ETY_DROPPED.contains(&row.reltype.as_str())) {
            *unknown.entry(row.reltype.clone()).or_insert(0) += 1;
        }
        if grouped {
            if row.tag.is_empty() {
                return Err(malformed(row.line, "a group row without group_tag".to_string()));
            }
            if groups.contains_key(row.tag.as_str()) {
                return Err(malformed(row.line, format!("group {} declared twice", row.tag)));
            }
            groups.insert(row.tag.as_str(), index);
        }
    }
    let mut top: Vec<usize> = Vec::new();
    let mut children: BTreeMap<usize, Vec<(i64, u64, usize)>> = BTreeMap::new();
    for (index, row) in rows.iter().enumerate() {
        if row.parent.is_empty() {
            top.push(index);
            continue;
        }
        let Some(group) = groups.get(row.parent.as_str()).copied() else {
            return Err(malformed(
                row.line,
                format!("parent_tag {} names no group of term {}", row.parent, row.term_id),
            ));
        };
        let position = row
            .ppos
            .trim()
            .parse::<i64>()
            .map_err(|_| malformed(row.line, format!("parent_position '{}'", row.ppos)))?;
        children.entry(group).or_default().push((position, row.line, index));
    }
    for list in children.values_mut() {
        list.sort();
    }
    if first.lang.is_empty() || first.term.trim().is_empty() {
        graph.skip("term without language or form", Some(first));
        return Ok(());
    }
    if first.lang == ETY_ENGLISH {
        graph.heads.insert(Box::from(head.as_str()), Box::from(first.term.as_str()));
    }
    graph.node(&head, &first.lang, &first.term);
    let mut walk = Walk { rows, children: &children, graph, source, head: &head };
    walk.walk(&top, false)
}

/// One block's ancestry walk: the rows it steps through, the groups they hang from, and the graph they build.
struct Walk<'a> {
    rows: &'a [Row],
    children: &'a BTreeMap<usize, Vec<(i64, u64, usize)>>,
    graph: &'a mut EtymologyGraph,
    source: &'a str,
    head: &'a str,
}

impl Walk<'_> {
    fn walk(&mut self, items: &[usize], chain: bool) -> PackResult<()> {
        let mut previous: Vec<String> = vec![self.head.to_string()];
        for index in items {
            let rows = self.rows;
            let Some(row) = rows.get(*index) else { continue };
            if self.side(row)? {
                continue;
            }
            let mut step: Vec<(String, &'static str)> = Vec::new();
            let mut is_step = false;
            if let Some(relation) = ancestry(&row.reltype) {
                is_step = true;
                if let Some(target) = self.target(row)? {
                    step.push((target, relation));
                }
            } else if row.reltype == "group_related_root" {
                let (members, had_ancestry) = self.members(*index)?;
                step = members;
                is_step = had_ancestry;
            } else if row.reltype == "group_derived_root" {
                if !chain {
                    let inner = self.children_of(*index);
                    self.walk(&inner, true)?;
                    continue;
                }
                self.graph.skip("group_derived_root inside group_derived_root", Some(row));
                is_step = true;
            } else if row.reltype == "group_affix_root" {
                for at in self.children_of(*index) {
                    if let Some(child) = rows.get(at) {
                        self.side(child)?;
                    }
                }
                continue;
            }
            if step.is_empty() {
                if chain && is_step {
                    // Never join the steps either side of one that gave nothing: that edge would be invented.
                    self.graph.skip("ancestry chain broken at a skipped step", Some(row));
                    previous.clear();
                }
                continue;
            }
            for parent in &previous {
                for (node, relation) in &step {
                    self.graph.edge(parent, node, relation);
                }
            }
            if chain {
                previous = step.iter().map(|(node, _)| node.clone()).collect();
            }
        }
        Ok(())
    }

    fn children_of(&self, group: usize) -> Vec<usize> {
        self.children.get(&group).map(|list| list.iter().map(|(_, _, at)| *at).collect()).unwrap_or_default()
    }

    /// Handle a row that is never a chain step; whether it was one of those.
    fn side(&mut self, row: &Row) -> PackResult<bool> {
        if ETY_ROOT.contains(&row.reltype.as_str()) {
            if let Some(target) = self.target(row)? {
                let head = self.head.to_string();
                self.graph.edge(&head, &target, "root");
            }
            return Ok(true);
        }
        if ETY_WITH_ROOT.contains(&row.reltype.as_str()) {
            let base = strip_gloss(row.rterm.trim());
            if row.lang == ETY_ENGLISH && row.rlang == ETY_ENGLISH && !base.is_empty() && base != row.term {
                self.graph.derivations.push(RawRecord::new(
                    "derivation",
                    vec![
                        ("base", RawRecord::text(base)),
                        ("derived", RawRecord::text(row.term.clone())),
                        ("kind", RawRecord::text("other")),
                        ("source", RawRecord::text(self.source)),
                    ],
                ));
            }
            return Ok(true);
        }
        Ok(false)
    }

    fn target(&mut self, row: &Row) -> PackResult<Option<String>> {
        let form = strip_gloss(row.rterm.trim());
        if row.rid.is_empty() || form.is_empty() || row.rlang.is_empty() {
            self.graph.skip("ancestry row without related id, language or form", Some(row));
            return Ok(None);
        }
        let node = format!("ety:{}", row.rid);
        self.graph.node(&node, &row.rlang, form);
        Ok(Some(node))
    }

    /// A related group's alternatives, and whether it had any ancestry child at all.
    fn members(&mut self, group: usize) -> PackResult<(Vec<(String, &'static str)>, bool)> {
        let list = self.children_of(group);
        let mut members = Vec::new();
        let mut had_ancestry = false;
        for at in list {
            let rows = self.rows;
            let Some(child) = rows.get(at) else { continue };
            if self.side(child)? {
                continue;
            }
            if let Some(relation) = ancestry(&child.reltype) {
                had_ancestry = true;
                if let Some(target) = self.target(child)? {
                    members.push((target, relation));
                }
            } else if ETY_GROUP.contains(&child.reltype.as_str()) {
                let reason = format!("{} inside group_related_root", child.reltype);
                self.graph.skip(&reason, Some(child));
            }
        }
        Ok((members, had_ancestry))
    }
}

/// The graph as origin and etymon records, kept to what English heads reach within `max_depth` edges, plus the
/// graph's derivation records. `uncertain` is false: etymology-db carries no uncertainty.
pub fn etymology_records(graph: &EtymologyGraph, source: &str, max_depth: u32, emit: Emit<'_>) -> PackResult<()> {
    let mut depth: BTreeMap<&str, u32> = BTreeMap::new();
    let mut frontier: Vec<&str> =
        graph.heads.keys().map(|head| &**head).filter(|head| graph.parents.contains_key(*head)).collect();
    frontier.sort_unstable();
    for head in &frontier {
        depth.insert(head, 0);
    }
    let empty: BTreeSet<Edge> = BTreeSet::new();
    let mut level = 0u32;
    while !frontier.is_empty() && level < max_depth {
        let mut following: Vec<&str> = Vec::new();
        for child in &frontier {
            let edges = graph.parents.get(*child).unwrap_or(&empty);
            for (parent, relation) in edges {
                emit(RawRecord::new(
                    "etymon",
                    vec![
                        ("child", RawRecord::text(*child)),
                        ("parent", RawRecord::text(&**parent)),
                        ("relation", RawRecord::text(&**relation)),
                        ("uncertain", FieldValue::Bool(false)),
                        ("source", RawRecord::text(source)),
                    ],
                ))?;
                if !depth.contains_key(&**parent) {
                    depth.insert(&**parent, level + 1);
                    following.push(&**parent);
                }
            }
        }
        following.sort_unstable();
        frontier = following;
        level += 1;
    }
    for node in depth.keys() {
        let Some((language, form)) = graph.nodes.get(*node) else { continue };
        let mut fields = vec![
            ("id", RawRecord::text(*node)),
            ("language", RawRecord::text(&**language)),
            ("form", RawRecord::text(&**form)),
        ];
        if let Some(word) = graph.heads.get(*node) {
            fields.push(("word", RawRecord::text(&**word)));
        }
        emit(RawRecord::new("origin", fields))?;
    }
    for record in &graph.derivations {
        emit(record.clone())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::indexing_slicing)]

    use super::*;
    use crate::limits::MAX_DEPTH;
    use crate::record::validate_record;
    use std::sync::atomic::AtomicBool;

    const HEADER: &str = "term_id,lang,term,reltype,related_term_id,related_lang,related_term,position,group_tag,parent_tag,parent_position\n";

    /// One row, its eleven columns named so a fixture cannot miscount them.
    fn row(fields: [&str; 11]) -> String {
        format!("{}\n", fields.join(","))
    }

    fn graph(rows: &[String]) -> PackResult<EtymologyGraph> {
        let text = format!("{HEADER}{}", rows.concat());
        parse_etymology_csv(text.as_bytes(), "ety", &AtomicBool::new(false))
    }

    fn records(graph: &EtymologyGraph) -> Vec<String> {
        let mut out = Vec::new();
        {
            let mut emit = |record: RawRecord| {
                out.push(validate_record(&record).unwrap().line());
                Ok(())
            };
            etymology_records(graph, "ety", MAX_DEPTH, &mut emit).unwrap();
        }
        let mut seen: Vec<String> = out;
        seen.sort();
        seen.dedup();
        seen
    }

    #[test]
    fn an_ancestry_row_makes_an_etymon_and_both_origins() {
        let rows =
            vec![row(["a1", "English", "father", "inherited_from", "b1", "Old English", "fæder", "0", "", "", ""])];
        let lines = records(&graph(&rows).unwrap());
        assert!(lines.iter().any(|line| line
            == r#"{"child":"ety:a1","parent":"ety:b1","relation":"inherited","source":"ety","type":"etymon","uncertain":false}"#));
        assert!(lines.iter().any(|line| line.contains(r#""id":"ety:a1""#) && line.contains(r#""word":"father""#)));
        assert!(
            lines.iter().any(|line| line.contains(r#""id":"ety:b1""#) && line.contains(r#""language":"Old English""#))
        );
    }

    #[test]
    fn has_root_is_an_edge_and_never_a_chain_step() {
        let rows = vec![
            row(["a1", "English", "father", "group_derived_root", "", "", "", "0", "G1", "", ""]),
            row(["a1", "English", "father", "has_root", "r1", "Proto-Germanic", "*fader", "0", "", "G1", "0"]),
            row(["a1", "English", "father", "inherited_from", "b1", "Old English", "fæder", "0", "", "G1", "1"]),
        ];
        let lines = records(&graph(&rows).unwrap());
        assert!(
            lines.iter().any(|line| line.contains(r#""relation":"root""#) && line.contains(r#""parent":"ety:r1""#))
        );
        assert!(
            lines
                .iter()
                .any(|line| line.contains(r#""parent":"ety:b1""#) && line.contains(r#""relation":"inherited""#))
        );
    }

    #[test]
    fn a_broken_chain_joins_nothing_across_the_gap() {
        let rows = vec![
            row(["a1", "English", "word", "group_derived_root", "", "", "", "0", "G1", "", ""]),
            row(["a1", "English", "word", "inherited_from", "b1", "Old English", "x", "0", "", "G1", "0"]),
            row(["a1", "English", "word", "inherited_from", "", "", "", "0", "", "G1", "1"]),
            row(["a1", "English", "word", "inherited_from", "b2", "Latin", "y", "0", "", "G1", "2"]),
        ];
        let parsed = graph(&rows).unwrap();
        let lines = records(&parsed);
        assert!(lines.iter().any(|line| line.contains(r#""parent":"ety:b1""#)));
        assert!(!lines.iter().any(|line| line.contains(r#""parent":"ety:b2""#)), "no edge may cross the break");
        assert_eq!(parsed.skips().counts().get("ancestry chain broken at a skipped step"), Some(&1));
    }

    #[test]
    fn a_chain_joins_its_steps_in_parent_position_order() {
        let rows = vec![
            row(["a1", "English", "word", "group_derived_root", "", "", "", "0", "G1", "", ""]),
            row(["a1", "English", "word", "inherited_from", "b2", "Latin", "y", "0", "", "G1", "1"]),
            row(["a1", "English", "word", "inherited_from", "b1", "Old English", "x", "0", "", "G1", "0"]),
        ];
        let parsed = graph(&rows).unwrap();
        let lines = records(&parsed);
        assert!(lines.iter().any(|line| line.contains(r#""child":"ety:a1","parent":"ety:b1""#)));
        assert!(lines.iter().any(|line| line.contains(r#""child":"ety:b1","parent":"ety:b2""#)));
    }

    #[test]
    fn an_unknown_relation_type_fails_the_build_naming_it() {
        let rows = vec![row(["a1", "English", "word", "frobnicated_from", "b1", "Latin", "y", "0", "", "", ""])];
        let error = graph(&rows).unwrap_err();
        assert_eq!(error.kind(), PackErrorKind::Version);
        assert!(error.to_string().contains("unknown relation types: frobnicated_from (1)"), "{error}");
    }

    #[test]
    fn a_self_edge_is_skipped_and_counted() {
        let rows = vec![row(["a1", "English", "word", "inherited_from", "a1", "English", "word", "0", "", "", ""])];
        let parsed = graph(&rows).unwrap();
        assert!(records(&parsed).iter().all(|line| !line.contains(r#""type":"etymon""#)));
        assert_eq!(parsed.skips().counts().get("self-edge"), Some(&1));
    }

    #[test]
    fn a_with_root_row_gives_a_modern_derivation() {
        let rows = vec![
            row(["a1", "English", "unhelpful", "has_prefix_with_root", "", "", "", "0", "", "", ""]),
            row([
                "a1",
                "English",
                "unhelpful",
                "has_prefix_with_root",
                "b1",
                "English",
                "helpful (full of help)",
                "0",
                "",
                "",
                "",
            ]),
        ];
        let lines = records(&graph(&rows).unwrap());
        assert!(
            lines.iter().any(|line| line
                == r#"{"base":"helpful","derived":"unhelpful","kind":"other","source":"ety","type":"derivation"}"#),
            "{lines:?}"
        );
    }

    #[test]
    fn a_term_without_a_language_gives_no_head() {
        let rows = vec![row(["a1", "", "word", "inherited_from", "b1", "Latin", "y", "0", "", "", ""])];
        let parsed = graph(&rows).unwrap();
        assert_eq!(parsed.skips().counts().get("term without language or form"), Some(&1));
        assert_eq!(parsed.node_count(), 0);
    }

    #[test]
    fn a_parent_tag_naming_no_group_is_refused() {
        let rows = vec![
            row(["a1", "English", "word", "inherited_from", "", "", "", "0", "", "", ""]),
            row(["a1", "English", "word", "inherited_from", "b1", "Latin", "y", "0", "", "nope", "0"]),
        ];
        assert!(graph(&rows).unwrap_err().to_string().contains("names no group of term a1"));
    }
}
