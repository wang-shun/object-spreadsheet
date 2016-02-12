# Argument adapters.
#
# Note:
# "validate: (mutableVars, mutableCurrentScopeVars) -> ..."
# - mutableVars is an EJSONKeyedSet<string> of all variables in scope
# - mutableCurrentScopeVars is an EJSONKeyedSet<string> of all variables defined
#   in the current scope, which are the variables that statements are allowed to
#   assign to.
# The "mutable" in the names refers to the fact that both sets are mutated as
# assignments are processed.
VarName = {
  validate: (mutableVars, mutableCurrentScopeVars, arg) ->
    valAssert(_.isString(arg), 'Variable name must be a string')
  stringify: (model, mutableVars, arg) ->
    {
      name: arg
      str: FormulaInternals.stringifyIdent(arg)
    }
}
# This one is mostly for documentation purposes.  Validate, typecheck, and
# execute for statements all have side effects; if we performed those side
# effects during the arg adapter phase, we'd be behaving as if the statements
# ran unconditionally before the control structure, and a control structure for
# which that behavior is correct would be a pretty boring control structure.
# Even for stringify, foreach needs to bind a variable first.
#
# We could have the arg adapters return partial applications of the
# validateStatements, etc. functions, but I don't think this helps
# understandability.
Statements = {}
OptionalVarName = {
  validate: (mutableVars, mutableCurrentScopeVars, arg) ->
    if arg? then VarName.validate(mutableVars, mutableCurrentScopeVars, arg)
  stringify: (model, mutableVars, arg) ->
    if arg? then VarName.stringify(model, mutableVars, arg) else null
}
EagerSubformula = {
  # Wrapper needed to strip mutableCurrentScopeVars argument.
  validate: (mutableVars, mutableCurrentScopeVars, arg) ->
    FormulaInternals.EagerSubformula.validate(mutableVars, arg)
  # Eta-expanded to avoid a load order dependence.
  typecheck: (model, mutableVars, arg) ->
    FormulaInternals.EagerSubformula.typecheck(model, mutableVars, arg)
  execute: (model, mutableVars, arg) ->
    FormulaInternals.EagerSubformula.evaluate(model, mutableVars, arg)
  stringify: (model, mutableVars, arg) ->
    # Anything that binds a local variable needs the original formula in order
    # to get its type.  Follow the design of stringifySubformula.
    #
    # All contexts in which formulas appear in statements are safe for PRECEDENCE_LOWEST.
    {
      formula: arg
      str: FormulaInternals.EagerSubformula.stringify(model, mutableVars, arg).strFor(FormulaInternals.PRECEDENCE_LOWEST)
    }
}

# We really just want to think of this as parameterized by two booleans, but I
# guess a class is the way to do it.
class EagerFamilyRef
  constructor: (@wantObject, @wantKeys) ->

  validate: (mutableVars, mutableCurrentScopeVars, fmla) ->
    EagerSubformula.validate(mutableVars, mutableCurrentScopeVars, fmla)
    valAssert(fmla[0] == 'down', 'Family reference must be a down navigation.')
    valAssert(
      # A single down navigation in concrete syntax will always have
      # wantValues = !isObject, but the simplification code in resolveNavigation
      # generates down navigations to object columns with wantValues = true, and
      # more generally either mismatch can arise from adding/removing object
      # types.
      getColumn(fmla[2]).isObject == @wantObject && fmla[4] == !@wantObject,
      if @wantObject
        'new/make only work on object families.'
      else
        'set/add/remove only work on leaf families.')
    valAssert(fmla[3]? == @wantKeys,
              if @wantKeys
                'make requires a subscript expression.'
              else
                'A subscript expression is not allowed.')
  typecheck: (model, mutableVars, fmla) ->
    type = EagerSubformula.typecheck(model, mutableVars, fmla)
    # EagerFamilyRef is used only as the target of mutations, so we can go ahead
    # and check this here.
    valAssert(!getColumn(fmla[2]).formula?,
              'Cannot mutate a formula column.')
    type
  execute: (model, mutableVars, fmla) ->
    {
      parentCellsTset: evaluateFormula(model, mutableVars, fmla[1])
      columnId: fmla[2]
      keysTset:
        if fmla[3]? then evaluateFormula(model, mutableVars, fmla[3]) else null
    }
  stringify: EagerSubformula.stringify

validateAssignment = (mutableVars, mutableCurrentScopeVars, lhsName) ->
  unless mutableCurrentScopeVars.has(lhsName)
    valAssert(!mutableVars.has(lhsName),
              "Assignment to #{lhsName} shadows a variable defined " +
              'outside the current scope (foreach block).')
    mutableCurrentScopeVars.add(lhsName)
    mutableVars.add(lhsName)

indent = (str) -> str.replace(/^(?=.)/mg, '  ')

dispatch = {
  let:
    argAdapters: [VarName, EagerSubformula]
    validate: (mutableVars, mutableCurrentScopeVars, lhsName, rhsFmla) ->
      validateAssignment(mutableVars, mutableCurrentScopeVars, lhsName)
    typecheck: (model, mutableVars, lhsName, rhsType) ->
      mutableVars.set(lhsName, rhsType)
    execute: (model, mutableVars, lhsName, rhsTset) ->
      mutableVars.set(lhsName, rhsTset)
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) ->
      mutableVars.set(lhsSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, rhsSinfo.formula))
      "let #{lhsSinfo.str} = #{rhsSinfo.str}\n"
  set:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of ':='", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$set: {values: rhsTset.elements()}})
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) ->
      "#{lhsSinfo.str} := #{rhsSinfo.str}\n"
  add:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of 'add'", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$addToSet: {values: {$each: rhsTset.elements()}}})
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) ->
      "to set #{lhsSinfo.str} add #{rhsSinfo.str}\n"
  remove:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of 'remove'", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.update({column: lhsFref.columnId, key: parentCellId},
                     {$pullAll: {values: rhsTset.elements()}})
    stringify: (model, mutableVars, lhsSinfo, rhsSinfo) ->
      "from set #{lhsSinfo.str} remove #{rhsSinfo.str}\n"
  if:
    argAdapters: [EagerSubformula, Statements, Statements]
    validate: (mutableVars, mutableCurrentScopeVars, conditionFmla, thenBody, elseBody) ->
      # We can't simply validate the "then" part and then the "else" part,
      # because a loop in the "else" part shouldn't be reported as shadowing a
      # variable defined only in the "then" part.  Check each part separately;
      # then, all variables that were in the current scope after either part
      # should be in the current scope after the "if".
      currentScopeVarsByBranch =
        for branch in [thenBody, elseBody]
          branchVars = mutableVars.shallowClone()
          branchCurrentScopeVars = mutableCurrentScopeVars.shallowClone()
          validateStatements(branchVars, branchCurrentScopeVars, branch)
          branchCurrentScopeVars
      for csv in currentScopeVarsByBranch
        for varName in csv.elements()
          mutableCurrentScopeVars.add(varName)
          mutableVars.add(varName)
    typecheck: (model, mutableVars, conditionType, thenBody, elseBody) ->
      valExpectType('if condition', conditionType, 'bool')
      varsByBranch =
        for branch in [thenBody, elseBody]
          branchVars = mutableVars.shallowClone()
          typecheckStatements(model, branchVars, branch)
          branchVars
      mergedVars = mergeTypeMaps(varsByBranch[0], varsByBranch[1])
      # Mutate mutableVars to match mergedVars.  (Maybe if we introduce a real
      # class to track the defined variables, this will be less hacky.)  Here,
      # mergedVars should contain a superset of the keys of mutableVars.
      for [k, v] in mergedVars.entries()
        mutableVars.set(k, v)
    execute: (model, mutableVars, conditionTset, thenBody, elseBody) ->
      executeStatements(
        model, mutableVars,
        if singleElement(conditionTset.set) then thenBody else elseBody)
    stringify: (model, mutableVars, conditionSinfo, thenBody, elseBody) ->
      varsAndStringByBranch =
        for branch in [thenBody, elseBody]
          branchVars = mutableVars.shallowClone()
          str = stringifyStatements(model, branchVars, branch)
          {branchVars, str}
      mergedVars = mergeTypeMaps(varsAndStringByBranch[0].branchVars, varsAndStringByBranch[1].branchVars)
      for [k, v] in mergedVars.entries()
        mutableVars.set(k, v)
      "if (#{conditionSinfo.str}) {\n" + indent(varsAndStringByBranch[0].str) + "}" +
      (if elseBody.length then " else {\n" + indent(varsAndStringByBranch[1].str) + "}\n" else "\n")
  foreach:
    argAdapters: [VarName, EagerSubformula, Statements]
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, domainFmla, body) ->
      mutableVars = mutableVars.shallowClone()
      mutableCurrentScopeVars = new EJSONKeyedSet()
      valAssert(!mutableVars.has(bindVarName),
                "foreach binding of #{bindVarName} shadows a variable defined " +
                'outside the current scope (foreach block).')
      mutableCurrentScopeVars.add(bindVarName)
      mutableVars.add(bindVarName)
      validateStatements(mutableVars, mutableCurrentScopeVars, body)
    typecheck: (model, mutableVars, bindVarName, domainType, body) ->
      mutableVars = mutableVars.shallowClone()
      mutableVars.add(bindVarName)  # TODO TEST THIS
      #mutableVars.set(bindVarName, domainType)
      typecheckStatements(model, mutableVars, body)
    execute: (model, mutableVars, bindVarName, domainTset, body) ->
      for element in domainTset.elements()
        newVars = mutableVars.shallowClone()
        newVars.set(bindVarName, new TypedSet(domainTset.type, set([element])))
        executeStatements(model, newVars, body)
    stringify: (model, mutableVars, bindVarSinfo, domainSinfo, body) ->
      mutableVars = mutableVars.shallowClone()
      mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, domainSinfo.formula))
      "foreach (#{bindVarSinfo.str} : #{domainSinfo.str}) {\n" +
        indent(stringifyStatements(model, mutableVars, body)) + "}\n"
  delete:
    argAdapters: [EagerSubformula]
    typecheck: (model, mutableVars, objectsType) ->
      # XXX Duplicating functionality of EagerSubformulaCells in formulas.coffee.
      # It's not worth providing a whole EagerSubformulaCells wrapper yet.
      valAssert(typeIsReference(objectsType),
                "Expected a set of cells, got set of '#{objectsType}'")
    execute: (model, mutableVars, objectsTset) ->
      # XXX: We are relying on objectsTset.type being correct!  This
      # functionality is poorly tested since we introduced typechecking.
      model.invalidateDataCache()
      for objectId in objectsTset.elements()
        recursiveDeleteStateCellNoInvalidate(objectsTset.type, objectId)
    stringify: (model, mutableVars, objectsSinfo) ->
      "delete #{objectsSinfo.str}\n"
  new:
    argAdapters: [OptionalVarName, new EagerFamilyRef(true, false)]
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, fref) ->
      if bindVarName?
        validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName)
    typecheck: (model, mutableVars, bindVarName, familyType) ->
      if bindVarName?
        mutableVars.set(bindVarName, familyType)
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
    stringify: (model, mutableVars, bindVarSinfo, frefSinfo) ->
      if bindVarSinfo?
        mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula))
      (if bindVarSinfo? then "let #{bindVarSinfo.str} = " else '') + "new #{frefSinfo.str}\n"
  make:
    argAdapters: [OptionalVarName, new EagerFamilyRef(true, true)]
    validate: (mutableVars, mutableCurrentScopeVars, bindVarName, fref) ->
      if bindVarName?
        validateAssignment(mutableVars, mutableCurrentScopeVars, bindVarName)
    typecheck: (model, mutableVars, bindVarName, familyType) ->
      if bindVarName?
        mutableVars.set(bindVarName, familyType)
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
    stringify: (model, mutableVars, bindVarSinfo, frefSinfo) ->
      if bindVarSinfo?
        mutableVars.set(bindVarSinfo.name, FormulaInternals.tryTypecheckFormula(model, mutableVars, frefSinfo.formula))
      (if bindVarSinfo? then "let #{bindVarSinfo.str} = " else '') + "make #{frefSinfo.str}\n"
  check:
    argAdapters: [EagerSubformula]
    typecheck: (model, mutableVars, conditionType) ->
      valExpectType('check condition', conditionType, 'bool')
    execute: (model, mutableVars, conditionTset) ->
      unless singleElement(conditionTset.set)
        throw new EvaluationError('check condition failed')
    stringify: (model, mutableVars, conditionSinfo) ->
      "check #{conditionSinfo.str}\n"
}

mergeTypeMaps = (vars1, vars2) ->
  mergedVars = new EJSONKeyedMap()
  for [varName, type1] in vars1.entries()
    type2 = vars2.get(varName)
    mergedVars.set(varName, commonSupertype(type1, type2 ? TYPE_ERROR))
  for varName in vars2.keys()
    unless vars1.get(varName)?
      mergedVars.set(varName, TYPE_ERROR)
  mergedVars

paramsToTypeMap = (params) ->
  new EJSONKeyedMap([p.name, p.type] for p in params)

# params must already be in final format.
@parseProcedure = (stringProc) ->
  bodyString = stringProc.body
  unless /(^|\n)$/.test(bodyString)
    bodyString += '\n'

  parser = setupParserCommon(
    'ENTRY_PROCEDURE', paramsToTypeMap(stringProc.params))
  # The following duplicates the authoritative scoping rules expressed in the
  # statement handlers, but is needed to know the correct types during parsing
  # so we can interpret navigations correctly.
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
    [this.varsPreviousBranch, _] = this.varsStack.pop()
    this.vars = newVars

  try
    return {
      name: stringProc.name,
      params: EJSON.clone(stringProc.params),
      body: parser.parse(bodyString)
    }
  catch e
    if e instanceof SyntaxError
      throw new FormulaValidationError(e.message)
    else
      throw e

# Based on validateSubformula
# mutableVars: EJSONKeyedSet<string>
#
# Does not use dispatchStatement for the same reasons as validateSubformula.
validateStatement = (mutableVars, mutableCurrentScopeVars, statement) ->
  valAssert(_.isArray(statement), 'Statement must be an array.')
  valAssert(_.isString(opName = statement[0]), 'Statement must begin with an operation name (a string).')
  valAssert(dispatch.hasOwnProperty(opName),
            "Unknown operation '#{opName}'")
  d = dispatch[opName]
  args = statement[1..]
  valAssert(args.length == d.argAdapters.length,
            "Wrong number of arguments to '#{opName}' (required #{d.argAdapters.length}, got #{args.length})")
  for adapter, i in d.argAdapters
    if adapter.validate?
      adapter.validate(mutableVars, mutableCurrentScopeVars, args[i])
  if d.validate?
    d.validate(mutableVars, mutableCurrentScopeVars, args...)

# Copied from formulas.coffee.  More generality than we need right now.
dispatchStatement = (action, statement, contextArgs...) ->
  d = dispatch[statement[0]]
  args = statement[1..]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter[action]? then adapter[action](contextArgs..., args[i]) else args[i]
  d[action](contextArgs..., adaptedArgs...)

validateStatements = (mutableVars, mutableCurrentScopeVars, arg) ->
  valAssert(_.isArray(arg),
            'Expected a list of statements')
  for statement in arg
    validateStatement(mutableVars, mutableCurrentScopeVars, statement)

typecheckStatements = (model, mutableVars, arg) ->
  for statement in arg
    dispatchStatement('typecheck', statement, model, mutableVars)

executeStatements = (model, mutableVars, arg) ->
  for statement in arg
    dispatchStatement('execute', statement, model, mutableVars)

stringifyStatements = (model, mutableVars, arg) ->
  (for statement in arg
    dispatchStatement('stringify', statement, model, mutableVars)).join('')

@validateProcedure = (proc) ->
  check(proc, {
    _id: Match.Optional(String),
    name: String,
    params: [{
      name: String,
      type: String,
      singular: Boolean}],
    body: Match.Any})  # body is fully validated by validateStatements
  try
    mutableCurrentScopeVars = new EJSONKeyedSet()
    for param in proc.params
      valAssert(!mutableCurrentScopeVars.has(param.name),
                "Duplicate parameter name #{param.name}")
      mutableCurrentScopeVars.add(param.name)
    mutableVars = mutableCurrentScopeVars.shallowClone()
    validateStatements(mutableVars, mutableCurrentScopeVars, proc.body)
  catch e
    # XXX: Want to do this here?
    if e instanceof FormulaValidationError
      throw new Meteor.Error('invalid-procedure',
                             'Invalid procedure: ' + e.message)
    else
      throw e

# Returns nothing.  (If in the future we have procedures that return values,
# typecheckProcedure would return the procedure's return type.)
@typecheckProcedure = (model, proc) ->
  mutableVars = new EJSONKeyedMap()
  for param in proc.params
    # XXX Duplicates logic from {Type,ColumnId}.typecheck
    if typeIsReference(param.type)
      valAssert(model.getColumn(param.type)?, "No column exists with ID #{param.type}")
    mutableVars.set(param.name, param.type)
  typecheckStatements(model, mutableVars, proc.body)

# It is assumed that the procedure already passed typecheckProcedure against the
# current schema.
#
# May throw EvaluationError and leave the sheet in an intermediate state.
@executeProcedure = (model, proc, args) ->
  # TODO Validate correct set of arguments present with correct types?
  # Currently we consider that the caller's responsibility.
  for param in proc.params
    if param.singular
      singleElement(args.get(param.name).set)  # Better error message?
  executeStatements(model, args.shallowClone(), proc.body)

@stringifyProcedure = (proc) ->
  # C.f. stringifyFormula
  {
    name: proc.name,
    params: EJSON.clone(proc.params),
    body: stringifyStatements(liteModel, paramsToTypeMap(proc.params), proc.body)
  }
