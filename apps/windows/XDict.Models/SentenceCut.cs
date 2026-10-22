// The sentence around a selection, cut locally: UI Automation has no sentence unit, so a paragraph is expanded and the
// sentence found here. Pure and tested; the range is UTF-16, as UI Automation reports it.
namespace XDict.Models;

public static class SentenceCut
{
    /// <summary>A sentence in its paragraph: the text, the term's range inside it, and which ends are a cut window.</summary>
    public sealed record Sentence(string Text, int TermStart, int TermLength, bool CutStart, bool CutEnd);

    private static readonly char[] Terminators = ['.', '!', '?', '\u2026', '。', '！', '？'];
    private static readonly char[] Closers = ['"', '\'', '\u201D', '\u2019', '\u00BB', ')', ']', '}', '\u300D', '\u300F', '\uFF09'];

    /// <summary>
    /// The sentence (or run of sentences) covering the term, centered on it when the paragraph exceeds the ceiling.
    /// Null when the range is outside the paragraph, splits a character, or the term alone cannot fit the ceiling.
    /// </summary>
    public static Sentence? Around(string paragraph, int termStart, int termLength, int ceiling = CaptureValue.ContextCeiling)
    {
        if (string.IsNullOrEmpty(paragraph) || termStart < 0 || termLength <= 0 ||
            termStart > paragraph.Length - termLength) return null;
        if (Splits(paragraph, termStart, termLength)) return null;
        if (termLength > ceiling) return null;
        int start = LineStart(paragraph, termStart);
        int end = LineEnd(paragraph, termStart + termLength);
        start = SkipSpace(paragraph, start, end);
        end = TrimEnd(paragraph, start, end);
        if (end <= start || termStart < start || termStart + termLength > end) return null;
        if (end - start <= ceiling)
            return new Sentence(paragraph[start..end], termStart - start, termLength, false, false);

        // A window of exactly the ceiling, roughly centered on the term, moved off a character boundary.
        int window = Math.Clamp(termStart - (ceiling - termLength) / 2, start, end - ceiling);
        if (window > start && char.IsLowSurrogate(paragraph[window])) window++;
        // The bump above can move the window one past end - ceiling; clamp the pair so the slice never leaves the
        // sentence (and never indexes past paragraph.Length when the sentence ends the paragraph).
        int windowEnd = Math.Min(window + ceiling, end);
        if (windowEnd < end && char.IsHighSurrogate(paragraph[windowEnd - 1])) windowEnd--;
        if (windowEnd <= window) return null;
        if (windowEnd < termStart + termLength || window > termStart) return null; // the window no longer holds the term
        return new Sentence(paragraph[window..windowEnd], termStart - window, termLength,
            window > start, windowEnd < end);
    }

    /// <summary>Where the sentence holding `offset` starts: after the previous terminator and its closers.</summary>
    private static int LineStart(string text, int offset)
    {
        for (int i = offset - 1; i >= 0; i--)
        {
            if (Array.IndexOf(Terminators, text[i]) < 0) continue;
            int start = i + 1;
            while (start < offset && (IsCloser(text[start]) || char.IsWhiteSpace(text[start]))) start++;
            return start;
        }
        return 0;
    }

    /// <summary>Where the sentence holding the character before `offset` ends: through its terminator and closers.</summary>
    private static int LineEnd(string text, int offset)
    {
        for (int i = offset; i < text.Length; i++)
        {
            if (Array.IndexOf(Terminators, text[i]) < 0) continue;
            int end = i + 1;
            while (end < text.Length && IsCloser(text[end])) end++;
            return end;
        }
        return text.Length;
    }

    private static bool IsCloser(char c) => Array.IndexOf(Closers, c) >= 0;

    private static int SkipSpace(string text, int start, int end)
    {
        while (start < end && char.IsWhiteSpace(text[start])) start++;
        return start;
    }

    private static int TrimEnd(string text, int start, int end)
    {
        while (end > start && char.IsWhiteSpace(text[end - 1])) end--;
        return end;
    }

    private static bool Splits(string text, int start, int length)
    {
        if (start > 0 && char.IsLowSurrogate(text[start]) && char.IsHighSurrogate(text[start - 1])) return true;
        int end = start + length;
        return end < text.Length && char.IsHighSurrogate(text[end - 1]) && char.IsLowSurrogate(text[end]);
    }
}
