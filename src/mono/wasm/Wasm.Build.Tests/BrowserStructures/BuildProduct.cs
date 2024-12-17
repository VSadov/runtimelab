// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#nullable enable

namespace Wasm.Build.Tests;

public record BuildResult(
    string ProjectDir,
    string LogFile,
    bool Success,
    string BuildOutput
);
