// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#pragma once
#pragma warning(disable : 4503) // 'identifier' : decorated name length exceeded, name was truncated

#include "compiler.h"
#include "ssarenamestate.h"

typedef int LclVarNum;

// Pair of a local var name eg: V01 and Ssa number; eg: V01_01
typedef std::pair<LclVarNum, int> SsaVarName;

struct UseDefLocation
{
    BasicBlock*    Block = nullptr;
    Statement*     Stmt  = nullptr;
    GenTreeLclVar* Tree  = nullptr;

    UseDefLocation()
    {
    }

    UseDefLocation(BasicBlock* block, Statement* stmt, GenTreeLclVar* tree)
        : Block(block)
        , Stmt(stmt)
        , Tree(tree)
    {
    }
};

class SsaBuilder
{
    friend class IncrementalSsaBuilder;

private:
    inline void EndPhase(Phases phase)
    {
        m_pCompiler->EndPhase(phase);
    }

public:
    // Constructor
    SsaBuilder(Compiler* pCompiler);

    // Requires stmt nodes to be already sequenced in evaluation order. Analyzes the graph
    // for introduction of phi-nodes as GT_PHI tree nodes at the beginning of each block.
    // Each GT_LCL_VAR is given its ssa number through its GetSsaNum() field in the node.
    // Each GT_PHI node will be under a STORE_LCL_VAR node as the store's value operand.
    // The inputs to the PHI are represented as a linked list of GT_PHI_ARG nodes. Each
    // use or def is denoted by the corresponding local nodes. All defs of a particular
    // variable are stored in the "per SSA data" on the local descriptor.
    void Build();

private:
    // Insert a new GT_PHI statement.
    static Statement* InsertPhi(Compiler* comp, BasicBlock* block, unsigned lclNum);

    // Add a new GT_PHI_ARG node to an existing GT_PHI node
    void AddPhiArg(
        BasicBlock* block, Statement* stmt, GenTreePhi* phi, unsigned lclNum, unsigned ssaNum, BasicBlock* pred);

    static void AddNewPhiArg(Compiler*   comp,
                             BasicBlock* block,
                             Statement*  stmt,
                             GenTreePhi* phi,
                             unsigned    lclNum,
                             unsigned    ssaNum,
                             BasicBlock* pred);

    // Requires "postOrder" to hold the blocks of the flowgraph in topologically sorted order. Requires
    // count to be the valid entries in the "postOrder" array. Inserts GT_PHI nodes at the beginning
    // of basic blocks that require them.
    void InsertPhiFunctions();

    // Rename all definitions and uses within the compiled method.
    void RenameVariables();
    // Rename all definitions and uses within a block.
    void BlockRenameVariables(BasicBlock* block);
    // Rename a local or memory definition generated by a local store/GT_CALL node.
    void     RenameDef(GenTree* defNode, BasicBlock* block);
    unsigned RenamePushDef(GenTree* defNode, BasicBlock* block, unsigned lclNum, bool isFullDef);
    // Rename a use of a local variable.
    void RenameLclUse(GenTreeLclVarCommon* lclNode, BasicBlock* block);

    // Assumes that "block" contains a definition for local var "lclNum", with SSA number "ssaNum".
    // IF "block" is within one or more blocks with EH successors,
    // and the local variable is live at the start of the corresponding successors,
    // add this SSA number "ssaNum" to the argument list of the phi for the variable in the start
    // block of those handlers.
    void AddDefToEHSuccessorPhis(BasicBlock* block, unsigned lclNum, unsigned ssaNum);

    // Same as above, for memory.
    void AddMemoryDefToEHSuccessorPhis(MemoryKind memoryKind, BasicBlock* block, unsigned ssaNum);

    // Add GT_PHI_ARG nodes to the GT_PHI nodes within block's successors.
    void AddPhiArgsToSuccessors(BasicBlock* block);

    // Similar to Add[Memory]DefToEHSuccessorPhis, but adds initial values to
    // the handlers of a newly entered block based on one entering block.
    void AddPhiArgsToNewlyEnteredHandler(BasicBlock* predEnterBlock, BasicBlock* enterBlock, BasicBlock* handlerStart);

    Compiler*      m_pCompiler;
    CompAllocator  m_allocator;
    SsaRenameState m_renameStack;
};

class IncrementalLiveInBuilder
{
    Compiler*               m_comp;
    ArrayStack<BasicBlock*> m_queue;

public:
    IncrementalLiveInBuilder(Compiler* comp)
        : m_comp(comp)
        , m_queue(comp->getAllocator(CMK_SSA))
    {
    }

    void MarkLiveInBackwards(unsigned lclNum, const UseDefLocation& use, const UseDefLocation& reachingDef);
};

class IncrementalSsaBuilder
{
    Compiler*                  m_comp;
    unsigned                   m_lclNum;
    ArrayStack<UseDefLocation> m_defs;
    BitVecTraits               m_poTraits;
    BitVec                     m_defBlocks                  = BitVecOps::UninitVal();
    BitVec                     m_iteratedDominanceFrontiers = BitVecOps::UninitVal();
    IncrementalLiveInBuilder   m_liveInBuilder;

#ifdef DEBUG
    bool m_finalizedDefs = false;
#endif

    UseDefLocation FindOrCreateReachingDef(const UseDefLocation& use);
    bool           FindReachingDefInBlock(const UseDefLocation& use, BasicBlock* block, UseDefLocation* def);
    bool           FindReachingDefInSameStatement(const UseDefLocation& use, UseDefLocation* def);
    Statement*     LatestStatement(Statement* stmt1, Statement* stmt2);
public:
    IncrementalSsaBuilder(Compiler* comp, unsigned lclNum)
        : m_comp(comp)
        , m_lclNum(lclNum)
        , m_defs(comp->getAllocator(CMK_SSA))
        , m_poTraits(0, comp)
        , m_liveInBuilder(comp)
    {
    }

    void InsertDef(const UseDefLocation& def);
    bool FinalizeDefs();
    bool InsertUse(const UseDefLocation& use);
};
