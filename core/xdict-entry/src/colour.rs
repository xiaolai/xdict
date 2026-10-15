//! XDict owns the colours (ADR-0010; `dev-docs/reading-style.md` §1.3 and §4.2). Every colour a dictionary writes is
//! read in OKLCH and becomes one of the palette's tokens, with its light value as the fallback: hue is the
//! dictionary's meaning, tone is XDict's. The frame defines the tokens per theme, and every text token reads at 4.5:1
//! on every surface and tint of every theme (`palette.py`; [`tests`] checks the same here), so the core never needs
//! to know which background a text lands on.
//!
//! - **Foreground:** a neutral (C < 0.035) is `--xdict-text` (L < 0.45) or `--xdict-text-2`; near-white is text on a
//!   chip and becomes `--xdict-text`; otherwise its hue family, `-deep` when L < 0.5.
//! - **Background:** near-white neutral is `--xdict-panel` on a box and `transparent` elsewhere; another neutral is
//!   `--xdict-panel`; a chromatic colour is its family's `-tint`.
//! - **Mark** (border, outline, shadow): its family's foreground; a neutral is `--xdict-rule`.
//! - **Chip** (a rule that sets both): its text follows the background's family (`-deep`), or `--xdict-text`.
//!
//! [`SNAP_HUES`] is the owner's Q1: snap to the eight families (chosen 2026-10-15), or keep each colour's exact hue with
//! the token tier's lightness and chroma.

/// Q1: snap hues to the palette's families (`true`, the owner's answer) or keep the exact hue (`false`).
const SNAP_HUES: bool = true;
/// Monochrome text with one accent (the owner's "plain" option): every chromatic text colour becomes the accent,
/// `--xdict-blue` (the link colour), its tier kept. Off: each keeps its family.
const MONOCHROME: bool = false;
/// The accent family under [`MONOCHROME`]: blue.
const ACCENT: usize = 5;

/// What a colour is used for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Role {
    Text,
    /// A background; `boxed` when its rule draws a box (a border or padding), where near-white is a panel.
    Background {
        boxed: bool,
    },
    /// A border, rule or shadow. Unused while "Plain by default" drops every border inside an entry; kept for the
    /// borders R11 may restore.
    #[cfg_attr(not(test), expect(dead_code, reason = "Plain by default drops borders; R11 may restore some"))]
    Mark,
}

/// The palette's eight hue families: name, the hue range they take (OKLCH degrees, from the previous family's end),
/// and light `-deep` / plain / `-tint`, then dark, as `palette.json` gives them.
struct Family {
    name: &'static str,
    until: f64,
    light: [u32; 3],
    dark: [u32; 3],
}

const FAMILIES: [Family; 8] = [
    Family { name: "red", until: 45.0, light: [0x901114, 0xaf342f, 0xffebe8], dark: [0xfec9c2, 0xfb988d, 0x3e2724] },
    Family { name: "orange", until: 80.0, light: [0x773a00, 0x9b4e01, 0xffece0], dark: [0xffcba9, 0xf2a26a, 0x3c291d] },
    Family {
        name: "yellow",
        until: 110.0,
        light: [0x5c4c00, 0x796502, 0xf6f0da],
        dark: [0xecd78a, 0xcfb656, 0x332e19],
    },
    Family { name: "green", until: 170.0, light: [0x035e23, 0x047b30, 0xe3f6e5], dark: [0xaaeab2, 0x80cd8b, 0x223324] },
    Family { name: "teal", until: 215.0, light: [0x055959, 0x057575, 0xdaf7f6], dark: [0x81ecec, 0x3bcfcf, 0x163333] },
    Family { name: "blue", until: 280.0, light: [0x02489f, 0x2063bf, 0xe8f1fe], dark: [0xc0d9fe, 0x8ab9ff, 0x232e3f] },
    Family {
        name: "purple",
        until: 330.0,
        light: [0x622c91, 0x7c48ae, 0xf4ecff],
        dark: [0xe2ccfe, 0xc9a3f5, 0x32293c],
    },
    Family { name: "pink", until: 360.0, light: [0x881356, 0xa63470, 0xfeeaf2], dark: [0xfec5dc, 0xf297bf, 0x3c2730] },
];

/// The neutral tokens, light then dark: bg, panel, text, text-2, rule.
const NEUTRAL_LIGHT: [u32; 5] = [0xffffff, 0xf3f3f5, 0x1d1d1f, 0x636366, 0xd8d8dc];
#[cfg(test)]
const NEUTRAL_DARK: [u32; 5] = [0x1e1e1e, 0x2a2a2c, 0xe6e6e9, 0xa3a3a8, 0x3a3a3d];

/// A token: its name and its light value, the fallback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Token {
    Text,
    Text2,
    Panel,
    Rule,
    Transparent,
    /// A family (index into [`FAMILIES`]) at a tier: 0 deep, 1 plain, 2 tint.
    Hue(usize, usize),
}

/// An sRGB colour, each channel in [0, 1].
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Rgb {
    pub(crate) r: f64,
    pub(crate) g: f64,
    pub(crate) b: f64,
    pub(crate) a: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Lch {
    l: f64,
    c: f64,
    h: f64,
}

fn hex_rgb(hex: u32) -> Rgb {
    let byte = |s: u32| f64::from((hex >> s) & 0xff) / 255.0;
    Rgb { r: byte(16), g: byte(8), b: byte(0), a: 1.0 }
}

/// The family a hue (radians) falls in.
fn family(h: f64) -> usize {
    let degrees = h.to_degrees().rem_euclid(360.0);
    FAMILIES.iter().position(|f| degrees < f.until).unwrap_or(0)
}

/// `colour` made opaque over white: a translucent literal would let an unmapped background through.
fn opaque(colour: Rgb) -> Rgb {
    let mix = |c: f64| c * colour.a + (1.0 - colour.a);
    Rgb { r: mix(colour.r), g: mix(colour.g), b: mix(colour.b), a: 1.0 }
}

/// The token a colour takes in `role`; `chip` is the background its rule sets, when it sets one.
pub(crate) fn token(colour: Rgb, role: Role, chip: Option<Rgb>) -> Token {
    let lch = opaque(colour).lch();
    let neutral = lch.c < 0.035;
    match role {
        Role::Text => {
            if let Some(bg) = chip {
                match token(bg, Role::Background { boxed: false }, None) {
                    Token::Hue(f, _) => return Token::Hue(f, 0),
                    Token::Panel => return Token::Text,
                    _ => {}
                }
            }
            if lch.l >= 0.95 && lch.c < 0.03 {
                Token::Text
            } else if neutral {
                if lch.l < 0.45 { Token::Text } else { Token::Text2 }
            } else {
                let f = if MONOCHROME { ACCENT } else { family(lch.h) };
                Token::Hue(f, if lch.l < 0.5 { 0 } else { 1 })
            }
        }
        Role::Background { boxed } => {
            if lch.l >= 0.9 && lch.c < 0.02 {
                if boxed { Token::Panel } else { Token::Transparent }
            } else if neutral {
                Token::Panel
            } else {
                Token::Hue(family(lch.h), 2)
            }
        }
        Role::Mark if neutral => Token::Rule,
        Role::Mark => Token::Hue(family(lch.h), 1),
    }
}

impl Token {
    /// As CSS writes it: `var(--xdict-…, <light value>)`.
    pub(crate) fn css(self, colour: Rgb) -> String {
        let neutral =
            |name: &str, i: usize| format!("var(--xdict-{name}, #{:06x})", NEUTRAL_LIGHT.get(i).copied().unwrap_or(0));
        match self {
            Self::Text => neutral("text", 2),
            Self::Text2 => neutral("text-2", 3),
            Self::Panel => neutral("panel", 1),
            Self::Rule => neutral("rule", 4),
            Self::Transparent => "transparent".to_owned(),
            Self::Hue(f, tier) => {
                let Some(fam) = FAMILIES.get(f) else { return neutral("text", 2) };
                let light = fam.light.get(tier).copied().unwrap_or(0);
                if SNAP_HUES {
                    let suffix = ["-deep", "", "-tint"].get(tier).copied().unwrap_or("");
                    format!("var(--xdict-{}{suffix}, #{light:06x})", fam.name)
                } else {
                    // The exact hue, at the tier's lightness and chroma in each theme.
                    let h = opaque(colour).lch().h;
                    let tone = |hex: u32| {
                        let t = hex_rgb(hex).lch();
                        Lch { h, ..t }.fitted(1.0).hex()
                    };
                    let dark = fam.dark.get(tier).copied().unwrap_or(0);
                    format!("light-dark({}, {})", tone(light), tone(dark))
                }
            }
        }
    }
}

/// A colour as written, mapped for its role.
pub(crate) fn mapped(colour: Rgb, role: Role, chip: Option<Rgb>) -> String {
    token(colour, role, chip).css(colour)
}

fn to_linear(c: f64) -> f64 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

fn from_linear(c: f64) -> f64 {
    if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

impl Rgb {
    /// WCAG relative luminance.
    #[cfg(test)]
    pub(crate) fn luminance(self) -> f64 {
        0.2126 * to_linear(self.r) + 0.7152 * to_linear(self.g) + 0.0722 * to_linear(self.b)
    }

    fn lch(self) -> Lch {
        let (r, g, b) = (to_linear(self.r), to_linear(self.g), to_linear(self.b));
        let l = (0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b).cbrt();
        let m = (0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b).cbrt();
        let s = (0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b).cbrt();
        let ok_l = 0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s;
        let ok_a = 1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s;
        let ok_b = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s;
        Lch { l: ok_l, c: ok_a.hypot(ok_b), h: ok_b.atan2(ok_a) }
    }

    /// The colour as CSS writes it: `#rrggbb`, or `#rrggbbaa` when translucent.
    pub(crate) fn hex(self) -> String {
        let byte = |c: f64| (c.clamp(0.0, 1.0) * 255.0).round() as u8;
        if self.a < 1.0 {
            format!("#{:02x}{:02x}{:02x}{:02x}", byte(self.r), byte(self.g), byte(self.b), byte(self.a))
        } else {
            format!("#{:02x}{:02x}{:02x}", byte(self.r), byte(self.g), byte(self.b))
        }
    }
}

impl Lch {
    /// The sRGB colour, or `None` outside the gamut.
    fn rgb(self, a: f64) -> Option<Rgb> {
        let (ok_a, ok_b) = (self.c * self.h.cos(), self.c * self.h.sin());
        let l = (self.l + 0.396_337_777_4 * ok_a + 0.215_803_757_3 * ok_b).powi(3);
        let m = (self.l - 0.105_561_345_8 * ok_a - 0.063_854_172_8 * ok_b).powi(3);
        let s = (self.l - 0.089_484_177_5 * ok_a - 1.291_485_548 * ok_b).powi(3);
        let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s;
        let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s;
        let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s;
        let inside = |c: f64| (-1e-4..=1.0 + 1e-4).contains(&c);
        (inside(r) && inside(g) && inside(b)).then(|| Rgb {
            r: from_linear(r.clamp(0.0, 1.0)),
            g: from_linear(g.clamp(0.0, 1.0)),
            b: from_linear(b.clamp(0.0, 1.0)),
            a,
        })
    }

    /// The nearest colour in gamut with this lightness and hue: chroma reduced until it fits.
    fn fitted(self, a: f64) -> Rgb {
        if let Some(rgb) = self.rgb(a) {
            return rgb;
        }
        let (mut lo, mut hi) = (0.0, self.c);
        for _ in 0..24 {
            let mid = (lo + hi) / 2.0;
            if (Lch { c: mid, ..self }).rgb(a).is_some() { lo = mid } else { hi = mid }
        }
        let grey = self.l.clamp(0.0, 1.0);
        (Lch { c: lo, ..self }).rgb(a).unwrap_or(Rgb { r: grey, g: grey, b: grey, a })
    }
}

/// A colour literal at the start of `text`: the colour and how many bytes it takes. Hex, `rgb()`, `rgba()`,
/// `hsl()`, `hsla()` and the named colours.
pub(crate) fn literal(text: &str) -> Option<(Rgb, usize)> {
    if let Some(hex) = text.strip_prefix('#') {
        let len = hex.bytes().take_while(u8::is_ascii_hexdigit).count();
        let digits = hex.get(..len)?;
        let at = |i: usize, n: usize| u32::from_str_radix(digits.get(i..i + n)?, 16).ok();
        let (r, g, b, a) = match len {
            3 | 4 => {
                let one = |i| at(i, 1).map(|v| f64::from(v * 17) / 255.0);
                (one(0)?, one(1)?, one(2)?, if len == 4 { one(3)? } else { 1.0 })
            }
            6 | 8 => {
                let two = |i| at(i, 2).map(|v| f64::from(v) / 255.0);
                (two(0)?, two(2)?, two(4)?, if len == 8 { two(6)? } else { 1.0 })
            }
            _ => return None,
        };
        return Some((Rgb { r, g, b, a }, 1 + len));
    }
    let name_len = text.bytes().take_while(|b| b.is_ascii_alphabetic()).count();
    let name = text.get(..name_len)?.to_ascii_lowercase();
    if text.as_bytes().get(name_len) == Some(&b'(') {
        let window = text.get(name_len..)?;
        let window = window.get(..window.len().min(96)).unwrap_or(window);
        let close = window.find(')')? + name_len;
        let args = text.get(name_len + 1..close)?;
        let rgb = match name.as_str() {
            "rgb" | "rgba" => rgb_function(args)?,
            "hsl" | "hsla" => hsl_function(args)?,
            _ => return None,
        };
        return Some((rgb, close + 1));
    }
    let value = NAMED.iter().find(|(n, _)| *n == name)?.1;
    let byte = |shift: u32| f64::from((value >> shift) & 0xff) / 255.0;
    Some((Rgb { r: byte(16), g: byte(8), b: byte(0), a: 1.0 }, name_len))
}

/// A function's arguments: comma or space separated, an alpha after `/`.
fn arguments(args: &str) -> Vec<&str> {
    args.split([',', ' ', '/', '\t', '\n']).map(str::trim).filter(|a| !a.is_empty()).collect()
}

fn number(arg: &str, scale: f64) -> Option<f64> {
    let (n, percent) = match arg.strip_suffix('%') {
        Some(n) => (n, true),
        None => (arg, false),
    };
    let v: f64 = n.parse().ok().filter(|v: &f64| v.is_finite())?;
    Some(if percent { v / 100.0 } else { v / scale })
}

fn rgb_function(args: &str) -> Option<Rgb> {
    let a = arguments(args);
    if !(3..=4).contains(&a.len()) {
        return None;
    }
    let channel = |i: usize| a.get(i).and_then(|x| number(x, 255.0)).map(|v| v.clamp(0.0, 1.0));
    let alpha = if a.len() == 4 { channel_alpha(a.get(3)?)? } else { 1.0 };
    Some(Rgb { r: channel(0)?, g: channel(1)?, b: channel(2)?, a: alpha })
}

fn channel_alpha(arg: &str) -> Option<f64> {
    number(arg, 1.0).map(|v| v.clamp(0.0, 1.0))
}

fn hsl_function(args: &str) -> Option<Rgb> {
    let a = arguments(args);
    if !(3..=4).contains(&a.len()) {
        return None;
    }
    let hue = a.first()?.trim_end_matches("deg");
    let h: f64 = hue.parse().ok().filter(|v: &f64| v.is_finite())?;
    let s = number(a.get(1)?, 100.0)?.clamp(0.0, 1.0);
    let l = number(a.get(2)?, 100.0)?.clamp(0.0, 1.0);
    let alpha = if a.len() == 4 { channel_alpha(a.get(3)?)? } else { 1.0 };
    let k = |n: f64| (n + h.rem_euclid(360.0) / 30.0).rem_euclid(12.0);
    let f = |n: f64| l - s * l.min(1.0 - l) * (k(n) - 3.0).min(9.0 - k(n)).clamp(-1.0, 1.0);
    Some(Rgb { r: f(0.0), g: f(8.0), b: f(4.0), a: alpha })
}

/// A value with each colour literal in it mapped; `None` when it holds none. Strings, `url()`, `var()` and an
/// existing `light-dark()` are passed over whole.
pub(crate) fn map_value(value: &str, role: Role, chip: Option<Rgb>) -> Option<String> {
    let mut out = String::with_capacity(value.len());
    let mut copied = 0;
    let mut i = 0;
    let mut changed = false;
    let bytes = value.as_bytes();
    while let Some(&b) = bytes.get(i) {
        let rest = value.get(i..).unwrap_or("");
        match b {
            b'"' | b'\'' => {
                i += 1 + rest.get(1..).and_then(|r| r.find(char::from(b))).map_or(rest.len(), |e| e + 1);
                continue;
            }
            b'#' | b'a'..=b'z' | b'A'..=b'Z' => {
                let word = rest.bytes().take_while(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'_').count();
                let previous = i.checked_sub(1).and_then(|p| bytes.get(p)).copied().unwrap_or(b' ');
                let starts = b == b'#' || !(previous.is_ascii_alphanumeric() || previous == b'-' || previous == b'_');
                let name = rest.get(..word).unwrap_or("").to_ascii_lowercase();
                if starts
                    && rest.as_bytes().get(word) == Some(&b'(')
                    && !matches!(name.as_str(), "rgb" | "rgba" | "hsl" | "hsla")
                    && !name.ends_with("gradient")
                {
                    // Another function: passed over whole.
                    i += rest.find(')').map_or(rest.len(), |e| e + 1);
                    continue;
                }
                if starts
                    && let Some((colour, len)) = literal(rest)
                    && rest.as_bytes().get(len).is_none_or(|c| !(c.is_ascii_alphanumeric() || *c == b'-'))
                {
                    out.push_str(value.get(copied..i).unwrap_or(""));
                    out.push_str(&mapped(colour, role, chip));
                    i += len;
                    copied = i;
                    changed = true;
                    continue;
                }
                i += word.max(1);
            }
            _ => i += rest.chars().next().map_or(1, char::len_utf8),
        }
    }
    out.push_str(value.get(copied..).unwrap_or(""));
    changed.then_some(out)
}

/// The first colour literal in a value, for the background a rule paints.
pub(crate) fn first(value: &str) -> Option<Rgb> {
    let bytes = value.as_bytes();
    (0..bytes.len()).find_map(|i| {
        let previous = i.checked_sub(1).and_then(|p| bytes.get(p)).copied().unwrap_or(b' ');
        let b = *bytes.get(i)?;
        let starts = b == b'#' || (b.is_ascii_alphabetic() && !(previous.is_ascii_alphanumeric() || previous == b'-'));
        if !starts {
            return None;
        }
        let rest = value.get(i..)?;
        literal(rest)
            .filter(|(_, len)| rest.as_bytes().get(*len).is_none_or(|c| !c.is_ascii_alphanumeric()))
            .map(|(c, _)| c)
    })
}

/// CSS's named colours (css-color-4), `transparent` and `currentcolor` excepted: they are no colour to map.
const NAMED: [(&str, u32); 148] = [
    ("aliceblue", 0xf0f8ff),
    ("antiquewhite", 0xfaebd7),
    ("aqua", 0x00ffff),
    ("aquamarine", 0x7fffd4),
    ("azure", 0xf0ffff),
    ("beige", 0xf5f5dc),
    ("bisque", 0xffe4c4),
    ("black", 0x000000),
    ("blanchedalmond", 0xffebcd),
    ("blue", 0x0000ff),
    ("blueviolet", 0x8a2be2),
    ("brown", 0xa52a2a),
    ("burlywood", 0xdeb887),
    ("cadetblue", 0x5f9ea0),
    ("chartreuse", 0x7fff00),
    ("chocolate", 0xd2691e),
    ("coral", 0xff7f50),
    ("cornflowerblue", 0x6495ed),
    ("cornsilk", 0xfff8dc),
    ("crimson", 0xdc143c),
    ("cyan", 0x00ffff),
    ("darkblue", 0x00008b),
    ("darkcyan", 0x008b8b),
    ("darkgoldenrod", 0xb8860b),
    ("darkgray", 0xa9a9a9),
    ("darkgreen", 0x006400),
    ("darkgrey", 0xa9a9a9),
    ("darkkhaki", 0xbdb76b),
    ("darkmagenta", 0x8b008b),
    ("darkolivegreen", 0x556b2f),
    ("darkorange", 0xff8c00),
    ("darkorchid", 0x9932cc),
    ("darkred", 0x8b0000),
    ("darksalmon", 0xe9967a),
    ("darkseagreen", 0x8fbc8f),
    ("darkslateblue", 0x483d8b),
    ("darkslategray", 0x2f4f4f),
    ("darkslategrey", 0x2f4f4f),
    ("darkturquoise", 0x00ced1),
    ("darkviolet", 0x9400d3),
    ("deeppink", 0xff1493),
    ("deepskyblue", 0x00bfff),
    ("dimgray", 0x696969),
    ("dimgrey", 0x696969),
    ("dodgerblue", 0x1e90ff),
    ("firebrick", 0xb22222),
    ("floralwhite", 0xfffaf0),
    ("forestgreen", 0x228b22),
    ("fuchsia", 0xff00ff),
    ("gainsboro", 0xdcdcdc),
    ("ghostwhite", 0xf8f8ff),
    ("gold", 0xffd700),
    ("goldenrod", 0xdaa520),
    ("gray", 0x808080),
    ("green", 0x008000),
    ("greenyellow", 0xadff2f),
    ("grey", 0x808080),
    ("honeydew", 0xf0fff0),
    ("hotpink", 0xff69b4),
    ("indianred", 0xcd5c5c),
    ("indigo", 0x4b0082),
    ("ivory", 0xfffff0),
    ("khaki", 0xf0e68c),
    ("lavender", 0xe6e6fa),
    ("lavenderblush", 0xfff0f5),
    ("lawngreen", 0x7cfc00),
    ("lemonchiffon", 0xfffacd),
    ("lightblue", 0xadd8e6),
    ("lightcoral", 0xf08080),
    ("lightcyan", 0xe0ffff),
    ("lightgoldenrodyellow", 0xfafad2),
    ("lightgray", 0xd3d3d3),
    ("lightgreen", 0x90ee90),
    ("lightgrey", 0xd3d3d3),
    ("lightpink", 0xffb6c1),
    ("lightsalmon", 0xffa07a),
    ("lightseagreen", 0x20b2aa),
    ("lightskyblue", 0x87cefa),
    ("lightslategray", 0x778899),
    ("lightslategrey", 0x778899),
    ("lightsteelblue", 0xb0c4de),
    ("lightyellow", 0xffffe0),
    ("lime", 0x00ff00),
    ("limegreen", 0x32cd32),
    ("linen", 0xfaf0e6),
    ("magenta", 0xff00ff),
    ("maroon", 0x800000),
    ("mediumaquamarine", 0x66cdaa),
    ("mediumblue", 0x0000cd),
    ("mediumorchid", 0xba55d3),
    ("mediumpurple", 0x9370db),
    ("mediumseagreen", 0x3cb371),
    ("mediumslateblue", 0x7b68ee),
    ("mediumspringgreen", 0x00fa9a),
    ("mediumturquoise", 0x48d1cc),
    ("mediumvioletred", 0xc71585),
    ("midnightblue", 0x191970),
    ("mintcream", 0xf5fffa),
    ("mistyrose", 0xffe4e1),
    ("moccasin", 0xffe4b5),
    ("navajowhite", 0xffdead),
    ("navy", 0x000080),
    ("oldlace", 0xfdf5e6),
    ("olive", 0x808000),
    ("olivedrab", 0x6b8e23),
    ("orange", 0xffa500),
    ("orangered", 0xff4500),
    ("orchid", 0xda70d6),
    ("palegoldenrod", 0xeee8aa),
    ("palegreen", 0x98fb98),
    ("paleturquoise", 0xafeeee),
    ("palevioletred", 0xdb7093),
    ("papayawhip", 0xffefd5),
    ("peachpuff", 0xffdab9),
    ("peru", 0xcd853f),
    ("pink", 0xffc0cb),
    ("plum", 0xdda0dd),
    ("powderblue", 0xb0e0e6),
    ("purple", 0x800080),
    ("rebeccapurple", 0x663399),
    ("red", 0xff0000),
    ("rosybrown", 0xbc8f8f),
    ("royalblue", 0x4169e1),
    ("saddlebrown", 0x8b4513),
    ("salmon", 0xfa8072),
    ("sandybrown", 0xf4a460),
    ("seagreen", 0x2e8b57),
    ("seashell", 0xfff5ee),
    ("sienna", 0xa0522d),
    ("silver", 0xc0c0c0),
    ("skyblue", 0x87ceeb),
    ("slateblue", 0x6a5acd),
    ("slategray", 0x708090),
    ("slategrey", 0x708090),
    ("snow", 0xfffafa),
    ("springgreen", 0x00ff7f),
    ("steelblue", 0x4682b4),
    ("tan", 0xd2b48c),
    ("teal", 0x008080),
    ("thistle", 0xd8bfd8),
    ("tomato", 0xff6347),
    ("turquoise", 0x40e0d0),
    ("violet", 0xee82ee),
    ("wheat", 0xf5deb3),
    ("white", 0xffffff),
    ("whitesmoke", 0xf5f5f5),
    ("yellow", 0xffff00),
    ("yellowgreen", 0x9acd32),
];

/// Words a text colour value may hold besides tokens: keywords that name no colour of their own, and
/// `text-decoration`'s line and style words. `initial`, `revert` and `revert-layer` are not among them: they resolve
/// to the engine's CanvasText.
const NOT_COLOURS: [&str; 18] = [
    "currentcolor",
    "inherit",
    "unset",
    "transparent",
    "none",
    "auto",
    "from-font",
    "underline",
    "overline",
    "line-through",
    "blink",
    "solid",
    "double",
    "dotted",
    "dashed",
    "wavy",
    "spelling-error",
    "grammar-error",
];

/// Whether a value, once mapped, names only palette tokens (`var(--xdict-...)`, read to its closing parenthesis)
/// and words that are no colour. A system colour (`LinkText`, `-webkit-link`), a function (`color-mix()`,
/// `light-dark()`) or a dictionary's own variable would resolve to a colour outside the palette.
pub(crate) fn only_tokens(value: &str) -> bool {
    let mut rest = value;
    let mut plain = String::with_capacity(value.len());
    while let Some(at) = rest.find("var(--xdict-") {
        plain.push_str(rest.get(..at).unwrap_or(""));
        let mut depth = 0usize;
        let mut end = rest.len();
        for (i, c) in rest.get(at..).unwrap_or("").char_indices() {
            match c {
                '(' => depth += 1,
                ')' => {
                    depth = depth.saturating_sub(1);
                    if depth == 0 {
                        end = at + i + 1;
                        break;
                    }
                }
                _ => {}
            }
        }
        plain.push(' ');
        rest = rest.get(end..).unwrap_or("");
    }
    plain.push_str(rest);
    plain.split(|c: char| c.is_whitespace() || c == ',' || c == '/').filter(|w| !w.is_empty()).all(|w| {
        let lower = w.to_ascii_lowercase();
        NOT_COLOURS.contains(&lower.as_str())
            || lower.starts_with(|c: char| c.is_ascii_digit() || c == '.' || c == '+')
            || (lower.starts_with('-') && lower.as_bytes().get(1).is_some_and(|b| b.is_ascii_digit() || *b == b'.'))
    })
}

#[cfg(test)]
#[allow(clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn rgb(hex: u32) -> Rgb {
        hex_rgb(hex)
    }

    fn ratio(a: Rgb, b: Rgb) -> f64 {
        let (x, y) = (a.luminance(), b.luminance());
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }

    /// `palette.py`'s check, here: every text token on every surface and every tint, in both themes, is 4.5:1.
    #[test]
    fn every_text_token_reads_on_every_surface() {
        for (theme, neutral, tier) in
            [("light", NEUTRAL_LIGHT, FAMILIES.map(|f| f.light)), ("dark", NEUTRAL_DARK, FAMILIES.map(|f| f.dark))]
        {
            let mut texts = vec![neutral[2], neutral[3]];
            let mut surfaces = vec![neutral[0], neutral[1]];
            for t in tier {
                texts.extend([t[0], t[1]]);
                surfaces.push(t[2]);
            }
            for &t in &texts {
                for &s in &surfaces {
                    let r = ratio(rgb(t), rgb(s));
                    assert!(r >= 4.5, "{theme}: #{t:06x} on #{s:06x} is {r:.2}");
                }
            }
        }
    }

    /// Hue is meaning: each family takes its colours; tone is XDict's: deep for dark colours.
    #[test]
    fn colours_take_their_familys_token() {
        let css = |hex: u32, role: Role| mapped(rgb(hex), role, None);
        assert_eq!(css(0xc00000, Role::Text), "var(--xdict-red, #af342f)");
        assert_eq!(css(0x8b0000, Role::Text), "var(--xdict-red-deep, #901114)");
        assert_eq!(css(0x1a0dab, Role::Text), "var(--xdict-blue-deep, #02489f)");
        assert_eq!(css(0x006400, Role::Text), "var(--xdict-green-deep, #035e23)");
        assert_eq!(css(0x800080, Role::Text), "var(--xdict-purple-deep, #622c91)");
        assert_eq!(css(0x000000, Role::Text), "var(--xdict-text, #1d1d1f)");
        assert_eq!(css(0x333333, Role::Text), "var(--xdict-text, #1d1d1f)");
        assert_eq!(css(0x999999, Role::Text), "var(--xdict-text-2, #636366)");
        assert_eq!(css(0xffffff, Role::Text), "var(--xdict-text, #1d1d1f)", "white text is a chip's");
        assert_eq!(css(0xffffff, Role::Background { boxed: false }), "transparent");
        assert_eq!(css(0xffffff, Role::Background { boxed: true }), "var(--xdict-panel, #f3f3f5)");
        assert_eq!(css(0xdddddd, Role::Background { boxed: false }), "var(--xdict-panel, #f3f3f5)");
        assert_eq!(css(0xfff8dc, Role::Background { boxed: false }), "var(--xdict-yellow-tint, #f6f0da)");
        assert_eq!(css(0x602090, Role::Background { boxed: false }), "var(--xdict-purple-tint, #f4ecff)");
        assert_eq!(css(0xcccccc, Role::Mark), "var(--xdict-rule, #d8d8dc)");
        assert_eq!(css(0xc00000, Role::Mark), "var(--xdict-red, #af342f)");
    }

    /// A chip's text follows its background's family, so the pair reads in every theme.
    #[test]
    fn a_chips_text_follows_its_background() {
        let purple = Some(rgb(0x602090));
        assert_eq!(mapped(rgb(0xffffff), Role::Text, purple), "var(--xdict-purple-deep, #622c91)");
        assert_eq!(mapped(rgb(0xffff00), Role::Text, Some(rgb(0x808080))), "var(--xdict-text, #1d1d1f)");
        assert_eq!(mapped(rgb(0xc00000), Role::Text, Some(rgb(0xffffff))), "var(--xdict-red, #af342f)");
    }

    #[test]
    fn every_syntax_is_read() {
        let hex = |t: &str| literal(t).map(|(c, n)| (c.hex(), n));
        assert_eq!(hex("#abc"), Some(("#aabbcc".into(), 4)));
        assert_eq!(hex("#AABBCC;"), Some(("#aabbcc".into(), 7)));
        assert_eq!(hex("#aabbcc80"), Some(("#aabbcc80".into(), 9)));
        assert_eq!(hex("rgb(255, 0, 0)"), Some(("#ff0000".into(), 14)));
        assert_eq!(hex("rgba(0 128 0 / 50%)"), Some(("#00800080".into(), 19)));
        assert_eq!(hex("rgb(100%,0%,0%)").map(|h| h.0), Some("#ff0000".into()));
        assert_eq!(hex("hsl(120, 100%, 25%)").map(|h| h.0), Some("#008000".into()));
        assert_eq!(hex("hsla(240deg 100% 50% / 1)").map(|h| h.0), Some("#0000ff".into()));
        assert_eq!(hex("Navy"), Some(("#000080".into(), 4)));
        for no in ["#ab", "#abcde", "rgb(1,2)", "hsl(x,1%,1%)", "transparent", "currentColor", "nonsense"] {
            assert_eq!(literal(no), None, "{no}");
        }
    }

    #[test]
    fn values_are_mapped_in_place() {
        assert_eq!(map_value("#000", Role::Text, None).as_deref(), Some("var(--xdict-text, #1d1d1f)"));
        let border = map_value("1px solid #c00000", Role::Mark, None).unwrap_or_default();
        assert_eq!(border, "1px solid var(--xdict-red, #af342f)");
        let gradient = map_value("linear-gradient(#fff8dc, #cce0ff)", Role::Background { boxed: false }, None);
        assert_eq!(
            gradient.as_deref(),
            Some("linear-gradient(var(--xdict-yellow-tint, #f6f0da), var(--xdict-blue-tint, #e8f1fe))")
        );
        for kept in ["inherit", "transparent", "url(red.png)", "var(--red)", "'red'", "redder", "light-dark(red, blue)"]
        {
            assert_eq!(map_value(kept, Role::Text, None), None, "{kept}");
        }
    }

    #[test]
    fn the_dark_audits_census_maps_to_tokens() {
        // `dev-docs/measurements/2026-10-15-dark-audit/README.md`'s census (values only): every one becomes a token.
        for hex in [
            0x000000, 0x333333, 0x202040, 0x0e01ad, 0x83001d, 0x6c3815, 0xc12d30, 0x0d680d, 0x3f51b5, 0x0069b4,
            0x666666, 0x008080, 0xd40218, 0xff0000,
        ] {
            assert!(mapped(rgb(hex), Role::Text, None).starts_with("var(--xdict-"), "{hex:06x}");
        }
        for hex in [0xffffff, 0xfaf9de, 0xfdeef3, 0xccffff, 0xf0f0f0, 0x602090, 0x8080c0, 0x3f7373] {
            let t = mapped(rgb(hex), Role::Background { boxed: true }, None);
            assert!(t.starts_with("var(--xdict-"), "{hex:06x}: {t}");
        }
    }

    /// The shell maps the colours a page's own scripts write at run time (`EntryScripts.colourGuard`); both read one
    /// list of samples, so the two mappings cannot drift.
    #[test]
    fn the_shells_samples_take_the_same_tokens() {
        let fixture = include_str!("../../../conformance/fixtures/colour-tokens.tsv");
        let mut checked = 0;
        for line in fixture.lines().filter(|l| !l.trim().is_empty() && !l.starts_with(';')) {
            let (colour, token) = line.split_once('\t').unwrap_or((line, "?"));
            let mapped = literal(colour).map(|(c, _)| mapped(c, Role::Text, None));
            let want = format!("var(--xdict-{token}, ");
            assert!(mapped.as_deref().is_some_and(|m| m.starts_with(&want)), "{colour}: {mapped:?}, want {token}");
            checked += 1;
        }
        assert!(checked >= 30, "{checked} samples");
    }

    #[test]
    fn hostile_values_are_bounded() {
        let started = std::time::Instant::now();
        let many = "#abc ".repeat(1 << 14);
        assert!(map_value(&many, Role::Text, None).is_some());
        let parens = "rgb(".repeat(1 << 16);
        let _ = map_value(&parens, Role::Text, None);
        let words = "a".repeat(1 << 20);
        let _ = map_value(&words, Role::Text, None);
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "{:?}", started.elapsed());
    }
}
