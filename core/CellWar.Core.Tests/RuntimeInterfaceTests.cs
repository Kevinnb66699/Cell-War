using Xunit;

namespace CellWar.Core.Tests;

public class RuntimeInterfaceTests
{
    [Fact]
    public void WorldHandle_NewWorld_GeneratesUniqueIds()
    {
        var world1 = WorldHandle.NewWorld();
        var world2 = WorldHandle.NewWorld();
        
        Assert.NotEqual(world1.Id, world2.Id);
        Assert.Equal(0L, world1.CreatedAtTick);
        Assert.Equal(0L, world2.CreatedAtTick);
    }

    [Fact]
    public void StepResult_RecordsExecutionState()
    {
        var result = new StepResult(
            EventsProcessed: 3,
            NewTick: 100L,
            QueueEmpty: false
        );
        
        Assert.Equal(3, result.EventsProcessed);
        Assert.Equal(100L, result.NewTick);
        Assert.False(result.QueueEmpty);
    }

    [Fact]
    public void ScheduledEvent_StoresEventData()
    {
        var payload = new { UnitId = 42 };
        var evt = new ScheduledEvent(
            Tick: 150L,
            EventType: "UnitDamage",
            Payload: payload,
            SequenceId: 5
        );
        
        Assert.Equal(150L, evt.Tick);
        Assert.Equal("UnitDamage", evt.EventType);
        Assert.Equal(payload, evt.Payload);
        Assert.Equal(5, evt.SequenceId);
    }

    [Fact]
    public void EntityId_InvalidState_IsRecognized()
    {
        var invalid = EntityId.Invalid;
        var valid = new EntityId(123);
        
        Assert.False(invalid.IsValid);
        Assert.True(valid.IsValid);
        Assert.Equal(0UL, invalid.Value);
        Assert.Equal(123UL, valid.Value);
    }
}
