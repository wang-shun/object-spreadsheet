VarName = {
}
OptionalVarName = {
}
EagerFamilyRef = {
}
Statements = {
}

# Dummies, TBD how to implement this.
EagerSubformula = null
LazySubformula = null

dispatch = {
  let:
    argAdapters: [VarName, EagerSubformula]
  set:
    argAdapters: [EagerFamilyRef, EagerSubformula]
  add:
    argAdapters: [EagerFamilyRef, EagerSubformula]
  remove:
    argAdapters: [EagerFamilyRef, EagerSubformula]
  if:
    argAdapters: [EagerSubformula, Statements, Statements]
  foreach:
    argAdapters: [VarName, EagerSubformula, Statements]
  delete:
    argAdapters: [EagerSubformula]
  new:
    argAdapters: [OptionalVarName, EagerFamilyRef]
  make:
    argAdapters: [OptionalVarName, EagerFamilyRef, EagerSubformula]
  check:
    argAdapters: [EagerSubformula]
}

mergeTypeMaps = (vars1, vars2) ->
  if vars1
    mergedVars = new EJSONKeyedMap()
    for [varName, type1] in vars1.entries()
      if (type2 = vars2.get(varName))?
        mergedVars.set(varName, mergeTypes(type1, type2))
  else
    vars2

@parseProcedure = (params, procString) ->
  parser = setupParserCommon('PROCEDURE', params)
  # More stuff for scoping and flow sensitivity...
  parser.yy.varsStack = []
  parser.yy.varsPreviousBranch = null
  parser.yy.pushVars = () ->
    this.varsStack.push([this.varsPreviousBranch, this.vars])
    this.varsPreviousBranch = null
    this.vars = this.vars.shallowClone()
  parser.yy.rollbackVars = () ->
    [this.varsPreviousBranch, this.vars] = this.varsStack.pop()
  parser.yy.nextBranch = () ->
    # assert !this.varsPreviousBranch?
    this.varsPreviousBranch = this.vars
    this.vars = this.varsStack[this.varsStack.length - 1][1].shallowClone()
  parser.yy.commitVars = () ->
    newVars = mergeTypeMaps(this.varsPreviousBranch, this.vars)
    this.popVars()
    this.vars = newVars
  parser.yy.convertFamilyReference = (fmla, wantObject, wantKeys) ->
    valAssert(fmla[0] == 'down', 'Family reference must be a down navigation.')
    valAssert(
      # A single down navigation in concrete syntax will always have
      # wantValues = !isObject, but the simplification code in resolveNavigation
      # generates down navigations to object columns with wantValues = true, and
      # more generally either mismatch can arise from adding/removing object
      # types.
      getColumn(fmla[2]).isObject == wantObject && fmla[4] == !wantObject,
      if wantObject
        'new/make only work on object families.'
      else
        'set/add/remove only work on leaf families.')
    valAssert(fmla[3]? == wantKeys,
              if wantKeys
                'make requires a subscript expression.'
              else
                'A subscript expression is not allowed.')
    return fmla[1..3]

  try
    return parser.parse(procString)
  catch e
    # Yuck.  Any better way to recognize parse errors caused by user input?
    if /^(Lexical|Parse) error/.test(e.message)
      throw new FormulaValidationError(e.message)
    else
      throw e

@executeStatements = (model, vars, statements) ->
  TODO
