// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Generated by Fuzzlyn v2.4 on 2024-10-14 17:25:44
// Run on X86 Windows
// Seed: 16789241273493732217-vectort,vector128,vector256,x86aes,x86avx,x86avx2,x86avx512bw,x86avx512bwvl,x86avx512cd,x86avx512cdvl,x86avx512dq,x86avx512dqvl,x86avx512f,x86avx512fvl,x86bmi1,x86bmi2,x86fma,x86lzcnt,x86pclmulqdq,x86popcnt,x86sse,x86sse2,x86sse3,x86sse41,x86sse42,x86ssse3,x86x86base
// Reduced from 49.4 KiB to 0.5 KiB in 00:03:38
// Hits JIT assert in Release:
// Assertion failed '!fgRngChkThrowAdded' in 'Program:Main(Fuzzlyn.ExecutionServer.IRuntime)' during 'Calculate stack level slots' (IL size 59; hash 0xade6b36b; FullOpts)
// 
//     File: D:\a\_work\1\s\src\coreclr\jit\flowgraph.cpp Line: 3655
// 
using System;
using System.Numerics;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;
using Xunit;

public class Runtime_108851
{
    public static int[] s_21 = new int[1];

    [Fact]
    public static void Problem()
    {
        if (!Avx512F.IsSupported)
        {
            return;
        }

        var vr1 = Vector128.Create<double>(0);
        if (Avx512F.ConvertToUInt32WithTruncation(vr1) >= 2894444111893762202L)
        {
            try
            {
                s_21[0] = 0;
            }
            finally
            {
                s_21[0] = 0;
            }
        }

        s_21[0] = 0;
    }
}
