﻿// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using Xunit;

namespace System.Numerics.Tests
{

    public static partial class UInt32Samples
    {
        private static readonly uint[] set1 = new uint[] {
            0B00000000000000000000000000000000U,
            0B00000000000000000000000000000001U,
            0B00111111111111111111111111111110U,
            0B00111111111111111111111111111111U,

            0B01000000000000000000000000000000U,
            0B01000000000000000000000000000001U,
            0B01111111111111111111111111111110U,
            0B01111111111111111111111111111111U,

            0B10000000000000000000000000000000U,
            0B10000000000000000000000000000001U,
            0B10111111111111111111111111111110U,
            0B10111111111111111111111111111111U,

            0B11000000000000000000000000000000U,
            0B11000000000000000000000000000001U,
            0B11111111111111111111111111111110U,
            0B11111111111111111111111111111111U,
        };

        private static IEnumerable<uint> GetSet1()
        {
            foreach (var item in set1)
            {
                yield return item;
            }
        }

        public static readonly IEnumerable<uint> Set1 = GetSet1();

        private static readonly uint[] set2 = new uint[] {
            0B00000000000000000000000000000000U,
            0B00000000000000000000000000000001U,
            0B00000000000000000100000000000000U,
            0B00000000000000000100000000000001U,

            0B00000000000000010000000000000000U,
            0B00000000000000010000000000000001U,
            0B00000000000000010100000000000000U,
            0B00000000000000010100000000000001U,

            0B00111111111111111111111111111110U,
            0B00111111111111111111111111111111U,
            0B00111111111111111011111111111110U,
            0B00111111111111111011111111111111U,

            0B00111111111111101111111111111110U,
            0B00111111111111101111111111111111U,
            0B00111111111111101011111111111110U,
            0B00111111111111101011111111111111U,

            0B01000000000000000000000000000000U,
            0B01000000000000000000000000000001U,
            0B01000000000000000100000000000000U,
            0B01000000000000000100000000000001U,

            0B01000000000000010000000000000000U,
            0B01000000000000010000000000000001U,
            0B01000000000000010100000000000000U,
            0B01000000000000010100000000000001U,

            0B01111111111111111111111111111110U,
            0B01111111111111111111111111111111U,
            0B01111111111111111011111111111110U,
            0B01111111111111111011111111111111U,

            0B01111111111111101111111111111110U,
            0B01111111111111101111111111111111U,
            0B01111111111111101011111111111110U,
            0B01111111111111101011111111111111U,

            0B10000000000000000000000000000000U,
            0B10000000000000000000000000000001U,
            0B10000000000000000100000000000000U,
            0B10000000000000000100000000000001U,

            0B10000000000000010000000000000000U,
            0B10000000000000010000000000000001U,
            0B10000000000000010100000000000000U,
            0B10000000000000010100000000000001U,

            0B10111111111111111111111111111110U,
            0B10111111111111111111111111111111U,
            0B10111111111111111011111111111110U,
            0B10111111111111111011111111111111U,

            0B10111111111111101111111111111110U,
            0B10111111111111101111111111111111U,
            0B10111111111111101011111111111110U,
            0B10111111111111101011111111111111U,

            0B11000000000000000000000000000000U,
            0B11000000000000000000000000000001U,
            0B11000000000000000100000000000000U,
            0B11000000000000000100000000000001U,

            0B11000000000000010000000000000000U,
            0B11000000000000010000000000000001U,
            0B11000000000000010100000000000000U,
            0B11000000000000010100000000000001U,

            0B11111111111111111111111111111110U,
            0B11111111111111111111111111111111U,
            0B11111111111111111011111111111110U,
            0B11111111111111111011111111111111U,

            0B11111111111111101111111111111110U,
            0B11111111111111101111111111111111U,
            0B11111111111111101011111111111110U,
            0B11111111111111101011111111111111U,
        };

        private static IEnumerable<uint> GetSet2()
        {
            foreach (var item in set2)
            {
                yield return item;
            }
        }

        public static readonly IEnumerable<uint> Set2 = GetSet2();
    }
}
