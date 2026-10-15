//! "Plain by default" (ADR-0010, the owner, 2026-10-15): decorative images and icons go, content images
//! (illustrations, diagrams) stay. An `<img>` is judged from its own tag: its declared size and its file name.
//! What neither decides is kept and reported, never guessed. An image inside a link is a control (a speaker, an
//! arrow) and is left for the control replacement (`dev-docs/reading-style.md` §5).

/// What an image is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Image {
    Decoration,
    Content,
    Undecided,
}

/// Words in a file name or class that name an icon or decoration.
const DECORATIVE: [&str; 11] =
    ["icon", "ico_", "bullet", "arrow", "spacer", "btn", "button", "sprite", "logo", "badge", "blank.gif"];
/// Words that name content.
const CONTENT: [&str; 7] = ["illus", "picture", "pic_", "fig", "diagram", "photo", "image_"];
/// The largest declared side of a decoration, and the smallest of a content image, in pixels.
const ICON_PX: u32 = 32;
const CONTENT_PX: u32 = 100;

/// The judgement on one start tag's source.
pub(crate) fn judge(tag: &str) -> Image {
    let attr = |n| crate::phon::attribute_of(tag, n);
    let px = |n| attr(n).and_then(|v| v.trim().trim_end_matches("px").parse::<u32>().ok());
    let (w, h) = (px("width"), px("height"));
    let name = attr("src").unwrap_or("").to_ascii_lowercase();
    let file = name.rsplit(['/', '\\']).next().unwrap_or("");
    let class = attr("class").unwrap_or("").to_ascii_lowercase();
    let words = format!("{file} {class}");
    if DECORATIVE.iter().any(|d| words.contains(d)) {
        return Image::Decoration;
    }
    if let (Some(w), Some(h)) = (w, h)
        && w <= ICON_PX
        && h <= ICON_PX
    {
        return Image::Decoration;
    }
    if w.is_some_and(|w| w >= CONTENT_PX) || h.is_some_and(|h| h >= CONTENT_PX) {
        return Image::Content;
    }
    if CONTENT.iter().any(|c| words.contains(c)) || file.ends_with(".jpg") || file.ends_with(".jpeg") {
        return Image::Content;
    }
    Image::Undecided
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn images_are_judged_by_their_own_tag() {
        assert_eq!(judge("<img src=\"img/icon_uk.png\">"), Image::Decoration);
        assert_eq!(judge("<img src=a.png width=16 height=16>"), Image::Decoration);
        assert_eq!(judge("<img src=a.png class=\"bullet\">"), Image::Decoration);
        assert_eq!(judge("<img src=a.png width=400>"), Image::Content);
        assert_eq!(judge("<img src=\"pics/skate.jpg\">"), Image::Content);
        assert_eq!(judge("<img src=\"fig_12.png\">"), Image::Content);
        assert_eq!(judge("<img src=x.png>"), Image::Undecided);
    }
}
