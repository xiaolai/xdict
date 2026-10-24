//! ARPAbet as CMUdict writes it: 39 phonemes, a stress digit 0, 1 or 2 on every vowel and on nothing else.

const VOWELS: [&str; 15] = ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"];
const CONSONANTS: [&str; 24] = [
    "B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "NG", "P", "R", "S", "SH", "T", "TH", "V", "W",
    "Y", "Z", "ZH",
];

/// One ARPAbet token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Phone {
    Vowel(u8),
    Consonant,
}

/// The token as ARPAbet, or `None` when it is not.
pub(super) fn phone(token: &str) -> Option<Phone> {
    if CONSONANTS.contains(&token) {
        return Some(Phone::Consonant);
    }
    let (base, digit) = token.split_at_checked(token.len().checked_sub(1)?)?;
    let stress = match digit {
        "0" => 0,
        "1" => 1,
        "2" => 2,
        _ => return None,
    };
    VOWELS.contains(&base).then_some(Phone::Vowel(stress))
}

/// The stress digit of every vowel, in order.
pub(super) fn stresses(phonemes: &[String]) -> Vec<u8> {
    phonemes
        .iter()
        .filter_map(|p| match phone(p) {
            Some(Phone::Vowel(stress)) => Some(stress),
            _ => None,
        })
        .collect()
}

pub(super) fn vowels(phonemes: &[String]) -> usize {
    // Counted, not collected: this runs for every stem validation (audit, 2026-10-24).
    phonemes.iter().filter(|p| matches!(phone(p), Some(Phone::Vowel(_)))).count()
}

/// The phonemes from the last vowel with stress 1 or 2 to the end; `None` when no vowel is stressed.
pub(super) fn rime(phonemes: &[String]) -> Option<&[String]> {
    let start = phonemes.iter().rposition(|p| matches!(phone(p), Some(Phone::Vowel(1 | 2))))?;
    phonemes.get(start..)
}

/// What two rimes are compared by: the tokens, with stress 2 written as 1 (primary and secondary stress alike).
pub(super) fn rime_key(rime: &[String]) -> String {
    // One string built in place: no token copy and no join (audit, 2026-10-24).
    let mut key = String::new();
    for (index, p) in rime.iter().enumerate() {
        if index > 0 {
            key.push(' ');
        }
        match (phone(p), p.strip_suffix('2')) {
            (Some(Phone::Vowel(2)), Some(base)) => {
                key.push_str(base);
                key.push('1');
            }
            _ => key.push_str(p),
        }
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(text: &str) -> Vec<String> {
        text.split(' ').map(String::from).collect()
    }

    #[test]
    fn arpabet_tokens_rimes_and_stress() {
        assert_eq!(phone("EY1"), Some(Phone::Vowel(1)));
        assert_eq!(phone("SH"), Some(Phone::Consonant));
        assert_eq!(phone("EY"), None);
        assert_eq!(phone("SH1"), None);
        assert_eq!(phone("QQ"), None);
        assert_eq!(phone(""), None);
        let monotone = tokens("M AA1 N AH0 T OW2 N");
        assert_eq!(rime(&monotone).map(rime_key), Some("OW1 N".into()));
        assert_eq!(stresses(&monotone), [1, 0, 2]);
        assert_eq!(rime(&tokens("DH AH0")), None);
    }
}
