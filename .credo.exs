# Credo configuration file. See https://github.com/rrrene/credo for details.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      # v0.1.0 alpha: permissive. Real bugs only, not style.
      checks: %{
        enabled: [
          # Warnings — these catch real bugs
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute},
          {Credo.Check.Warning.BoolOperationOnSameValues},
          {Credo.Check.Warning.Dbg},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck},
          {Credo.Check.Warning.IExPry},
          {Credo.Check.Warning.IoInspect},
          {Credo.Check.Warning.OperationOnSameValues},
          {Credo.Check.Warning.OperationWithConstantResult},
          {Credo.Check.Warning.RaiseInsideRescue},
          {Credo.Check.Warning.SpecWithStruct},
          {Credo.Check.Warning.UnusedEnumOperation},
          {Credo.Check.Warning.UnusedFileOperation},
          {Credo.Check.Warning.UnusedKeywordOperation},
          {Credo.Check.Warning.UnusedListOperation},
          {Credo.Check.Warning.UnusedPathOperation},
          {Credo.Check.Warning.UnusedRegexOperation},
          {Credo.Check.Warning.UnusedStringOperation},
          {Credo.Check.Warning.UnusedTupleOperation},
          {Credo.Check.Warning.UnsafeExec},
          # Refactor — catch complexity and nesting issues
          {Credo.Check.Refactor.CondStatements},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 15},
          {Credo.Check.Refactor.FunctionArity, max_arity: 8},
          {Credo.Check.Refactor.LongQuoteBlocks},
          {Credo.Check.Refactor.MatchInCondition},
          {Credo.Check.Refactor.NegatedConditionsInUnless},
          {Credo.Check.Refactor.NegatedConditionsWithElse},
          {Credo.Check.Refactor.Nesting, max_nesting: 5},
          {Credo.Check.Refactor.UnlessWithElse},
          {Credo.Check.Refactor.RedundantWithClauseResult},
          # Design
          {Credo.Check.Design.TagTODO},
          {Credo.Check.Design.TagFIXME}
        ],
        disabled: [
          # Style issues are ignored in v0.1.0 alpha
          # Re-enable in v0.2.0 with a stricter config
        ]
      }
    }
  ]
}
