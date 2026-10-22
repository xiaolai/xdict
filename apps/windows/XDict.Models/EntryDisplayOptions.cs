namespace XDict.Models;

public sealed record EntryDisplayOption(string Id, string Attribute, string[] Values, string DefaultValue);
public sealed record EntryDisplayOptions(uint Version, EntryDisplayOption[] Options, string Css)
{
    public string[][] Resolve(IReadOnlyDictionary<string, string>? chosen)
    {
        if (Version != 1 || Options.Length > 32 || Css.Length > 256 * 1024) throw new InvalidDataException("unsupported display catalogue");
        var resolved = new List<string[]>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var option in Options)
        {
            if (option.Id.Length is < 1 or > 64 || !option.Id.All(c => c is >= 'a' and <= 'z' or '-'))
                throw new InvalidDataException("invalid display option id");
            if (option.Attribute != "data-xdict-opt-" + option.Id || !ids.Add(option.Id) || option.Values.Length is < 1 or > 32 ||
                !option.Values.Contains(option.DefaultValue, StringComparer.Ordinal) || option.Values.Any(v => v.Length is < 1 or > 64 || !v.All(c => c is >= 'a' and <= 'z' or '-')))
                throw new InvalidDataException("invalid display option");
            string? value = chosen?.GetValueOrDefault(option.Id);
            resolved.Add([option.Attribute, value is not null && option.Values.Contains(value, StringComparer.Ordinal) ? value : option.DefaultValue]);
        }
        return resolved.ToArray();
    }
}
