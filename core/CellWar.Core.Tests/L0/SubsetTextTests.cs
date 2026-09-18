namespace CellWar.Core.Tests.L0;

/// <summary>`Subset.Text` 是 delta 叶子「相等吗」的唯一尺子：没语义键的数组整条当叶子，叶子里的对象键序不该算差异（批 1 F13）。</summary>
public class SubsetTextTests
{
    [Fact]
    public void 叶子里的对象按键名排序后再比_键序不同不算差异()
    {
        var a = new List<object?> { new Dictionary<string, object?> { ["id"] = 0L, ["faction"] = 1L, ["d"] = new Dictionary<string, object?> { ["income"] = 28L } } };
        var b = new List<object?> { new Dictionary<string, object?> { ["d"] = new Dictionary<string, object?> { ["income"] = 28L }, ["faction"] = 1L, ["id"] = 0L } };
        Assert.Equal(Subset.Text(a), Subset.Text(b));
        Assert.Equal("[{\"d\":{\"income\":28},\"faction\":1,\"id\":0}]", Subset.Text(a));
    }

    [Fact]
    public void 值不同仍是差异()
    {
        var a = new Dictionary<string, object?> { ["x"] = 1L, ["y"] = 2L };
        var b = new Dictionary<string, object?> { ["y"] = 3L, ["x"] = 1L };
        Assert.NotEqual(Subset.Text(a), Subset.Text(b));
    }
}
