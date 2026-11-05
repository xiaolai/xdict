// What the capture panel hands the meaning pane: the term, its validated sentence and range, and the entry the
// panel drew. The sentence and the entry are the only things an AI question may carry, and only on the reader's ask.
namespace XDict.App.Capture;

public sealed record MeaningRequest(
    string Term,
    string Sentence,
    int Start,
    int Length,
    string Dict,
    string Edition,
    string Key,
    uint Occurrence,
    string DictionaryName);
