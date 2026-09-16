namespace CellWar.Core.Tests;

public class HelloCoreTests
{
    [Fact]
    public void GetGreeting_ReturnsExpectedMessage()
    {
        var core = new HelloCore();
        var greeting = core.GetGreeting();
        Assert.Equal("CellWar.Core initialized", greeting);
    }
}
