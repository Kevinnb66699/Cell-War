namespace CellWar.Core;

public interface IObservationProvider
{
    MatchObservation Observe(ReadLease lease, int? authorizedSeat);
}

public interface IObservationSink
{
    void Publish(MatchObservation observation);
}
