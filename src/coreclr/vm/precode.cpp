// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
// precode.cpp
//

//
// Stub that runs before the actual native code
//


#include "common.h"

#ifdef FEATURE_PERFMAP
#include "perfmap.h"
#endif

//==========================================================================================
// class Precode
//==========================================================================================
BOOL Precode::IsValidType(PrecodeType t)
{
    LIMITED_METHOD_CONTRACT;
    SUPPORTS_DAC;

    switch (t) {
    case PRECODE_STUB:
#ifdef HAS_NDIRECT_IMPORT_PRECODE
    case PRECODE_NDIRECT_IMPORT:
#endif // HAS_NDIRECT_IMPORT_PRECODE
#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
#endif // HAS_FIXUP_PRECODE
#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
#endif // HAS_THISPTR_RETBUF_PRECODE
        return TRUE;
    default:
        return FALSE;
    }
}

SIZE_T Precode::SizeOf(PrecodeType t)
{
    LIMITED_METHOD_CONTRACT;
    SUPPORTS_DAC;

    switch (t)
    {
    case PRECODE_STUB:
        return sizeof(StubPrecode);
#ifdef HAS_NDIRECT_IMPORT_PRECODE
    case PRECODE_NDIRECT_IMPORT:
        return sizeof(NDirectImportPrecode);
#endif // HAS_NDIRECT_IMPORT_PRECODE
#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
        return sizeof(FixupPrecode);
#endif // HAS_FIXUP_PRECODE
#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
        return sizeof(ThisPtrRetBufPrecode);
#endif // HAS_THISPTR_RETBUF_PRECODE

    default:
        UnexpectedPrecodeType("Precode::SizeOf", t);
        break;
    }
    return 0;
}

// Note: This is immediate target of the precode. It does not follow jump stub if there is one.
PCODE Precode::GetTarget()
{
    LIMITED_METHOD_CONTRACT;
    SUPPORTS_DAC;

    PCODE target = 0;

    PrecodeType precodeType = GetType();
    switch (precodeType)
    {
    case PRECODE_STUB:
        target = AsStubPrecode()->GetTarget();
        break;
#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
        target = AsFixupPrecode()->GetTarget();
        break;
#endif // HAS_FIXUP_PRECODE
#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
        target = AsThisPtrRetBufPrecode()->GetTarget();
        break;
#endif // HAS_THISPTR_RETBUF_PRECODE

    default:
        UnexpectedPrecodeType("Precode::GetTarget", precodeType);
        break;
    }
    return target;
}

MethodDesc* Precode::GetMethodDesc(BOOL fSpeculative /*= FALSE*/)
{
    CONTRACTL {
        NOTHROW;
        GC_NOTRIGGER;
        SUPPORTS_DAC;
    } CONTRACTL_END;

    TADDR pMD = (TADDR)NULL;

    PrecodeType precodeType = GetType();
    switch (precodeType)
    {
    case PRECODE_STUB:
        pMD = AsStubPrecode()->GetMethodDesc();
        break;
#ifdef HAS_NDIRECT_IMPORT_PRECODE
    case PRECODE_NDIRECT_IMPORT:
        pMD = AsNDirectImportPrecode()->GetMethodDesc();
        break;
#endif // HAS_NDIRECT_IMPORT_PRECODE
#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
        pMD = AsFixupPrecode()->GetMethodDesc();
        break;
#endif // HAS_FIXUP_PRECODE
#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
        pMD = AsThisPtrRetBufPrecode()->GetMethodDesc();
        break;
#endif // HAS_THISPTR_RETBUF_PRECODE

    default:
        break;
    }

    if (pMD == (TADDR)NULL)
    {
        if (fSpeculative)
            return NULL;
        else
            UnexpectedPrecodeType("Precode::GetMethodDesc", precodeType);
    }

    // GetMethodDesc() on platform specific precode types returns TADDR. It should return
    // PTR_MethodDesc instead. It is a workaround to resolve cyclic dependency between headers.
    // Once we headers factoring of headers cleaned up, we should be able to get rid of it.
    return (PTR_MethodDesc)pMD;
}

BOOL Precode::IsPointingToPrestub(PCODE target)
{
    CONTRACTL
    {
        NOTHROW;
        GC_NOTRIGGER;
        MODE_ANY;
    }
    CONTRACTL_END;

    if (IsPointingTo(target, GetPreStubEntryPoint()))
        return TRUE;

#ifdef HAS_FIXUP_PRECODE
    if (IsPointingTo(target, ((PCODE)this + FixupPrecode::FixupCodeOffset)))
        return TRUE;
#endif

    return FALSE;
}

// If addr is patched fixup precode, returns address that it points to. Otherwise returns NULL.
PCODE Precode::TryToSkipFixupPrecode(PCODE addr)
{
    CONTRACTL {
        NOTHROW;
        GC_NOTRIGGER;
    } CONTRACTL_END;

    return 0;
}

#ifndef DACCESS_COMPILE

Precode* Precode::Allocate(PrecodeType t, MethodDesc* pMD,
                           LoaderAllocator *  pLoaderAllocator,
                           AllocMemTracker *  pamTracker)
{
    CONTRACTL
    {
        THROWS;
        GC_NOTRIGGER;
        MODE_ANY;
    }
    CONTRACTL_END;

    SIZE_T size = Precode::SizeOf(t);
    Precode* pPrecode;

    if (t == PRECODE_FIXUP)
    {
        pPrecode = (Precode*)pamTracker->Track(pLoaderAllocator->GetFixupPrecodeHeap()->AllocAlignedMem(size, 1));
        pPrecode->Init(pPrecode, t, pMD, pLoaderAllocator);
    }
    else if (t == PRECODE_STUB || t == PRECODE_NDIRECT_IMPORT)
    {
        pPrecode = (Precode*)pamTracker->Track(pLoaderAllocator->GetNewStubPrecodeHeap()->AllocAlignedMem(size, 1));
        pPrecode->Init(pPrecode, t, pMD, pLoaderAllocator);
    }
    else
    {
        pPrecode = (Precode*)pamTracker->Track(pLoaderAllocator->GetPrecodeHeap()->AllocAlignedMem(size, AlignOf(t)));
        ExecutableWriterHolder<Precode> precodeWriterHolder(pPrecode, size);
        precodeWriterHolder.GetRW()->Init(pPrecode, t, pMD, pLoaderAllocator);
        ClrFlushInstructionCache(pPrecode, size);

    }

    return pPrecode;
}

void Precode::Init(Precode* pPrecodeRX, PrecodeType t, MethodDesc* pMD, LoaderAllocator *pLoaderAllocator)
{
    LIMITED_METHOD_CONTRACT;

    switch (t) {
    case PRECODE_STUB:
        ((StubPrecode*)this)->Init((StubPrecode*)pPrecodeRX, pMD, pLoaderAllocator);
        break;
#ifdef HAS_NDIRECT_IMPORT_PRECODE
    case PRECODE_NDIRECT_IMPORT:
        ((NDirectImportPrecode*)this)->Init((NDirectImportPrecode*)pPrecodeRX, pMD, pLoaderAllocator);
        break;
#endif // HAS_NDIRECT_IMPORT_PRECODE
#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
        ((FixupPrecode*)this)->Init((FixupPrecode*)pPrecodeRX, pMD, pLoaderAllocator);
        break;
#endif // HAS_FIXUP_PRECODE
#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
        ((ThisPtrRetBufPrecode*)this)->Init(pMD, pLoaderAllocator);
        break;
#endif // HAS_THISPTR_RETBUF_PRECODE
    default:
        UnexpectedPrecodeType("Precode::Init", t);
        break;
    }

    _ASSERTE(IsValidType(GetType()));
}

void Precode::ResetTargetInterlocked()
{
    WRAPPER_NO_CONTRACT;

    PrecodeType precodeType = GetType();
    switch (precodeType)
    {
        case PRECODE_STUB:
            AsStubPrecode()->ResetTargetInterlocked();
            break;

#ifdef HAS_FIXUP_PRECODE
        case PRECODE_FIXUP:
            AsFixupPrecode()->ResetTargetInterlocked();
            break;
#endif // HAS_FIXUP_PRECODE

        default:
            UnexpectedPrecodeType("Precode::ResetTargetInterlocked", precodeType);
            break;
    }

    // Although executable code is modified on x86/x64, a FlushInstructionCache() is not necessary on those platforms due to the
    // interlocked operation above (see ClrFlushInstructionCache())
}

BOOL Precode::SetTargetInterlocked(PCODE target, BOOL fOnlyRedirectFromPrestub)
{
    WRAPPER_NO_CONTRACT;
    _ASSERTE(!IsPointingToPrestub(target));

    PCODE expected = GetTarget();
    BOOL ret = FALSE;

    if (fOnlyRedirectFromPrestub && !IsPointingToPrestub(expected))
        return FALSE;

    PrecodeType precodeType = GetType();
    switch (precodeType)
    {
    case PRECODE_STUB:
        ret = AsStubPrecode()->SetTargetInterlocked(target, expected);
        break;

#ifdef HAS_FIXUP_PRECODE
    case PRECODE_FIXUP:
        ret = AsFixupPrecode()->SetTargetInterlocked(target, expected);
        break;
#endif // HAS_FIXUP_PRECODE

#ifdef HAS_THISPTR_RETBUF_PRECODE
    case PRECODE_THISPTR_RETBUF:
        ret = AsThisPtrRetBufPrecode()->SetTargetInterlocked(target, expected);
        ClrFlushInstructionCache(this, sizeof(ThisPtrRetBufPrecode), /* hasCodeExecutedBefore */ true);
        break;
#endif // HAS_THISPTR_RETBUF_PRECODE

    default:
        UnexpectedPrecodeType("Precode::SetTargetInterlocked", precodeType);
        break;
    }

    // Although executable code is modified on x86/x64, a FlushInstructionCache() is not necessary on those platforms due to the
    // interlocked operation above (see ClrFlushInstructionCache())

    return ret;
}

void Precode::Reset()
{
    WRAPPER_NO_CONTRACT;

    MethodDesc* pMD = GetMethodDesc();

    PrecodeType t = GetType();
    SIZE_T size = Precode::SizeOf(t);

    if (t == PRECODE_FIXUP)
    {
        Init(this, t, pMD, pMD->GetLoaderAllocator());
    }
    else
    {
        ExecutableWriterHolder<Precode> precodeWriterHolder(this, size);
        precodeWriterHolder.GetRW()->Init(this, t, pMD, pMD->GetLoaderAllocator());
        ClrFlushInstructionCache(this, SizeOf(), /* hasCodeExecutedBefore */ true);
    }
}

#endif // !DACCESS_COMPILE

#ifdef DACCESS_COMPILE
void Precode::EnumMemoryRegions(CLRDataEnumMemoryFlags flags)
{
    SUPPORTS_DAC;
    PrecodeType t = GetType();

    DacEnumMemoryRegion(GetStart(), SizeOf(t));
}
#endif

#ifdef HAS_FIXUP_PRECODE

#ifdef DACCESS_COMPILE
void FixupPrecode::EnumMemoryRegions(CLRDataEnumMemoryFlags flags)
{
    SUPPORTS_DAC;
    DacEnumMemoryRegion(dac_cast<TADDR>(this), sizeof(FixupPrecode));
    DacEnumMemoryRegion(dac_cast<TADDR>(GetData()), sizeof(FixupPrecodeData));
}
#endif // DACCESS_COMPILE

#endif // HAS_FIXUP_PRECODE

#ifndef DACCESS_COMPILE

void StubPrecode::Init(StubPrecode* pPrecodeRX, MethodDesc* pMD, LoaderAllocator *pLoaderAllocator /* = NULL */,
    BYTE type /* = StubPrecode::Type */, TADDR target /* = NULL */)
{
    WRAPPER_NO_CONTRACT;

    StubPrecodeData *pStubData = GetData();

    if (pLoaderAllocator != NULL)
    {
        // Use pMD == NULL in all precode initialization methods to allocate the initial jump stub in non-dynamic heap
        // that has the same lifetime like as the precode itself
        if (target == (TADDR)NULL)
            target = GetPreStubEntryPoint();
        pStubData->Target = target;
    }

    pStubData->MethodDesc = pMD;
    pStubData->Type = type;
}

#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
    #define ENUM_PAGE_SIZE(size) \
        extern "C" void StubPrecodeCode##size(); \
        extern "C" void StubPrecodeCode##size##_End();
    ENUM_PAGE_SIZES
    #undef ENUM_PAGE_SIZE
#else
extern "C" void StubPrecodeCode();
extern "C" void StubPrecodeCode_End();
#endif

#ifdef TARGET_X86
extern "C" size_t StubPrecodeCode_MethodDesc_Offset;
extern "C" size_t StubPrecodeCode_Target_Offset;

#define SYMBOL_VALUE(name) ((size_t)&name)

#endif

#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
void (*StubPrecode::StubPrecodeCode)();
void (*StubPrecode::StubPrecodeCode_End)();
#endif

void StubPrecode::StaticInitialize()
{
#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
    #define ENUM_PAGE_SIZE(size) \
        case size: \
            StubPrecodeCode = StubPrecodeCode##size; \
            StubPrecodeCode_End = StubPrecodeCode##size##_End; \
            _ASSERTE((SIZE_T)((BYTE*)StubPrecodeCode##size##_End - (BYTE*)StubPrecodeCode##size) <= StubPrecode::CodeSize); \
            break;

    int pageSize = GetStubCodePageSize();
    switch (pageSize)
    {
        ENUM_PAGE_SIZES
        default:
            EEPOLICY_HANDLE_FATAL_ERROR_WITH_MESSAGE(COR_E_EXECUTIONENGINE, W("Unsupported OS page size"));
    }
    #undef ENUM_PAGE_SIZE
#else
    _ASSERTE((SIZE_T)((BYTE*)StubPrecodeCode_End - (BYTE*)StubPrecodeCode) <= StubPrecode::CodeSize);
#endif
#ifdef TARGET_LOONGARCH64
    _ASSERTE(((*((short*)PCODEToPINSTR((PCODE)StubPrecodeCode) + OFFSETOF_PRECODE_TYPE)) >> 5) == StubPrecode::Type);
#elif TARGET_RISCV64
    _ASSERTE((*((BYTE*)PCODEToPINSTR((PCODE)StubPrecodeCode) + OFFSETOF_PRECODE_TYPE)) == StubPrecode::Type);
#else
    _ASSERTE((*((BYTE*)PCODEToPINSTR((PCODE)StubPrecodeCode) + OFFSETOF_PRECODE_TYPE)) == StubPrecode::Type);
#endif

}

void StubPrecode::GenerateCodePage(BYTE* pageBase, BYTE* pageBaseRX, SIZE_T pageSize)
{
#ifdef TARGET_X86
    int totalCodeSize = (pageSize / StubPrecode::CodeSize) * StubPrecode::CodeSize;
    for (int i = 0; i < totalCodeSize; i += StubPrecode::CodeSize)
    {
        memcpy(pageBase + i, (const void*)StubPrecodeCode, (BYTE*)StubPrecodeCode_End - (BYTE*)StubPrecodeCode);

        BYTE* pTargetSlot = pageBaseRX + i + pageSize + offsetof(StubPrecodeData, Target);
        *(BYTE**)(pageBase + i + SYMBOL_VALUE(StubPrecodeCode_Target_Offset)) = pTargetSlot;

        BYTE* pMethodDescSlot = pageBaseRX + i + pageSize + offsetof(StubPrecodeData, MethodDesc);
        *(BYTE**)(pageBase + i + SYMBOL_VALUE(StubPrecodeCode_MethodDesc_Offset)) = pMethodDescSlot;
    }
#else // TARGET_X86
    FillStubCodePage(pageBase, (const void*)PCODEToPINSTR((PCODE)StubPrecodeCode), StubPrecode::CodeSize, pageSize);
#endif // TARGET_X86
}

BOOL StubPrecode::IsStubPrecodeByASM(PCODE addr)
{
    BYTE *pInstr = (BYTE*)PCODEToPINSTR(addr);
#ifdef TARGET_X86
    return *pInstr == *(BYTE*)(StubPrecodeCode) &&
            *(DWORD*)(pInstr + SYMBOL_VALUE(StubPrecodeCode_MethodDesc_Offset)) == (DWORD)(pInstr + GetStubCodePageSize() + offsetof(StubPrecodeData, MethodDesc)) &&
            *(WORD*)(pInstr + 5) == *(WORD*)((BYTE*)StubPrecodeCode + 5) &&
            *(DWORD*)(pInstr + SYMBOL_VALUE(StubPrecodeCode_Target_Offset)) == (DWORD)(pInstr + GetStubCodePageSize() + offsetof(StubPrecodeData, Target));
#else // TARGET_X86
    BYTE *pTemplateInstr = (BYTE*)PCODEToPINSTR((PCODE)StubPrecodeCode);
    BYTE *pTemplateInstrEnd = (BYTE*)PCODEToPINSTR((PCODE)StubPrecodeCode_End);
    while ((pTemplateInstr < pTemplateInstrEnd) && (*pInstr == *pTemplateInstr))
    {
        pInstr++;
        pTemplateInstr++;
    }

    return pTemplateInstr == pTemplateInstrEnd;
#endif // TARGET_X86
}

#ifdef HAS_NDIRECT_IMPORT_PRECODE

void NDirectImportPrecode::Init(NDirectImportPrecode* pPrecodeRX, MethodDesc* pMD, LoaderAllocator *pLoaderAllocator)
{
    WRAPPER_NO_CONTRACT;
    StubPrecode::Init(pPrecodeRX, pMD, pLoaderAllocator, NDirectImportPrecode::Type, GetEEFuncEntryPoint(NDirectImportThunk));
}

#endif // HAS_NDIRECT_IMPORT_PRECODE

#ifdef HAS_FIXUP_PRECODE
void FixupPrecode::Init(FixupPrecode* pPrecodeRX, MethodDesc* pMD, LoaderAllocator *pLoaderAllocator)
{
    WRAPPER_NO_CONTRACT;

    _ASSERTE(pPrecodeRX == this);

    FixupPrecodeData *pData = GetData();
    pData->MethodDesc = pMD;

    _ASSERTE(GetMethodDesc() == (TADDR)pMD);

    pData->Target = (PCODE)pPrecodeRX + FixupPrecode::FixupCodeOffset;
    pData->PrecodeFixupThunk = GetPreStubEntryPoint();
}

#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
    #define ENUM_PAGE_SIZE(size) \
        extern "C" void FixupPrecodeCode##size(); \
        extern "C" void FixupPrecodeCode##size##_End();
    ENUM_PAGE_SIZES
    #undef ENUM_PAGE_SIZE
#else
extern "C" void FixupPrecodeCode();
extern "C" void FixupPrecodeCode_End();
#endif

#ifdef TARGET_X86
extern "C" size_t FixupPrecodeCode_MethodDesc_Offset;
extern "C" size_t FixupPrecodeCode_Target_Offset;
extern "C" size_t FixupPrecodeCode_PrecodeFixupThunk_Offset;
#endif

#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
void (*FixupPrecode::FixupPrecodeCode)();
void (*FixupPrecode::FixupPrecodeCode_End)();
#endif

void FixupPrecode::StaticInitialize()
{
#if defined(TARGET_ARM64) && defined(TARGET_UNIX)
    #define ENUM_PAGE_SIZE(size) \
        case size: \
            FixupPrecodeCode = FixupPrecodeCode##size; \
            FixupPrecodeCode_End = FixupPrecodeCode##size##_End; \
            _ASSERTE((SIZE_T)((BYTE*)FixupPrecodeCode##size##_End - (BYTE*)FixupPrecodeCode##size) <= FixupPrecode::CodeSize); \
            break;

    int pageSize = GetStubCodePageSize();

    switch (pageSize)
    {
        ENUM_PAGE_SIZES
        default:
            EEPOLICY_HANDLE_FATAL_ERROR_WITH_MESSAGE(COR_E_EXECUTIONENGINE, W("Unsupported OS page size"));
    }
    #undef ENUM_PAGE_SIZE
#else
    _ASSERTE((SIZE_T)((BYTE*)FixupPrecodeCode_End - (BYTE*)FixupPrecodeCode) <= FixupPrecode::CodeSize);
#endif
#ifdef TARGET_LOONGARCH64
    _ASSERTE(((*((short*)PCODEToPINSTR((PCODE)StubPrecodeCode) + OFFSETOF_PRECODE_TYPE)) >> 5) == StubPrecode::Type);
#elif TARGET_RISCV64
    _ASSERTE((*((BYTE*)PCODEToPINSTR((PCODE)FixupPrecodeCode) + OFFSETOF_PRECODE_TYPE)) == FixupPrecode::Type);
#else
    _ASSERTE(*((BYTE*)PCODEToPINSTR((PCODE)FixupPrecodeCode) + OFFSETOF_PRECODE_TYPE) == FixupPrecode::Type);
#endif
}

void FixupPrecode::GenerateCodePage(BYTE* pageBase, BYTE* pageBaseRX, SIZE_T pageSize)
{
#ifdef TARGET_X86
    int totalCodeSize = (pageSize / FixupPrecode::CodeSize) * FixupPrecode::CodeSize;

    for (int i = 0; i < totalCodeSize; i += FixupPrecode::CodeSize)
    {
        memcpy(pageBase + i, (const void*)FixupPrecodeCode, FixupPrecode::CodeSize);
        BYTE* pTargetSlot = pageBaseRX + i + pageSize + offsetof(FixupPrecodeData, Target);
        *(BYTE**)(pageBase + i + SYMBOL_VALUE(FixupPrecodeCode_Target_Offset)) = pTargetSlot;

        BYTE* pMethodDescSlot = pageBaseRX + i + pageSize + offsetof(FixupPrecodeData, MethodDesc);
        *(BYTE**)(pageBase + i + SYMBOL_VALUE(FixupPrecodeCode_MethodDesc_Offset)) = pMethodDescSlot;

        BYTE* pPrecodeFixupThunkSlot = pageBaseRX + i + pageSize + offsetof(FixupPrecodeData, PrecodeFixupThunk);
        *(BYTE**)(pageBase + i + SYMBOL_VALUE(FixupPrecodeCode_PrecodeFixupThunk_Offset)) = pPrecodeFixupThunkSlot;
    }
#else // TARGET_X86
    FillStubCodePage(pageBase, (const void*)PCODEToPINSTR((PCODE)FixupPrecodeCode), FixupPrecode::CodeSize, pageSize);
#endif // TARGET_X86
}

BOOL FixupPrecode::IsFixupPrecodeByASM(PCODE addr)
{
    BYTE *pInstr = (BYTE*)PCODEToPINSTR(addr);
#ifdef TARGET_X86
    return
        *(WORD*)(pInstr) == *(WORD*)(FixupPrecodeCode) &&
        *(DWORD*)(pInstr + SYMBOL_VALUE(FixupPrecodeCode_Target_Offset)) == (DWORD)(pInstr + GetStubCodePageSize() + offsetof(FixupPrecodeData, Target)) &&
        *(pInstr + 6) == *((BYTE*)FixupPrecodeCode + 6) &&
        *(DWORD*)(pInstr + SYMBOL_VALUE(FixupPrecodeCode_MethodDesc_Offset)) == (DWORD)(pInstr + GetStubCodePageSize() + offsetof(FixupPrecodeData, MethodDesc)) &&
        *(WORD*)(pInstr + 11) == *(WORD*)((BYTE*)FixupPrecodeCode + 11) &&
        *(DWORD*)(pInstr + SYMBOL_VALUE(FixupPrecodeCode_PrecodeFixupThunk_Offset)) == (DWORD)(pInstr + GetStubCodePageSize() + offsetof(FixupPrecodeData, PrecodeFixupThunk));
#else // TARGET_X86
    BYTE *pTemplateInstr = (BYTE*)PCODEToPINSTR((PCODE)FixupPrecodeCode);
    BYTE *pTemplateInstrEnd = (BYTE*)PCODEToPINSTR((PCODE)FixupPrecodeCode_End);
    while ((pTemplateInstr < pTemplateInstrEnd) && (*pInstr == *pTemplateInstr))
    {
        pInstr++;
        pTemplateInstr++;
    }

    return pTemplateInstr == pTemplateInstrEnd;
#endif // TARGET_X86
}

#endif // HAS_FIXUP_PRECODE

BOOL DoesSlotCallPrestub(PCODE pCode)
{
    CONTRACTL {
        NOTHROW;
        GC_NOTRIGGER;
        PRECONDITION(pCode != GetPreStubEntryPoint());
    } CONTRACTL_END;

    TADDR pInstr = dac_cast<TADDR>(PCODEToPINSTR(pCode));

    if (!IS_ALIGNED(pInstr, PRECODE_ALIGNMENT))
    {
        return FALSE;
    }

    //FixupPrecode
#if defined(HAS_FIXUP_PRECODE)
    if (FixupPrecode::IsFixupPrecodeByASM(pCode))
    {
        PCODE pTarget = dac_cast<PTR_FixupPrecode>(pInstr)->GetTarget();

        return pTarget == PCODEToPINSTR(pCode) + FixupPrecode::FixupCodeOffset;
    }
#endif

    // StubPrecode
    if (StubPrecode::IsStubPrecodeByASM(pCode))
    {
        pCode = dac_cast<PTR_StubPrecode>(pInstr)->GetTarget();
        return pCode == GetPreStubEntryPoint();
    }

    return FALSE;
}

void PrecodeMachineDescriptor::Init(PrecodeMachineDescriptor *dest)
{
    dest->OffsetOfPrecodeType = OFFSETOF_PRECODE_TYPE;
    // cDAC will do (where N = 8*ReadWidthOfPrecodeType):
    //   uintN_t PrecodeType = *(uintN_t*)(pPrecode + OffsetOfPrecodeType);
    //   PrecodeType >>= ShiftOfPrecodeType;
    //   return (byte)PrecodeType;
#ifdef TARGET_LOONGARCH64
    dest->ReadWidthOfPrecodeType = 2;
#else
    dest->ReadWidthOfPrecodeType = 1;
#endif
#if defined(SHIFTOF_PRECODE_TYPE)
    dest->ShiftOfPrecodeType = SHIFTOF_PRECODE_TYPE;
#else
    dest->ShiftOfPrecodeType = 0;
#endif

    dest->InvalidPrecodeType = InvalidPrecode::Type;
    dest->StubPrecodeType = StubPrecode::Type;
#ifdef HAS_NDIRECT_IMPORT_PRECODE
    dest->PInvokeImportPrecodeType = NDirectImportPrecode::Type;
#endif // HAS_NDIRECT_IMPORT_PRECODE
#ifdef HAS_FIXUP_PRECODE
    dest->FixupPrecodeType = FixupPrecode::Type;
#endif
#ifdef HAS_THISPTR_RETBUF_PRECODE
    dest->ThisPointerRetBufPrecodeType = ThisPtrRetBufPrecode::Type;
#endif
    dest->StubCodePageSize = GetStubCodePageSize();
}

#endif // !DACCESS_COMPILE

