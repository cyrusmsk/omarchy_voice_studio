/**
 * Lock-free single-producer / single-consumer command queue.
 *
 * The UI thread is the only producer, the control/engine side the only
 * consumer. The real-time audio callback never touches this queue — it only
 * observes the published graph pointer (see audio.graph). Payloads are
 * heap-allocated command structs owned by the queue; capacity is fixed at
 * construction so enqueue/dequeue never allocate.
 */
module audio.rt_queue;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;

enum EngineCommandKind : ubyte
{
    setInputGain,
    setOutputGain,
    setSlotEnabled,
    setControl,
    swapGraph,
    noop,
}

struct EngineCommand
{
    EngineCommandKind kind;
    uint slot; // plugin slot index (for slot/control commands)
    uint port; // control port index
    float value;
    void* graph; // for swapGraph
}

final class CommandQueue
{
private:
    EngineCommand[] _buf;
    uint _mask;
    shared uint _head; // consumer index
    shared uint _tail; // producer index

public:
    this(uint capacityPowerOfTwo = 8)
    {
        uint cap = 1u << capacityPowerOfTwo;
        _buf = new EngineCommand[cap];
        _mask = cap - 1;
        atomicStore!(MemoryOrder.rel)(_head, 0);
        atomicStore!(MemoryOrder.rel)(_tail, 0);
    }

    @property uint capacity() const nothrow @nogc { return _mask + 1; }

    bool enqueue(EngineCommand cmd) nothrow
    {
        uint tail = atomicLoad!(MemoryOrder.acq)(_tail);
        uint head = atomicLoad!(MemoryOrder.acq)(_head);
        if (tail - head >= _mask + 1)
            return false; // full: caller drops + surfaces "engine busy"
        _buf[tail & _mask] = cmd;
        atomicStore!(MemoryOrder.rel)(_tail, tail + 1);
        return true;
    }

    bool dequeue(out EngineCommand cmd) nothrow
    {
        uint head = atomicLoad!(MemoryOrder.acq)(_head);
        uint tail = atomicLoad!(MemoryOrder.acq)(_tail);
        if (head == tail)
            return false;
        cmd = _buf[head & _mask];
        atomicStore!(MemoryOrder.rel)(_head, head + 1);
        return true;
    }

    /// Non-RT helper for tests: number of pending items.
    uint pending() nothrow
    {
        return atomicLoad!(MemoryOrder.acq)(_tail) - atomicLoad!(MemoryOrder.acq)(_head);
    }
}

unittest
{
    auto q = new CommandQueue(2); // capacity 4
    EngineCommand c;
    c.kind = EngineCommandKind.setInputGain;
    c.value = -3.0f;
    assert(q.enqueue(c));
    assert(q.pending == 1);
    EngineCommand o;
    assert(q.dequeue(o));
    assert(o.kind == EngineCommandKind.setInputGain);
    assert(!q.dequeue(o));
}
