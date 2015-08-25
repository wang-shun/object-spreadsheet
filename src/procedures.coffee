# Argument adapters.
# The first few are for documentation purposes and currently don't do anything.
VarName = {}
Statements = {}
OptionalVarName = {}
EagerSubformula = {
  execute: evaluateFormula
}
EagerFamilyRef = {
  execute: (model, vars, arg) ->
    parentCellsTset: evaluateFormula(model, vars, arg[0])
    columnId: arg[1]
    keysTset: arg[2]
}

recursiveDeleteStateCell = (columnId, cellId) ->
  col = getColumn(columnId)
  for childColId in col.children
    childCol = getColumn(childColId)
    unless childCol.formula?
      # Empty families are only inserted during evaluateAll, so they may not yet
      # exist for objects created in the same transaction.
      if (ce = Cells.findOne({column: childColId, key: cellId}))?
        for val in ce.values
          recursiveDeleteStateCell(childColId, cellIdChild(cellId, val))
  Cells.update({column: columnId, key: cellIdParent(cellId)},
               {$pull: {values: cellIdLastStep(cellId)}})

dispatch = {
  let:
    argAdapters: [VarName, EagerSubformula]
    execute: (model, mutableVars, lhsName, rhsTset) ->
      mutableVars.set(lhsName, rhsTset)
  set:
    argAdapters: [EagerFamilyRef, EagerSubformula]
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$set: {values: rhsTset.elements()}})
  add:
    argAdapters: [EagerFamilyRef, EagerSubformula]
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$addToSet: {values: {$each: rhsTset.elements()}}})
  remove:
    argAdapters: [EagerFamilyRef, EagerSubformula]
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.update({column: lhsFref.columnId, key: parentCellId},
                     {$pullAll: {values: rhsTset.elements()}})
  if:
    argAdapters: [EagerSubformula, Statements, Statements]
    execute: (model, mutableVars, conditionTset, thenBody, elseBody) ->
      executeStatements1(
        model, mutableVars,
        if singleElement(conditionTset.set) then thenBody else elseBody)
  foreach:
    argAdapters: [VarName, EagerSubformula, Statements]
    execute: (model, mutableVars, bindVarName, domainTset, body) ->
      for element in domainTset.elements()
        newVars = mutableVars.shallowClone()
        newVars.set(bindVarName, new TypedSet(domainTset.type, set([element])))
        executeStatements1(model, newVars, body)
  delete:
    argAdapters: [EagerSubformula]
    execute: (model, mutableVars, objectsTset) ->
      # XXX: We are relying on objectsTset.type being correct!  This
      # functionality is poorly tested since we introduced typechecking.
      model.invalidateDataCache()
      for objectId in objectsTset.elements()
        recursiveDeleteStateCell(objectsTset.type, objectId)
  new:
    argAdapters: [OptionalVarName, EagerFamilyRef]
    execute: (model, mutableVars, bindVarName, fref) ->
      model.invalidateDataCache()
      objects = []
      for parentCellId in fref.parentCellsTset.elements()
        token = Random.id()
        Cells.upsert({column: fref.columnId, key: parentCellId},
                     {$addToSet: {values: token}})
        objects.push(cellIdChild(parentCellId, token))
      if bindVarName?
        mutableVars.set(bindVarName, new TypedSet(fref.columnId, set(objects)))
  make:
    argAdapters: [OptionalVarName, EagerFamilyRef]
    execute: (model, mutableVars, bindVarName, fref) ->
      model.invalidateDataCache()
      for parentCellId in fref.parentCellsTset.elements()
        for key in fref.keysTset.elements()
          # No-op if already exists
          Cells.upsert({column: fref.columnId, key: parentCellId},
                       {$addToSet: {values: key}})
          objects.push(cellIdChild(parentCellId, key))
      if bindVarName?
        mutableVars.set(bindVarName, new TypedSet(fref.columnId, set(objects)))
  check:
    argAdapters: [EagerSubformula]
    execute: (model, mutableVars, conditionTset) ->
      unless singleElement(conditionTset.set)
        throw new EvaluationError('check statement failed')
}

mergeTypeMaps = (vars1, vars2) ->
  if vars1
    mergedVars = new EJSONKeyedMap()
    for [varName, type1] in vars1.entries()
      if (type2 = vars2.get(varName))?
        mergedVars.set(varName, mergeTypes(type1, type2))
  else
    vars2

@parseCannedTransaction = (paramsInfo, bodyString) ->
  params = new EJSONKeyedMap()
  # Disable automatic addition of built-in parameters for now to avoid the
  # hassle of setting them manually when they aren't actually needed.
  ## Imagined to be system-set and count 1.
  #params.set('clientUser', parseTypeStr('Person'))
  count1Checks = ''
  for [paramName, paramType] in paramsInfo
    if /\*$/.test(paramType)
      paramType = paramType[0...-1]
    else
      count1Checks += "check count(#{paramName}) = 1\n"
    paramType = parseTypeStr(paramType)
    params.set(paramName, paramType)
  bodyString = (count1Checks + bodyString +
                if /\n$/.test(bodyString) then '' else '\n')

  parser = setupParserCommon('PROCEDURE', params)
  # More stuff for scoping and flow sensitivity...
  parser.yy.varsStack = []
  parser.yy.varsPreviousBranch = null
  parser.yy.pushVars = () ->
    this.varsStack.push([this.varsPreviousBranch, this.vars])
    this.varsPreviousBranch = null
    this.vars = this.vars.shallowClone()
  parser.yy.popVars = () ->
    [this.varsPreviousBranch, _] = this.varsStack.pop()
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
    return {params, body: parser.parse(bodyString)}
  catch e
    # Yuck.  Any better way to recognize parse errors caused by user input?
    if /^(Lexical|Parse) error/.test(e.message)
      throw new FormulaValidationError(e.message)
    else
      throw e

# Copied from formulas.coffee.  More generality than we need right now.
dispatchStatement = (action, statement, contextArgs...) ->
  d = dispatch[statement[0]]
  args = statement[1..]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter[action]? then adapter[action](contextArgs..., args[i]) else args[i]
  d[action](contextArgs..., adaptedArgs...)

executeStatement = (model, mutableVars, statement) ->
  dispatchStatement('execute', statement, model, mutableVars)

# mutableVars: The map is intended to be mutated; the value tsets, not.
executeStatements1 = (model, mutableVars, statements) ->
  for statement in statements
    executeStatement(model, mutableVars, statement)

# May throw EvaluationError and leave things in an intermediate state.
@executeStatements = (model, vars, statements) ->
  executeStatements1(model, vars.shallowClone(), statements)
