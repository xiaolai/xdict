//! What a query finds in one file (ADR-0007 decisions 7 and 9): the keys it matches, tier by tier, and where
//! their redirects lead.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet, VecDeque};

use xdict_mdx::{Budget, Error, File, Kept};

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
    /// Problems met by the walk from the matched key that reached this hit, given once: with the first hit
    /// the walk reaches, and empty on its others.
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
/// …and this many keys landed on in all (a target may name a key many records share), and this many targets
/// tried: each costs a search, and one record may name thousands.
pub const FAN_OUT: usize = 1024;
/// Targets one lookup tries in all, over every matched key: past it the lookup is refused, as too large.
pub const STEPS: usize = 1 << 16;

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
/// key that is an entry is never given again as a redirect's. Every record read is taken from `budget`, and
/// every target tried counts against [`STEPS`].
pub fn resolve(file: &File, query: &str, mode: Mode, budget: &mut Budget) -> Result<Resolved, Error> {
    let matched = matches(file, query, mode)?;
    let keys: Vec<usize> = matched.iter().map(|(i, _)| *i).collect();
    let mut read = Read::default();
    read.add(file, &keys, budget)?;
    let entries: HashSet<usize> = keys.iter().copied().filter(|i| !read.is_redirect(*i)).collect();
    let mut resolved = Resolved::default();
    let mut placed: HashMap<usize, usize> = HashMap::new();
    // The matched key each redirect hit came by (its chain's first), and each such key's problems: a hit carries
    // its own way's, decided once every way is known, since a later, shorter way replaces an earlier one.
    let mut owner: HashMap<usize, usize> = HashMap::new();
    let mut ways: Vec<(usize, Vec<Problem>)> = Vec::new();
    let mut steps = 0usize;
    for (i, how) in matched {
        let Some(named) = read.targets(i).map(<[String]>::to_vec) else {
            if let Entry::Vacant(slot) = placed.entry(i) {
                slot.insert(resolved.hits.len());
                resolved.hits.push(Hit { key: i, how, problems: vec![] });
            }
            continue;
        };
        let Followed { reached, problems } = follow(file, i, &named, budget, &mut read, &mut steps)?;
        for (j, chain) in reached {
            if entries.contains(&j) {
                continue;
            }
            match placed.get(&j).copied() {
                Some(at) => {
                    if let Some(hit) = resolved.hits.get_mut(at)
                        && let How::Redirect { chain: kept } = &hit.how
                        && chain.len() < kept.len()
                    {
                        hit.how = How::Redirect { chain };
                        owner.insert(at, i);
                    }
                }
                None => {
                    placed.insert(j, resolved.hits.len());
                    owner.insert(resolved.hits.len(), i);
                    resolved.hits.push(Hit { key: j, how: How::Redirect { chain }, problems: vec![] });
                }
            }
        }
        ways.push((i, problems));
    }
    // Each walk's problems, moved once: to the first hit it finally owns, or, owning none, to the lookup's.
    let mut first: HashMap<usize, usize> = HashMap::new();
    for (&at, &from) in &owner {
        first.entry(from).and_modify(|kept| *kept = (*kept).min(at)).or_insert(at);
    }
    for (i, problems) in ways {
        match first.get(&i).and_then(|&at| resolved.hits.get_mut(at)) {
            Some(hit) => hit.problems = problems,
            None => resolved.problems.extend(problems),
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
/// across them: two ways to one key are not a loop. At most [`FAN_OUT`] targets are tried, each counted in
/// `steps`; the queue never holds more than could still be tried. Records come from `read`, the lookup's, and
/// a key already on the chain is a loop before it is read.
fn follow(
    file: &File,
    from: usize,
    named: &[String],
    budget: &mut Budget,
    read: &mut Read,
    steps: &mut usize,
) -> Result<Followed, Error> {
    let mut walk = Walk::new(from, named);
    while let Some((target, chain)) = walk.queue.pop_front() {
        let chain = match walk.admit(chain, steps)? {
            Flow::Go(chain) => chain,
            Flow::Skip => continue,
            Flow::Stop => break,
        };
        let landed = land(file, &target)?;
        let landed = match walk.count(target, &chain, landed) {
            Flow::Go(landed) => landed,
            Flow::Skip => continue,
            Flow::Stop => break,
        };
        let fresh: Vec<usize> = landed.iter().copied().filter(|j| !chain.contains(j)).collect();
        read.add(file, &fresh, budget)?;
        for j in landed {
            walk.arrive(j, &chain, read);
        }
    }
    Ok(walk.out)
}

/// What the walk does with a target: go on with it, pass to the next, or stop following the key.
enum Flow<T> {
    Go(T),
    Skip,
    Stop,
}

/// One key's redirects being followed: what is still to try, and what has been found.
struct Walk {
    from: usize,
    queue: VecDeque<(String, Vec<usize>)>,
    /// Targets taken from the queue, and keys landed on, against [`FAN_OUT`].
    tried: usize,
    landed: usize,
    /// Entries already reached, each given once.
    given: HashSet<usize>,
    out: Followed,
}

impl Walk {
    fn new(from: usize, named: &[String]) -> Self {
        let mut walk = Self {
            from,
            queue: named.iter().take(FAN_OUT + 1).map(|t| (t.clone(), vec![from])).collect(),
            tried: 0,
            landed: 0,
            given: HashSet::new(),
            out: Followed { reached: Vec::new(), problems: Vec::new() },
        };
        walk.nowhere(from, named);
        walk
    }

    /// A redirect naming no target leads nowhere: a dangling redirect, its target empty.
    fn nowhere(&mut self, from: usize, named: &[String]) {
        if named.is_empty() {
            self.out.problems.push(Problem::Dangling { from, target: String::new() });
        }
    }

    /// The limits on trying one more target: this key's [`FAN_OUT`] stops the walk, the lookup's [`STEPS`]
    /// refuses the lookup, and a chain past [`HOPS`] is given up alone.
    fn admit(&mut self, chain: Vec<usize>, steps: &mut usize) -> Result<Flow<Vec<usize>>, Error> {
        self.tried += 1;
        if self.tried > FAN_OUT {
            self.out.problems.push(Problem::Limit { chain });
            return Ok(Flow::Stop);
        }
        *steps += 1;
        if *steps > STEPS {
            return Err(Error::TooLarge(format!("the redirects of one lookup name more than {STEPS} targets")));
        }
        if chain.len() > HOPS {
            self.out.problems.push(Problem::Limit { chain });
            return Ok(Flow::Skip);
        }
        Ok(Flow::Go(chain))
    }

    /// The keys `target` landed on, counted: none is a dangling target, and past [`FAN_OUT`] in all the walk
    /// stops.
    fn count(&mut self, target: String, chain: &[usize], landed: Vec<usize>) -> Flow<Vec<usize>> {
        if landed.is_empty() {
            let from = chain.last().copied().unwrap_or(self.from);
            self.out.problems.push(Problem::Dangling { from, target });
            return Flow::Skip;
        }
        self.landed += landed.len();
        if self.landed > FAN_OUT {
            self.out.problems.push(Problem::Limit { chain: chain.to_vec() });
            return Flow::Stop;
        }
        Flow::Go(landed)
    }

    /// Key `j`, landed on along `chain`: a loop if the chain has it already, else its targets queued (no more
    /// than could still be tried) if it is a redirect, else an entry reached, given once.
    fn arrive(&mut self, j: usize, chain: &[usize], read: &Read) {
        let mut next = chain.to_vec();
        next.push(j);
        if chain.contains(&j) {
            self.out.problems.push(Problem::Loop { chain: next });
            return;
        }
        match read.targets(j) {
            Some(targets) => {
                self.nowhere(j, targets);
                let room = (FAN_OUT + 1).saturating_sub(self.tried + self.queue.len());
                self.queue.extend(targets.iter().take(room).map(|t| (t.clone(), next.clone())));
            }
            None => {
                if self.given.insert(j) {
                    self.out.reached.push((j, next));
                }
            }
        }
    }
}

/// The keys a redirect to `target` lands on: those spelt exactly as it is, where there are any (`find` gives
/// them first), else every key tier 1 finds for it.
fn land(file: &File, target: &str) -> Result<Vec<usize>, Error> {
    let mut found = file.find(target)?;
    let mut exact = 0;
    for &i in &found {
        if file.key(i)? != target {
            break;
        }
        exact += 1;
    }
    if exact > 0 {
        found.truncate(exact);
    }
    Ok(found)
}

/// What a record is to a lookup: `None` for an entry, else the targets its redirect names (perhaps none).
type Targets = Option<Vec<String>>;

/// Every record a lookup has read, by key, each read and taken from the budget once, and the blocks kept
/// between reads, so a block several targets share is decompressed once while it is kept.
#[derive(Default)]
struct Read {
    records: HashMap<usize, Targets>,
    kept: Kept,
}

impl Read {
    /// Reads, for each of `keys` not read yet, what its record is.
    fn add(&mut self, file: &File, keys: &[usize], budget: &mut Budget) -> Result<(), Error> {
        let mut unread: Vec<usize> = keys.iter().copied().filter(|i| !self.records.contains_key(i)).collect();
        unread.sort_unstable();
        unread.dedup();
        let records = &mut self.records;
        file.for_each_record_kept(&unread, budget, &mut self.kept, |i, record| {
            records.insert(i, targets(&String::from_utf8_lossy(&record.data)));
            Ok(())
        })
    }

    /// The targets of key `i`'s record, if it was read and is a redirect.
    fn targets(&self, i: usize) -> Option<&[String]> {
        self.records.get(&i).and_then(Option::as_deref)
    }

    fn is_redirect(&self, i: usize) -> bool {
        self.targets(i).is_some()
    }
}

/// The targets of an `@@@LINK=` record, one per line that names one, at most one more than [`FAN_OUT`] (no more
/// can be followed); none for an entry, or for a redirect that names nothing.
pub fn redirect_targets(text: &str) -> Vec<String> {
    targets(text).unwrap_or_default()
}

/// `None` for an entry; for an `@@@LINK=` record, the targets its lines name, which may be none.
fn targets(text: &str) -> Targets {
    if !text.trim_start().starts_with("@@@LINK=") {
        return None;
    }
    Some(
        text.lines()
            .filter_map(|line| line.trim().strip_prefix("@@@LINK="))
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .take(FAN_OUT + 1)
            .map(str::to_owned)
            .collect(),
    )
}

/// Each key of `keys`' occurrence: its place among the keys spelt exactly as it is, in file order.
pub fn occurrences(file: &File, keys: &[usize]) -> Result<HashMap<usize, u32>, Error> {
    let mut texts: HashSet<String> = HashSet::new();
    for &i in keys {
        texts.insert(file.key(i)?.into_owned());
    }
    let mut out = HashMap::with_capacity(keys.len());
    for text in &texts {
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
