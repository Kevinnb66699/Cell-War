using System.Collections;
using System.Collections.Immutable;

namespace CellWar.Core;

/// <summary>Immutable hash pages with a persistent page table. Builders copy only dirty pages.</summary>
public sealed class PagedMap<TKey, TValue> : IReadOnlyDictionary<TKey, TValue> where TKey : notnull
{
    private readonly ImmutableDictionary<int, ImmutableDictionary<TKey, TValue>> pages;
    public int Count { get; }
    public static PagedMap<TKey, TValue> Empty { get; } = new(
        ImmutableDictionary<int, ImmutableDictionary<TKey, TValue>>.Empty, 0);

    private PagedMap(ImmutableDictionary<int, ImmutableDictionary<TKey, TValue>> pages, int count)
        => (this.pages, Count) = (pages, count);

    // A page uses a persistent collision map, so adversarial hashes cannot force full-world copies.
    private static int Page(TKey key) => key switch
    {
        int id => id >> 4,
        EntityId id => unchecked((int)(id.Value >> 4)),
        HexPosition p => unchecked((p.Q + 32768) * 4096 + ((p.R + 32768) >> 4)),
        _ => (key.GetHashCode() & int.MaxValue) >> 4
    };
    public TValue this[TKey key] => TryGetValue(key, out var value) ? value : throw new KeyNotFoundException();
    public IEnumerable<TKey> Keys => this.Select(pair => pair.Key);
    public IEnumerable<TValue> Values => this.Select(pair => pair.Value);
    public bool ContainsKey(TKey key) => TryGetValue(key, out _);
    public bool TryGetValue(TKey key, out TValue value)
    {
        if (pages.TryGetValue(Page(key), out var page) && page.TryGetValue(key, out value!)) return true;
        value = default!;
        return false;
    }
    public Builder ToBuilder() => new(this);
    public PagedMap<TKey, TValue> SetItem(TKey key, TValue value)
    {
        var builder = ToBuilder();
        builder[key] = value;
        return builder.Freeze();
    }
    public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator() => pages.Values.SelectMany(p => p).GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
    public static implicit operator PagedMap<TKey, TValue>(Dictionary<TKey, TValue> source)
    {
        var builder = Empty.ToBuilder();
        foreach (var pair in source) builder[pair.Key] = pair.Value;
        return builder.Freeze();
    }
    public static implicit operator PagedMap<TKey, TValue>(Builder source) => source.Freeze();

    public sealed class Builder
    {
        private PagedMap<TKey, TValue> root;
        private readonly Dictionary<int, ImmutableDictionary<TKey, TValue>.Builder> dirty = new();
        private int count;
        internal Builder(PagedMap<TKey, TValue> root) => (this.root, count) = (root, root.Count);
        public TValue this[TKey key]
        {
            get => TryGetValue(key, out var value) ? value : throw new KeyNotFoundException();
            set
            {
                var page = Writable(Page(key));
                if (!page.ContainsKey(key)) count++;
                page[key] = value;
            }
        }
        private ImmutableDictionary<TKey, TValue>.Builder Writable(int id)
        {
            if (!dirty.TryGetValue(id, out var page))
            {
                page = (root.pages.TryGetValue(id, out var shared) ? shared : ImmutableDictionary<TKey, TValue>.Empty).ToBuilder();
                dirty.Add(id, page);
            }
            return page;
        }
        public bool TryGetValue(TKey key, out TValue value)
        {
            if (dirty.TryGetValue(Page(key), out var page)) return page.TryGetValue(key, out value!);
            return root.TryGetValue(key, out value!);
        }
        public bool Remove(TKey key)
        {
            if (!Writable(Page(key)).Remove(key)) return false;
            count--;
            return true;
        }
        public PagedMap<TKey, TValue> Freeze()
        {
            var table = root.pages;
            foreach (var pair in dirty)
                table = pair.Value.Count == 0 ? table.Remove(pair.Key) : table.SetItem(pair.Key, pair.Value.ToImmutable());
            root = new(table, count);
            dirty.Clear();
            return root;
        }
    }
}
