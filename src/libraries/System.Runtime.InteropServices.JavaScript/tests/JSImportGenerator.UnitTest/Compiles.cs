// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using Microsoft.CodeAnalysis;
using System.Collections.Generic;
using System.Runtime.InteropServices.JavaScript;
using System.Threading.Tasks;
using System;
using Xunit;
using Microsoft.Interop.UnitTests;
using Microsoft.CodeAnalysis.CSharp.Testing;
using Microsoft.CodeAnalysis.Testing;
using Microsoft.CodeAnalysis.Text;
using System.Text;

namespace JSImportGenerator.Unit.Tests
{
    public class Compiles
    {
        public static IEnumerable<object[]> CodeSnippetsToCompile()
        {
            yield return new object[] { CodeSnippets.TrivialClassDeclarations };
            yield return new object[] { CodeSnippets.AllDefault };
            yield return new object[] { CodeSnippets.AllAnnotated };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<int>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<byte>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<bool>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<char>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<string>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<JSObject>() };
            yield return new object[] { CodeSnippets.DefaultReturnMarshaler<Exception>() };
        }


        [Theory]
        [MemberData(nameof(CodeSnippetsToCompile))]
        public void ValidateSnippets(string source)
        {
            Compilation comp = TestUtils.CreateCompilation(source, allowUnsafe: true);
            TestUtils.AssertPreSourceGeneratorCompilation(comp);

            var newComp = TestUtils.RunGenerators(comp, out var generatorDiags,
                new Microsoft.Interop.JavaScript.JSImportGenerator(),
                new Microsoft.Interop.JavaScript.JSExportGenerator());

            // uncomment for debugging JSTestUtils.DumpCode(source, newComp, generatorDiags);

            Assert.Empty(generatorDiags);

            TestUtils.AssertPostSourceGeneratorCompilation(newComp);
        }

        [Fact]
        public async Task ValidateGeneratedSourceOutput()
        {
            var test = new Test()
            {
                TestState =
                {
                    Sources = { CodeSnippets.AllAnnotated, CodeSnippets.AllAnnotatedExport },
                    GeneratedSources =
                    {
                        (typeof(Microsoft.Interop.JavaScript.JSImportGenerator),
                        "JSImports.g.cs",
                        SourceText.From("""
                            // <auto-generated/>
                            unsafe partial class Basic
                            {
                                [global::System.Diagnostics.DebuggerNonUserCode]
                                internal static partial void Annotated(object a1, long a2, long a3, global::System.Action a4, global::System.Func<int> a5, global::System.Span<byte> a6, global::System.ArraySegment<byte> a7, global::System.Threading.Tasks.Task<object> a8, object[] a9, global::System.DateTime a10, global::System.DateTimeOffset a11, global::System.Threading.Tasks.Task<global::System.DateTime> a12, global::System.Threading.Tasks.Task<global::System.DateTimeOffset> a13, global::System.Threading.Tasks.Task<long> a14, global::System.Threading.Tasks.Task<long> a15)
                                {
                                    if (__signature_Annotated_1583225186 == null)
                                    {
                                        __signature_Annotated_1583225186 = global::System.Runtime.InteropServices.JavaScript.JSFunctionBinding.BindJSFunction("DoesNotExist", null, new global::System.Runtime.InteropServices.JavaScript.JSMarshalerType[] { global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Discard, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int52, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.BigInt64, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Action(), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Function(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int32), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Span(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Byte), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.ArraySegment(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Byte), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Array(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTime, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTimeOffset, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTime), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTimeOffset), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int52), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.BigInt64) });
                                    }

                                    global::System.Span<global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument> __arguments_buffer = stackalloc global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument[17];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __arg_exception = ref __arguments_buffer[0];
                                    __arg_exception.Initialize();
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __arg_return = ref __arguments_buffer[1];
                                    __arg_return.Initialize();
                                    // Setup - Perform required setup.
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a15_native__js_arg = ref __arguments_buffer[16];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a14_native__js_arg = ref __arguments_buffer[15];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a13_native__js_arg = ref __arguments_buffer[14];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a12_native__js_arg = ref __arguments_buffer[13];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a11_native__js_arg = ref __arguments_buffer[12];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a10_native__js_arg = ref __arguments_buffer[11];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a9_native__js_arg = ref __arguments_buffer[10];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a8_native__js_arg = ref __arguments_buffer[9];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a7_native__js_arg = ref __arguments_buffer[8];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a6_native__js_arg = ref __arguments_buffer[7];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a5_native__js_arg = ref __arguments_buffer[6];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a4_native__js_arg = ref __arguments_buffer[5];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a3_native__js_arg = ref __arguments_buffer[4];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a2_native__js_arg = ref __arguments_buffer[3];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a1_native__js_arg = ref __arguments_buffer[2];
                                    // PinnedMarshal - Convert managed data to native data that requires the managed data to be pinned.
                                    __a15_native__js_arg.ToJS(a15, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, long __task_result) =>
                                    {
                                        __task_result_arg.ToJSBig(__task_result);
                                    });
                                    __a14_native__js_arg.ToJS(a14, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, long __task_result) =>
                                    {
                                        __task_result_arg.ToJS(__task_result);
                                    });
                                    __a13_native__js_arg.ToJS(a13, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, global::System.DateTimeOffset __task_result) =>
                                    {
                                        __task_result_arg.ToJS(__task_result);
                                    });
                                    __a12_native__js_arg.ToJS(a12, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, global::System.DateTime __task_result) =>
                                    {
                                        __task_result_arg.ToJS(__task_result);
                                    });
                                    __a11_native__js_arg.ToJS(a11);
                                    __a10_native__js_arg.ToJS(a10);
                                    __a9_native__js_arg.ToJS(a9);
                                    __a8_native__js_arg.ToJS(a8, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, object __task_result) =>
                                    {
                                        __task_result_arg.ToJS(__task_result);
                                    });
                                    __a7_native__js_arg.ToJS(a7);
                                    __a6_native__js_arg.ToJS(a6);
                                    __a5_native__js_arg.ToJS(a5, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __delegate_arg_arg1, int __delegate_arg1) =>
                                    {
                                        __delegate_arg_arg1.ToJS(__delegate_arg1);
                                    });
                                    __a4_native__js_arg.ToJS(a4);
                                    __a3_native__js_arg.ToJSBig(a3);
                                    __a2_native__js_arg.ToJS(a2);
                                    __a1_native__js_arg.ToJS(a1);
                                    global::System.Runtime.InteropServices.JavaScript.JSFunctionBinding.InvokeJS(__signature_Annotated_1583225186, __arguments_buffer);
                                }

                                static global::System.Runtime.InteropServices.JavaScript.JSFunctionBinding __signature_Annotated_1583225186;
                            }
                        
                            """.ReplaceLineEndings("\r\n"), Encoding.UTF8)),
                        (typeof(Microsoft.Interop.JavaScript.JSExportGenerator),
                        "JSExports.g.cs",
                        SourceText.From("""
                            // <auto-generated/>
                            namespace System.Runtime.InteropServices.JavaScript
                            {
                                [global::System.Runtime.CompilerServices.CompilerGeneratedAttribute]
                                unsafe class __GeneratedInitializer
                                {
                                    [global::System.ThreadStaticAttribute]
                                    static bool initialized;
                                    [global::System.Runtime.CompilerServices.ModuleInitializerAttribute, global::System.Diagnostics.CodeAnalysis.DynamicDependencyAttribute(global::System.Diagnostics.CodeAnalysis.DynamicallyAccessedMemberTypes.PublicMethods | global::System.Diagnostics.CodeAnalysis.DynamicallyAccessedMemberTypes.NonPublicMethods, "System.Runtime.InteropServices.JavaScript.__GeneratedInitializer", "TestProject")]
                                    static internal void __TrimmingPreserve_()
                                    {
                                    }

                                    [global::System.Diagnostics.CodeAnalysis.DynamicDependencyAttribute("__Wrapper_AnnotatedExport_1583225186", "Basic", "TestProject")]
                                    static void __Register_()
                                    {
                                        if (initialized || global::System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != global::System.Runtime.InteropServices.Architecture.Wasm)
                                            return;
                                        initialized = true;
                                        global::System.Runtime.InteropServices.JavaScript.JSFunctionBinding.BindManagedFunction("[TestProject]Basic:AnnotatedExport", 1583225186, new global::System.Runtime.InteropServices.JavaScript.JSMarshalerType[] { global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Discard, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int52, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.BigInt64, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Action(), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Function(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int32), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Span(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Byte), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.ArraySegment(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Byte), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Array(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Object), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTime, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTimeOffset, global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTime), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.DateTimeOffset), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Int52), global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.Task(global::System.Runtime.InteropServices.JavaScript.JSMarshalerType.BigInt64) });
                                    }
                                }
                            }
                            unsafe partial class Basic
                            {
                                [global::System.Diagnostics.DebuggerNonUserCode]
                                internal static unsafe void __Wrapper_AnnotatedExport_1583225186(global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument* __arguments_buffer)
                                {
                                    object a1;
                                    long a2;
                                    long a3;
                                    global::System.Action a4;
                                    global::System.Func<int> a5;
                                    global::System.Span<byte> a6;
                                    global::System.ArraySegment<byte> a7;
                                    global::System.Threading.Tasks.Task<object> a8;
                                    object[] a9;
                                    global::System.DateTime a10;
                                    global::System.DateTimeOffset a11;
                                    global::System.Threading.Tasks.Task<global::System.DateTime> a12;
                                    global::System.Threading.Tasks.Task<global::System.DateTimeOffset> a13;
                                    global::System.Threading.Tasks.Task<long> a14;
                                    global::System.Threading.Tasks.Task<long> a15;
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __arg_exception = ref __arguments_buffer[0];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __arg_return = ref __arguments_buffer[1];
                                    // Setup - Perform required setup.
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a15_native__js_arg = ref __arguments_buffer[16];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a14_native__js_arg = ref __arguments_buffer[15];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a13_native__js_arg = ref __arguments_buffer[14];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a12_native__js_arg = ref __arguments_buffer[13];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a11_native__js_arg = ref __arguments_buffer[12];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a10_native__js_arg = ref __arguments_buffer[11];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a9_native__js_arg = ref __arguments_buffer[10];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a8_native__js_arg = ref __arguments_buffer[9];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a7_native__js_arg = ref __arguments_buffer[8];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a6_native__js_arg = ref __arguments_buffer[7];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a5_native__js_arg = ref __arguments_buffer[6];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a4_native__js_arg = ref __arguments_buffer[5];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a3_native__js_arg = ref __arguments_buffer[4];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a2_native__js_arg = ref __arguments_buffer[3];
                                    ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __a1_native__js_arg = ref __arguments_buffer[2];
                                    try
                                    {
                                        // Unmarshal - Convert native data to managed data.
                                        __a15_native__js_arg.ToManaged(out a15, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, out long __task_result) =>
                                        {
                                            __task_result_arg.ToManagedBig(out __task_result);
                                        });
                                        __a14_native__js_arg.ToManaged(out a14, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, out long __task_result) =>
                                        {
                                            __task_result_arg.ToManaged(out __task_result);
                                        });
                                        __a13_native__js_arg.ToManaged(out a13, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, out global::System.DateTimeOffset __task_result) =>
                                        {
                                            __task_result_arg.ToManaged(out __task_result);
                                        });
                                        __a12_native__js_arg.ToManaged(out a12, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, out global::System.DateTime __task_result) =>
                                        {
                                            __task_result_arg.ToManaged(out __task_result);
                                        });
                                        __a11_native__js_arg.ToManaged(out a11);
                                        __a10_native__js_arg.ToManaged(out a10);
                                        __a9_native__js_arg.ToManaged(out a9);
                                        __a8_native__js_arg.ToManaged(out a8, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __task_result_arg, out object __task_result) =>
                                        {
                                            __task_result_arg.ToManaged(out __task_result);
                                        });
                                        __a7_native__js_arg.ToManaged(out a7);
                                        __a6_native__js_arg.ToManaged(out a6);
                                        __a5_native__js_arg.ToManaged(out a5, static (ref global::System.Runtime.InteropServices.JavaScript.JSMarshalerArgument __delegate_arg_arg1, out int __delegate_arg1) =>
                                        {
                                            __delegate_arg_arg1.ToManaged(out __delegate_arg1);
                                        });
                                        __a4_native__js_arg.ToManaged(out a4);
                                        __a3_native__js_arg.ToManagedBig(out a3);
                                        __a2_native__js_arg.ToManaged(out a2);
                                        __a1_native__js_arg.ToManaged(out a1);
                                        Basic.AnnotatedExport(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15);
                                    }
                                    catch (global::System.Exception ex)
                                    {
                                        __arg_exception.ToJS(ex);
                                    }
                                }
                            }
                            
                            """.ReplaceLineEndings("\r\n"), Encoding.UTF8)),
                    }
                },
            };

            await test.RunAsync();
        }

        private sealed class Test : CSharpAnalyzerTest<EmptyDiagnosticAnalyzer, DefaultVerifier>
        {
            public Test()
            {
                ReferenceAssemblies = new ReferenceAssemblies(string.Empty);
                TestState.AdditionalReferences.AddRange(SourceGenerators.Tests.LiveReferencePack.GetMetadataReferences());
            }

            protected override IEnumerable<Type> GetSourceGenerators()
                => [typeof(Microsoft.Interop.JavaScript.JSImportGenerator), typeof(Microsoft.Interop.JavaScript.JSExportGenerator)];
        }
    }
}
