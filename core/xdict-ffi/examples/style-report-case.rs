//! The on-demand style-report parity case (`style-report-parity.sh`; owner, 2026-10-17): writes one dictionary with
//! the test suite's own MDX writer into `<dir>` (`case.mdx`, `case.mdd`, `case.css`), opens it with the core directly
//! and writes the core's `reading_style` to `<dir>/expected.json`, the shape each binding's output is compared with.
//! Not part of `conformance/` or any default run.

use std::error::Error;
use std::fs;
use std::path::PathBuf;

use xdict_core::{Config, Core, Location, NoProgress, Opened, PROTOCOL, Package};
use xdict_mdx_writer::{Entry as W, Spec, write};

/// A page size, an `!important`, a colour, a line height, a family replaced, an icon face drawing Private Use Area
/// characters and a bundled phonetic face: something in every part of the report.
const SIDECAR: &str = concat!(
    "body{font-size:15px;margin:0;color:#333} .p{font-size:12px !important;line-height:20px;font-family:Arial} ",
    "@font-face{font-family:\"Case Phonetic\";src:url(cp.ttf)} .phon{font-family:\"Case Phonetic\"}"
);
const ICONS: &str = "@font-face{font-family:Ic;src:url(ic.woff)} .i::before{font-family:Ic;content:\"\\e900\"}";

fn main() -> Result<(), Box<dyn Error>> {
    let dir = PathBuf::from(std::env::args_os().nth(1).ok_or("usage: style-report-case <dir>")?);
    fs::create_dir_all(&dir)?;
    let record = concat!(
        r#"<link rel="stylesheet" href="case.css"><link rel="stylesheet" href="in/icons.css">"#,
        r#"<b>run</b> <span class="phon">/rʌn/</span> <span class="i"></span><p class="p">to move fast</p>"#
    );
    fs::write(dir.join("case.mdx"), write(&Spec::mdx(), &[W::text("run", record)])?)?;
    fs::write(dir.join("case.mdd"), write(&Spec::mdd(), &[W::bytes("\\in\\icons.css", ICONS.as_bytes())])?)?;
    fs::write(dir.join("case.css"), SIDECAR)?;
    let at = |name: &str| Location::Path { path: dir.join(name).to_string_lossy().into_owned() };
    let package = Package { mdx: at("case.mdx"), mdd: vec![at("case.mdd")], sidecars: vec![at("case.css")] };
    let core = Core::new(Config { client_protocol: PROTOCOL, ..Config::default() })?;
    core.import(package.clone(), &NoProgress)?;
    let Opened::Ready { dict, .. } = core.open(package)? else { return Err("the case did not open".into()) };
    let style = core.reading_style(dict)?;
    fs::write(dir.join("expected.json"), serde_json::to_vec_pretty(&style)?)?;
    Ok(())
}
