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
    FormulaInternals.stringifyIdent(arg)
}
# This one is mostly for documentation purposes.  Defining validate, typecheck,
# and stringify would only be useful for one statement type (namely if, since
# foreach needs to bind a variable before calling those methods), which we don't
# consider to meet the bar for putting those implementations in an argument
# adapter.  And defining execute would not be useful for any control structure.
# (A control structure that just executes its body inline would be a pretty
# useless control structure.)
Statements = {}
OptionalVarName = {
  validate: (mutableVars, mutableCurrentScopeVars, arg) ->
    if arg? then VarName.validate(mutableVars, mutableCurrentScopeVars, arg)
  stringify: (vars, arg) ->
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
  # All contexts in which formulas appear in statements are safe for PRECEDENCE_LOWEST.
  stringify: (model, mutableVars, arg) ->
    FormulaInternals.EagerSubformula.stringify(model, mutableVars, arg).strFor(PRECEDENCE_LOWEST)
}

# We really just want to think of this as parameterized by two booleans, but I
# guess a class is the way to do it.
class EagerFamilyRef
  constructor: (@wantObject, @wantKeys) ->

  validate: (mutableVars, mutableCurrentScopeVars, fmla) ->
    EagerSubformula.validate(mutableVars, mutableCurrentScopeVars, fmla)
    valAssert(fmla[0] == 'down', 'Family reference must be a down navigation.')
    # A single down navigation in concrete syntax will always have
    # wantValues = !isObject, but the simplification code in resolveNavigation
    # generates down navigations to object columns with wantValues = true, and
    # more generally either mismatch can arise from adding/removing object
    # types.
    valAssert(
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
    stringify: (model, mutableVars, lhsStr, rhsStr) ->
      "let #{lhsStr} = #{rhsStr}\n"
  set:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of ':='", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$set: {values: rhsTset.elements()}})
    stringify: (model, mutableVars, lhsStr, rhsStr) ->
      "#{lhsStr} := #{rhsStr}\n"
  add:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of 'add'", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.upsert({column: lhsFref.columnId, key: parentCellId},
                     {$addToSet: {values: {$each: rhsTset.elements()}}})
    stringify: (model, mutableVars, lhsStr, rhsStr) ->
      "to set #{lhsStr} add #{rhsStr}\n"
  remove:
    argAdapters: [new EagerFamilyRef(false, false), EagerSubformula]
    typecheck: (model, mutableVars, lhsType, rhsType) ->
      valExpectType("Right operand of 'remove'", rhsType, lhsType)
    execute: (model, mutableVars, lhsFref, rhsTset) ->
      # XXX Validate not modifying a formula column.
      model.invalidateDataCache()
      for parentCellId in lhsFref.parentCellsTset.elements()
        Cells.update({column: lhsFref.columnId, key: parentCellId},
                     {$pullAll: {values: rhsTset.elements()}})
    stringify: (model, mutableVars, lhsStr, rhsStr) ->
      "from set #{lhsStr} remove #{rhsStr}\n"
  if:
    argAdapters: [EagerSubformula, Statements, Statements]
    validate: (mutableVars, mutableCurrentScopeVars, conditionFmla, thenBody, elseBody) ->
      validateStatements(mutableVars, mutableCurrentScopeVars, thenBody)
      validateStatements(mutableVars, mutableCurrentScopeVars, elseBody)
    typecheck: (model, mutableVars, conditionType, thenBody, elseBody) ->
      valExpectType('if condition', conditionType, 'bool')
      typecheckStatements(model, mutableVars, thenBody)
      typecheckStatements(model, mutableVars, elseBody)
    execute: (model, mutableVars, conditionTset, thenBody, elseBody) ->
      executeStatements(
        model, mutableVars,
        if singleElement(conditionTset.set) then thenBody else elseBody)
    stringify: (model, mutableVars, conditionStr, thenBody, elseBody) ->
      "if (#{conditionStr}) {\n" + indent(stringifyStatements(thenBody)) + "}\n" +
      (if elseBody.length
        "else {\n" + indent(stringifyStatements(elseBody)) + "}\n")
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
      mutableVars.add(bindVarName)
      typecheckStatements(model, mutableVars, body)
    execute: (model, mutableVars, bindVarName, domainTset, body) ->
      for element in domainTset.elements()
        newVars = mutableVars.shallowClone()
        newVars.set(bindVarName, new TypedSet(domainTset.type, set([element])))
        executeStatements(model, newVars, body)
    stringify: (model, mutableVars, bindVarStr, domainStr, body) ->
      "foreach (#{bindVarStr} : #{domainStr}) {\n" +
      indent(stringifyStatements(body)) + "}\n"
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
    stringify: (model, mutableVars, objectsStr) ->
      "delete #{objectsStr}"
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
    stringify: (model, mutableVars, bindVarStr, frefStr) ->
      (if bindVarStr? then "let #{bindVarStr} = " else '') + "new #{frefStr}"
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
    stringify: (model, mutableVars, bindVarStr, frefStr) ->
      (if bindVarStr? then "let #{bindVarStr} = " else '') + "make #{frefStr}"
  check:
    argAdapters: [EagerSubformula]
    typecheck: (model, mutableVars, conditionType) ->
      valExpectType('check condition', conditionType, 'bool')
    execute: (model, mutableVars, conditionTset) ->
      unless singleElement(conditionTset.set)
        throw new EvaluationError('check condition failed')
    stringify: (model, mutableVars, conditionStr) ->
      "check #{conditionStr}"
}

mergeTypeMaps = (vars1, vars2) ->
  if vars1
    mergedVars = new EJSONKeyedMap()
    for [varName, type1] in vars1.entries()
      if (type2 = vars2.get(varName))?
        mergedVars.set(varName, commonSupertype(type1, type2))
  else
    vars2

# params must already be in final format.
@parseProcedure = (name, params, bodyString) ->
  unless /\n$/.test(bodyString)
    bodyString += '\n'

  parser = setupParserCommon(
    'ENTRY_PROCEDURE',
    new EJSONKeyedMap([p.name, p.type] for p in params))
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
    this.varsPreviousBranch = this.varsStack.pop()[0]
    this.vars = newVars

  try
    return {name, params, body: parser.parse(bodyString)}
  catch e
    if e instanceof SyntaxError
      throw new FormulaValidationError(e.message)
    else
      throw e

# Based on validateSubformula
# mutableVars: EJSONKeyedSet<string>
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

# Perhaps it's not surprising that for every action we currently need (typecheck
# and evaluate), a sequential composition can be processed sequentially.
#
# This will aggregate return values, which we just ignore for now.
dispatchStatements = (action, statements, contextArgs...) ->
  for statement in statements
    dispatchStatement(action, statement, contextArgs...)

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
      console.log(e.stack)
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
