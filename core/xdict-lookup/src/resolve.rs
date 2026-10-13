//! What a query finds in one file (ADR-0007 decisions 7 and 9): the keys it matches, tier by tier, and where
//! their redirects lead.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};

use xdict_mdx::{Budget, Error, File};

/// Which matching a lookup uses.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// What a reader typed: both tiers, public keys only.
    Reader,
    /// What a link or a redirect named: tier 1 only, internal keys included.
    Link,
}

/// Why a key matched.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum How {
    /// Spelt as asked.
    Exact,
    /// Equal under the file's own rules (tier 1).
    Folded,
    /// Equal once marks a reader cannot type are removed (tier 2).
    Unmarked,
    /// Reached through `@@@LINK=`: the key numbers passed through, the matched key first.
    Redirect { chain: Vec<usize> },
}

/// What stopped a redirect short. Data, not an error: real files have every one (`core-api.md` finding 10).
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Problem {
    /// `from` names `target`, which no key matches.
    Dangling { from: usize, target: String },
    /// The chain came back to a key already on it.
    Loop { chain: Vec<usize> },
    /// The chain went past [`HOPS`], or one key's redirects past [`FAN_OUT`] keys.
    Limit { chain: Vec<usize> },
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Hit {
    pub key: usize,
    pub how: How,
    /// Problems met on the way to this hit's key from the key that matched.
    pub problems: Vec<Problem>,
}

/// One file's answer: hits in order, and the problems of matched keys that led to no hit.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Resolved {
    pub hits: Vec<Hit>,
    pub problems: Vec<Problem>,
}

/// Redirects followed from one key: at most this many hops (the 25 need four)…
pub const HOPS: usize = 8;
/// …and this many keys landed on in all (a target may name a key many records share).
pub const FAN_OUT: usize = 1024;

/// The keys `query` matches, in order: tier 1 (exact spellings, then folded, each in file order), then, for a
/// reader, tier 2 (in file order). A reader is never given an internal key.
pub fn matches(file: &File, query: &str, mode: Mode) -> Result<Vec<(usize, How)>, Error> {
    let mut found = Vec::new();
    let mut seen = HashSet::new();
    for i in file.find(query)? {
        if mode == Mode::Link || file.is_public(i)? {
            let how = if file.key(i)? == query { How::Exact } else { How::Folded };
            found.push((i, how));
        }
        seen.insert(i);
    }
    if mode == Mode::Reader {
        let plain = file.unmark(query);
        let mut tier2 = file.find_unmarked(query)?;
        if plain != query {
            tier2.extend(file.find(&plain)?);
        }
        tier2.sort_unstable();
        tier2.dedup();
        for i in tier2 {
            if !seen.contains(&i) && file.is_public(i)? {
                found.push((i, How::Unmarked));
            }
        }
    }
    Ok(found)
}

/// Every hit `query` leads to in `file`: each matched key that is an entry, and every entry its redirects reach,
/// breadth first, in the matched key's place. A key reached twice is given once, by its shortest way; a matched
/// key that is an entry is never given again as a redirect's. Every record read is taken from `budget`.
pub fn resolve(file: &File, query: &str, mode: Mode, budget: &mut Budget) -> Result<Resolved, Error> {
    let matched = matches(file, query, mode)?;
    let keys: Vec<usize> = matched.iter().map(|(i, _)| *i).collect();
    let targets = redirects(file, &keys, budget)?;
    let entries: HashSet<usize> = keys.iter().copied().filter(|i| targets.get(i).is_none_or(Vec::is_empty)).collect();
    let mut resolved = Resolved::default();
    let mut placed: HashMap<usize, usize> = HashMap::new();
    for (i, how) in matched {
        let Some(named) = targets.get(&i).filter(|t| !t.is_empty()) else {
            if let Entry::Vacant(slot) = placed.entry(i) {
                slot.insert(resolved.hits.len());
                resolved.hits.push(Hit { key: i, how, problems: vec![] });
            }
            continue;
        };
        let Followed { reached, problems } = follow(file, i, named, budget)?;
        let mut gave = Vec::new();
        for (j, chain) in reached {
            if entries.contains(&j) {
                continue;
            }
            match placed.get(&j).and_then(|&at| resolved.hits.get_mut(at)) {
                Some(hit) => {
                    if let How::Redirect { chain: kept } = &hit.how
                        && chain.len() < kept.len()
                    {
                        hit.how = How::Redirect { chain };
                    }
                }
                None => {
                    placed.insert(j, resolved.hits.len());
                    gave.push(resolved.hits.len());
                    resolved.hits.push(Hit { key: j, how: How::Redirect { chain }, problems: vec![] });
                }
            }
        }
        if gave.is_empty() {
            resolved.problems.extend(problems);
        } else {
            for at in gave {
                if let Some(hit) = resolved.hits.get_mut(at) {
                    hit.problems.clone_from(&problems);
                }
            }
        }
    }
    Ok(resolved)
}

/// Where one key's redirects lead.
struct Followed {
    /// Each entry reached, once, with its chain: the key followed from first.
    reached: Vec<(usize, Vec<usize>)>,
    /// What stopped any way short.
    problems: Vec<Problem>,
}

/// The entries key `from`'s redirects (`named`) reach, breadth first. A loop is caught along each chain, not
/// across them: two ways to one key are not a loop.
fn follow(file: &File, from: usize, named: &[String], budget: &mut Budget) -> Result<Followed, Error> {
    let mut queue: VecDeque<(String, Vec<usize>)> = named.iter().map(|t| (t.clone(), vec![from])).collect();
    let (mut reached, mut problems, mut landed_in_all) = (Vec::new(), Vec::new(), 0usize);
    let mut given = HashSet::new();
    while let Some((target, chain)) = queue.pop_front() {
        if chain.len() > HOPS {
            problems.push(Problem::Limit { chain });
            continue;
        }
        let landed = file.find(&target)?;
        let last = chain.last().copied().unwrap_or(from);
        if landed.is_empty() {
            problems.push(Problem::Dangling { from: last, target });
            continue;
        }
        landed_in_all += landed.len();
        if landed_in_all > FAN_OUT {
            problems.push(Problem::Limit { chain });
            break;
        }
        let onward = redirects(file, &landed, budget)?;
        for j in landed {
            let mut next = chain.clone();
            next.push(j);
            if chain.contains(&j) {
                problems.push(Problem::Loop { chain: next });
                continue;
            }
            match onward.get(&j).filter(|t| !t.is_empty()) {
                Some(targets) => queue.extend(targets.iter().map(|t| (t.clone(), next.clone()))),
                None => {
                    if given.insert(j) {
                        reached.push((j, next));
                    }
                }
            }
        }
    }
    Ok(Followed { reached, problems })
}

/// For each of `keys`, the targets its record names if it is a redirect, or none: every block read once.
fn redirects(file: &File, keys: &[usize], budget: &mut Budget) -> Result<HashMap<usize, Vec<String>>, Error> {
    let mut targets = HashMap::with_capacity(keys.len());
    file.for_each_record(keys, budget, |i, record| {
        targets.insert(i, redirect_targets(&String::from_utf8_lossy(&record.data)));
        Ok(())
    })?;
    Ok(targets)
}

/// The targets of an `@@@LINK=` record, one per line that names one; none for an entry.
pub fn redirect_targets(text: &str) -> Vec<String> {
    if !text.trim_start().starts_with("@@@LINK=") {
        return Vec::new();
    }
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("@@@LINK="))
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Each key of `keys`' occurrence: its place among the keys spelt exactly as it is, in file order.
pub fn occurrences(file: &File, keys: &[usize]) -> Result<HashMap<usize, u32>, Error> {
    let mut texts: HashMap<String, Vec<usize>> = HashMap::new();
    for &i in keys {
        texts.entry(file.key(i)?.into_owned()).or_default().push(i);
    }
    let mut out = HashMap::with_capacity(keys.len());
    for text in texts.keys() {
        let mut n = 0u32;
        for i in file.find(text)? {
            if file.key(i)? == text.as_str() {
                out.insert(i, n);
                n += 1;
            }
        }
    }
    Ok(out)
}

/// Public keys beginning with `prefix` under the file's folding, in folded order, each spelling once, added to
/// `out` until it holds `limit`.
pub fn suggest(file: &File, prefix: &str, limit: usize, out: &mut Vec<String>) -> Result<(), Error> {
    let mut given: HashSet<String> = out.iter().cloned().collect();
    file.prefixed(prefix, |i| {
        if out.len() >= limit {
            return Ok(false);
        }
        if file.is_public(i)? {
            let key = file.key(i)?.into_owned();
            if given.insert(key.clone()) {
                out.push(key);
            }
        }
        Ok(out.len() < limit)
    })
}
