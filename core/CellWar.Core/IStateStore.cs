namespace CellWar.Core;

/// <summary>
/// State Store: 版本控制、隔离与原子提交。
/// 使用结构共享与写时复制，支持分支和快照。
/// 不知道玩法语义，只保证版本和原子性。
/// </summary>
public interface IStateStore
{
    /// <summary>
    /// 分配新世界存储，返回内部键。
    /// </summary>
    StoreKey Allocate(WorldImage initial);

    /// <summary>
    /// 读取指定版本的不可变快照。
    /// </summary>
    ReadLease Read(StoreKey key, RevisionQuery revision);

    /// <summary>
    /// 开始事务，基于期望的 revision。
    /// </summary>
    Result<WorldTransaction, ConflictError> Begin(StoreKey key, Revision expected);

    /// <summary>
    /// 提交事务，返回新 revision。
    /// </summary>
    Result<CommitReceipt, StoreError> Commit(WorldTransaction tx);

    /// <summary>
    /// 计算两个版本之间的差异。
    /// </summary>
    ChangeSet Diff(ReadLease before, ReadLease after);

    /// <summary>
    /// 从源版本创建结构共享的分支。
    /// </summary>
    StoreKey Fork(ReadLease source);

    /// <summary>
    /// 导出快照用于持久化。
    /// </summary>
    Checkpoint Export(StoreKey key);

    /// <summary>
    /// 从快照恢复世界。
    /// </summary>
    Result<StoreKey, SnapshotError> Import(Checkpoint checkpoint);

    /// <summary>
    /// 释放世界存储。
    /// </summary>
    void Drop(StoreKey key);
}

/// <summary>
/// StoreKey: 内部存储标识，仅 Runtime 使用，不跨进程。
/// </summary>
public readonly record struct StoreKey(Guid Id);

/// <summary>
/// Revision: 单调递增的版本号。
/// </summary>
public readonly record struct Revision(long Value) : IComparable<Revision>
{
    public static readonly Revision Initial = new(0);

    public int CompareTo(Revision other) => Value.CompareTo(other.Value);

    public Revision Next() => new(Value + 1);
}

/// <summary>
/// RevisionQuery: 查询特定版本或最新版本。
/// </summary>
public abstract record RevisionQuery
{
    public sealed record Latest : RevisionQuery;
    public sealed record Exact(Revision Revision) : RevisionQuery;
}

/// <summary>
/// ReadLease: 不可变读租约，持有特定版本的引用。
/// </summary>
public sealed class ReadLease : IDisposable
{
    private WorldImage? snapshot;
    internal ReadLease(StoreKey key, Revision revision, WorldImage snapshot)
    {
        Key = key;
        Revision = revision;
        this.snapshot = snapshot;
    }

    public StoreKey Key { get; }
    public Revision Revision { get; }
    public WorldImage Snapshot => snapshot ?? throw new ObjectDisposedException(nameof(ReadLease));

    public void Dispose()
    {
        snapshot = null;
    }
}

/// <summary>
/// WorldTransaction: 事务上下文，包含可变状态、调度、RNG、屏障和输出。
/// </summary>
public sealed class WorldTransaction : IDisposable
{
    internal object? Owner { get; set; }
    internal bool Completed { get; private set; }
    internal WorldTransaction(StoreKey key, Revision baseRevision, WorldImage mutableImage)
    {
        Key = key;
        BaseRevision = baseRevision;
        MutableImage = mutableImage;
    }

    public StoreKey Key { get; }
    public Revision BaseRevision { get; }
    public WorldImage MutableImage { get; }
    public void Dispose()
    {
        Completed = true;
        MutableImage.Freeze();
    }
}

/// <summary>
/// CommitReceipt: 提交收据，包含新版本号。
/// </summary>
public readonly record struct CommitReceipt(Revision NewRevision);

/// <summary>
/// WorldImage: 完整世界状态的镜像，包含所有可分支状态。
/// 使用不可变集合实现结构共享。
/// </summary>
public sealed class WorldImage
{
    private bool frozen;
    private WorldState state;
    private SimulationState simulation = new();
    public WorldState State
    {
        get => state;
        set { EnsureMutable(); state = value ?? throw new ArgumentNullException(nameof(value)); }
    }
    public SimulationState Simulation
    {
        get => simulation;
        set { EnsureMutable(); simulation = value; }
    }
    
    public WorldImage(WorldState state)
    {
        this.state = state;
    }
    
    internal WorldImage CopyForTransaction() => new(State) { Simulation = Simulation };
    internal WorldImage Freeze() { frozen = true; return this; }
    private void EnsureMutable()
    {
        if (frozen) throw new InvalidOperationException("Published world images are immutable.");
    }
}

/// <summary>
/// ChangeSet: 两个版本之间的增量差异。
/// </summary>
public sealed class ChangeSet
{
    public IReadOnlyList<EntityId> Cells { get; init; } = Array.Empty<EntityId>();
    public IReadOnlyList<HexPosition> Tissues { get; init; } = Array.Empty<HexPosition>();
    public IReadOnlyList<int> Players { get; init; } = Array.Empty<int>();
    public bool TurnChanged { get; init; }
    public bool SimulationChanged { get; init; }
}

/// <summary>
/// Checkpoint: 可序列化的快照数据。
/// </summary>
public sealed class Checkpoint
{
    public string Json { get; }
    public Checkpoint(string json = "") => Json = json;
}

/// <summary>
/// 结果类型：成功或错误。
/// </summary>
public abstract record Result<TValue, TError>
{
    public sealed record Ok(TValue Value) : Result<TValue, TError>;
    public sealed record Err(TError Error) : Result<TValue, TError>;

    public bool IsOk => this is Ok;
    public bool IsErr => this is Err;
}

public sealed record ConflictError(Revision Expected, Revision Actual);
public sealed record StoreError(string Message);
public sealed record SnapshotError(string Message);
