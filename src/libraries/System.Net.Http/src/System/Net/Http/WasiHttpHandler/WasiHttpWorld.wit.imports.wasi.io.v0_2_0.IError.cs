// Generated by `wit-bindgen` 0.32.0. DO NOT EDIT!
// <auto-generated />
#nullable enable

using System;
using System.Runtime.CompilerServices;
using System.Collections;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;

namespace WasiHttpWorld.wit.imports.wasi.io.v0_2_0;

internal interface IError {

    /**
    * A resource which represents some error information.
    *
    * The only method provided by this resource is `to-debug-string`,
    * which provides some human-readable information about the error.
    *
    * In the `wasi:io` package, this resource is returned through the
    * `wasi:io/streams/stream-error` type.
    *
    * To provide more specific error information, other interfaces may
    * provide functions to further "downcast" this error into more specific
    * error information. For example, `error`s returned in streams derived
    * from filesystem types to be described using the filesystem's own
    * error-code type, using the function
    * `wasi:filesystem/types/filesystem-error-code`, which takes a parameter
    * `borrow&lt;error&gt;` and returns
    * `option&lt;wasi:filesystem/types/error-code&gt;`.
    *
    * The set of functions which can "downcast" an `error` into a more
    * concrete type is open.
    */

    internal class Error: IDisposable {
        internal int Handle { get; set; }

        internal readonly record struct THandle(int Handle);

        internal Error(THandle handle) {
            Handle = handle.Handle;
        }

        public void Dispose() {
            Dispose(true);
        }

        [DllImport("wasi:io/error@0.2.0", EntryPoint = "[resource-drop]error"), WasmImportLinkage]
        private static extern void wasmImportResourceDrop(int p0);

        protected virtual void Dispose(bool disposing) {
            if (disposing && Handle != 0) {
                wasmImportResourceDrop(Handle);
                Handle = 0;
            }
        }

        internal static class ToDebugStringWasmInterop
        {
            [DllImport("wasi:io/error@0.2.0", EntryPoint = "[method]error.to-debug-string"), WasmImportLinkage]
            internal static extern void wasmImportToDebugString(int p0, nint p1);

        }

        internal   unsafe string ToDebugString()
        {
            var handle = this.Handle;

            var retArea = new uint[2];
            fixed (uint* retAreaByte0 = &retArea[0])
            {
                var ptr = (nint)retAreaByte0;
                ToDebugStringWasmInterop.wasmImportToDebugString(handle, ptr);
                return Encoding.UTF8.GetString((byte*)BitConverter.ToInt32(new Span<byte>((void*)(ptr + 0), 4)), BitConverter.ToInt32(new Span<byte>((void*)(ptr + 4), 4)));
            }

            //TODO: free alloc handle (interopString) if exists
        }

    }

}
