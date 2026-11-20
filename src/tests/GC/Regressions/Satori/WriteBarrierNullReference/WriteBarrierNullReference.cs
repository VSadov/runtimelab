// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Runtime.CompilerServices;
using Xunit;

// A reference store into a field of a null object faults in the write barrier, and the fault must surface as
// a NullReferenceException. The Satori barrier stores values that need no cards, such as null, with a separate
// instruction (RhpAssignRefAVLocationNotHeap), which the runtime must also recognize as a write barrier fault.
// The GC switches the barrier between its variants in collections, so the stores are repeated after collections.
public static class WriteBarrierNullReference
{
    private sealed class Holder
    {
        public object? Value;
    }

    private static object? s_escaped;

    [Fact]
    public static void TestEntryPoint()
    {
        // stored into a static field, thus not local to the thread
        s_escaped = new object();

        for (int i = 0; i < 3; i++)
        {
            Assert.Throws<NullReferenceException>(() => Store(null, null));
            // a new object is local to the thread, the barrier records its escape ahead of the store
            Assert.Throws<NullReferenceException>(() => Store(null, new object()));
            Assert.Throws<NullReferenceException>(() => Store(null, s_escaped));

            GC.Collect();
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void Store(Holder? holder, object? value)
    {
        holder!.Value = value;
    }
}
