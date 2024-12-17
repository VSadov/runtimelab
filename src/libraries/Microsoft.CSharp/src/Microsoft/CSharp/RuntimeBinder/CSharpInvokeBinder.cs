// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Dynamic;
using System.Numerics.Hashing;
using Microsoft.CSharp.RuntimeBinder.Errors;
using Microsoft.CSharp.RuntimeBinder.Semantics;

namespace Microsoft.CSharp.RuntimeBinder
{
    /// <summary>
    /// Represents a dynamic delegate-like call in C#, providing the binding semantics and the details about the operation.
    /// Instances of this class are generated by the C# compiler.
    /// </summary>
    [RequiresUnreferencedCode(Binder.TrimmerWarning)]
    internal sealed class CSharpInvokeBinder : InvokeBinder, ICSharpInvokeOrInvokeMemberBinder
    {
        public BindingFlag BindingFlags => 0;

        public Expr DispatchPayload(RuntimeBinder runtimeBinder, ArgumentObject[] arguments, LocalVariableSymbol[] locals)
            => runtimeBinder.DispatchPayload(this, arguments, locals);

        public void PopulateSymbolTableWithName(Type callingType, ArgumentObject[] arguments)
            => RuntimeBinder.PopulateSymbolTableWithPayloadInformation(this, callingType, arguments);

        public bool IsBinderThatCanHaveRefReceiver => true;

        bool ICSharpInvokeOrInvokeMemberBinder.StaticCall => _argumentInfo[0] != null && _argumentInfo[0].IsStaticType;

        string ICSharpBinder.Name => "Invoke";

        Type[] ICSharpInvokeOrInvokeMemberBinder.TypeArguments => Type.EmptyTypes;

        CSharpCallFlags ICSharpInvokeOrInvokeMemberBinder.Flags => _flags;

        private readonly CSharpCallFlags _flags;

        private readonly CSharpArgumentInfo[] _argumentInfo;

        CSharpArgumentInfo ICSharpBinder.GetArgumentInfo(int index) => _argumentInfo[index];

        bool ICSharpInvokeOrInvokeMemberBinder.ResultDiscarded => (_flags & CSharpCallFlags.ResultDiscarded) != 0;

        private readonly RuntimeBinder _binder;

        private readonly Type _callingContext;

        /// <summary>
        /// Initializes a new instance of the <see cref="CSharpInvokeBinder" />.
        /// </summary>
        /// <param name="flags">Extra information about this operation that is not specific to any particular argument.</param>
        /// <param name="callingContext">The <see cref="System.Type"/> that indicates where this operation is defined.</param>
        /// <param name="argumentInfo">The sequence of <see cref="CSharpArgumentInfo"/> instances for the arguments to this operation.</param>
        public CSharpInvokeBinder(
                CSharpCallFlags flags,
                Type callingContext,
                IEnumerable<CSharpArgumentInfo> argumentInfo) :
            base(BinderHelper.CreateCallInfo(ref argumentInfo, 1)) // discard 1 argument: the target object (even if static, arg is type)
        {
            _flags = flags;
            _callingContext = callingContext;
            _argumentInfo = argumentInfo as CSharpArgumentInfo[];
            _binder = new RuntimeBinder(callingContext);
        }

        public int GetGetBinderEquivalenceHash()
        {
            int hash = _callingContext?.GetHashCode() ?? 0;
            hash = HashHelpers.Combine(hash, (int)_flags);
            hash = BinderHelper.AddArgHashes(hash, _argumentInfo);

            return hash;
        }

        public bool IsEquivalentTo(ICSharpBinder other)
        {
            var otherBinder = other as CSharpInvokeBinder;
            if (otherBinder == null)
            {
                return false;
            }

            if (_flags != otherBinder._flags ||
                _callingContext != otherBinder._callingContext ||
                _argumentInfo.Length != otherBinder._argumentInfo.Length)
            {
                return false;
            }

            return BinderHelper.CompareArgInfos(_argumentInfo, otherBinder._argumentInfo);
        }

        /// <summary>
        /// Performs the binding of the dynamic invoke operation if the target dynamic object cannot bind.
        /// </summary>
        /// <param name="target">The target of the dynamic invoke operation.</param>
        /// <param name="args">The arguments of the dynamic invoke operation.</param>
        /// <param name="errorSuggestion">The binding result to use if binding fails, or null.</param>
        /// <returns>The <see cref="DynamicMetaObject"/> representing the result of the binding.</returns>
        public override DynamicMetaObject FallbackInvoke(DynamicMetaObject target, DynamicMetaObject[] args, DynamicMetaObject errorSuggestion)
        {
#if ENABLECOMBINDER
            DynamicMetaObject com;
            if (ComInterop.ComBinder.TryBindInvoke(this, target, args, out com))
            {
                return com;
            }
#else
            BinderHelper.ThrowIfUsingDynamicCom(target);
#endif

            BinderHelper.ValidateBindArgument(target, nameof(target));
            BinderHelper.ValidateBindArgument(args, nameof(args));
            return BinderHelper.Bind(this, _binder, BinderHelper.Cons(target, args), _argumentInfo, errorSuggestion);
        }
    }
}
