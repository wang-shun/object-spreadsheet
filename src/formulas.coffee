# A smidgen of user documentation:
#
# The current representation of formulas follows the style of Lisp in the format
# of JSON.  A formula is an array in which the first element is a string giving
# the name of a supported operation.  The formats and meanings of any remaining
# elements depend on the operation; they may include subformulas.  Each
# operation is briefly documented in "dispatch" below.
#
# A (sub)formula is evaluated with respect to a mapping of variable names
# (strings) to values.  At this time, the value of a variable or a subformula
# (assuming no runtime evaluation error occurs) is always a finite "typed set",
# though some operations deal exclusively with singleton sets.  The formula of
# a formula column is evaluated once for each cell in the parent column, with
# "this" bound to that parent cell, and the returned set gives the values of
# cells to generate in a "family" in the formula column.  Some operations may
# evaluate subformulas with additional variable bindings.
#
# Primitive types known to the system so far: _unit ('X') and _bool
# (false, true).

@valAssert = (cond, message) ->
  throw new FormulaValidationError(message) unless cond
evalAssert = (cond, message) ->
  throw new EvaluationError(message) unless cond

readFamilyForFormula = (model, qFamilyId) ->
  tset = model.evaluateFamily(qFamilyId)
  if tset?
    return tset
  else
    # Includes the case of a newly detected cycle.
    # Future: Specifically state that there was a cycle.
    throw new EvaluationError("Reference to column #{qFamilyId.columnId} family #{JSON.stringify(qFamilyId.cellId)}, which failed to evaluate")

readColumnTypeForFormula = (model, columnId) ->
  type = model.typecheckColumn(columnId)
  if type != TYPE_ERROR
    return type
  else
    throw new FormulaValidationError("Reference to column #{columnId} of unknown type.  " +
                                     "Fix its formula or manually specify the type if needed to break a cycle.")

evalAsSingleton = (set) ->
  elements = set.elements()
  evalAssert(elements.length == 1, 'Expected a singleton')
  elements[0]
evalAsType = (tset, type) ->
  evalAssert(mergeTypes(tset.type, type) != TYPE_ERROR,
             "Expected a set of type '#{type}', got '#{tset.type}'")
  tset.set

IDENTIFIER_RE = /[_A-Za-z][_A-Za-z0-9]*/

# Argument adapters to reduce the amount of duplicated work to validate
# arguments and evaluate subexpressions.
# Future: Errors should pinpoint the offending subformula.
EagerSubformula = {
  # Note, we can't eta-contract these because the functions aren't defined at
  # this point in the file.  Better ideas welcome.
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  typecheck: (model, vars, arg) ->
    typecheckFormula(model, vars, arg)
  evaluate: (model, vars, arg) ->
    evaluateFormula(model, vars, arg)
  stringify: (arg) ->
    stringifySubformula(arg)
}
EagerSubformulaCells = {
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  typecheck: (model, vars, arg) ->
    type = typecheckFormula(model, vars, arg)
    valAssert(!typeIsPrimitive(type), "Expected a set of cells, got set of '#{type}'")
    type
  evaluate: (model, vars, arg) ->
    evaluateFormula(model, vars, arg)
  stringify: (arg) ->
    stringifySubformula(arg)
}
# It might be nicer on the users to not require the extra 2-element array in the
# input, but for now this goes with our framework.
Lambda = {
  validate: (vars, arg) ->
    valAssert(_.isArray(arg) && arg.length == 2,
              'Lambda subformula must be a two-element array')
    [varName, body] = arg
    valAssert(_.isString(varName) && IDENTIFIER_RE.test(varName),
              "Lambda variable must be an identifier, got '#{arg}'")
    # Try to save users from themselves.
    valAssert(!vars.has(varName),
              'Lambda shadows variable ' + varName)
    newVars = vars.shallowClone()
    newVars.add(varName)
    validateSubformula(newVars, body)
  typecheck: (model, vars, [varName, body]) ->
    (argType) ->
      newVars = vars.shallowClone()
      newVars.set(varName, argType)
      typecheckFormula(model, newVars, body)
  evaluate: (model, vars, [varName, body]) ->
    # he he he!
    (arg) ->
      newVars = vars.shallowClone()
      newVars.set(varName, arg)
      evaluateFormula(model, newVars, body)
  stringify: ([varName, body]) ->
    [varName, stringifySubformula(body)]
}
ColumnId = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Column ID must be a string')
  typecheck: (model, vars, arg) ->
    valAssert(model.getColumn(arg)?, "No column exists with ID #{arg}")
    arg
}
Type = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Type must be a string')
    # Future: Reject unknown primitive types
    #if typeIsPrimitive(arg) ...
  typecheck: (model, vars, arg) ->
    unless typeIsPrimitive(arg)
      ColumnId.typecheck(model, vars, arg)
    arg
}

getValues = (model, vars, cells) ->
  # XXX: Fail on token columns
  type = model.getColumn(cells.type).type
  new TypedSet(type, set((cellIdLastStep(x) for x in cells.elements())))

typecheckUp = (model, vars, startCellsType, targetColId, wantValues) ->
  [upPath, downPath] = findCommonAncestorPaths(startCellsType, targetColId)
  valAssert(downPath.length == 1,
             'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not up')
  if wantValues then readColumnTypeForFormula(model, targetColId) else targetColId

typecheckDown = (model, vars, startCellsType, targetColId, wantValues) ->
  targetCol = model.getColumn(targetColId)
  valAssert(targetCol.parent == startCellsType,
             'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not down')
  if wantValues then readColumnTypeForFormula(model, targetColId) else targetColId

goUp = (model, vars, startCellsTset, targetColId, wantValues) ->
  # XXX: Can we get here with startCellsTset.type == TYPE_ANY?
  [upPath, downPath] = findCommonAncestorPaths(startCellsTset.type, targetColId)

  # Go up.
  numIdStepsToDrop = upPath.length - 1
  result = new TypedSet(targetColId)
  for startCellId in startCellsTset.set.elements()
    targetCellId = startCellId.slice(0, startCellId.length - numIdStepsToDrop)
    # Duplicates are thrown out.  Future: multisets?
    result.add(targetColId, startCellId.slice(0, startCellId.length - numIdStepsToDrop))

  if wantValues then getValues(model, vars, result) else result

goDown = (model, vars, startCellsTset, targetColId, wantValues) ->
  # XXX: Can we get here with startCellsTset.type == TYPE_ANY?

  # Go down.
  targetCellsSet = new EJSONKeyedSet()
  for cellId in startCellsTset.elements()
    for value in readFamilyForFormula(model, {columnId: targetColId, cellId: cellId}).elements()
      targetCellsSet.add(cellIdChild(cellId, value))
  targetCellsTset = new TypedSet(targetColId, targetCellsSet)

  if wantValues then getValues(model, vars, targetCellsTset) else targetCellsTset

stringifyNavigation = (startCellsSinfo, targetColumnId, wantValues) ->
  # XXX: What if the name is ambiguous in this context?
  # To detect, we would need to know the type; too much work.
  column = getColumn(targetColumnId) ? {name: '<deleted>', cellName: '<deleted>'}
  {
    str:
      (if startCellsSinfo.strFor(1) == '::' then '::'
      else if startCellsSinfo.strFor(1) == 'this' then ''
      else startCellsSinfo.strFor(1) + '.') +
      (if wantValues then column.name else column.cellName)
    outerPrecedence: 2
  }

dispatch = {

  # ["lit", type ID (string), elements (array)]:
  # A literal set of elements of the specified type.
  # Concrete syntax: 2, {3,4}, {5,6,7,} etc.  The elements may be JSON booleans,
  # numbers, or strings.
  lit:
    argAdapters: [Type, {}]
    validate: (vars, type, list) ->
      valAssert(_.isArray(list), 'Set literal must be an array')
      # Future: Could go ahead and validate primitive-type literals here.
    typecheck: (model, vars, type, list) ->
      type
    evaluate: (model, vars, type, list) ->
      # XXXXXXX: Validate members of the type.
      new TypedSet(type, new EJSONKeyedSet(list))
    stringify: (type, list) ->
      str:
        if type == '_root'
          # See stringifyNavigation.  This shouldn't be exposed anywhere else.
          '::'
        else if list.length == 1
          JSON.stringify(list[0])
        else
          # XXX: Canonicalize order?
          '{' + (JSON.stringify(x) for x in list).join(',') + '}'
      outerPrecedence: 2

  # ["var", varName (string)]:
  # Gets the value of a bound variable.
  # Concrete syntax: myVar
  var:
    argAdapters: [{}]
    validate: (vars, varName) ->
      valAssert(_.isString(varName) && IDENTIFIER_RE.test(varName),
                "Variable name must be an identifier, got '#{varName}'")
      valAssert(vars.has(varName),
                "Undefined variable #{varName}")
    typecheck: (model, vars, varName) ->
      vars.get(varName)
    evaluate: (model, vars, varName) ->
      vars.get(varName)
    stringify: (varName) ->
      str: varName
      outerPrecedence: 2

  # ["up", startCells, targetColumnId, wantValues (bool)]
  # Concrete syntax: foo, FooCell, (expression).foo, etc.
  up:
    argAdapters: [EagerSubformulaCells, ColumnId, {}]
    validate: (vars, startCellsFmla, targetColumnId, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckUp
    evaluate: goUp
    stringify: stringifyNavigation

  # ["down", startCells, targetColumnId, wantValues (bool)]
  # Currently allows only one step, matching the concrete syntax.  This makes
  # life easier for now.
  # XXX: Eventually the easiest way to provide the refactoring support we'll
  # want is to allow multiple steps.  We can see the issue already if startCells
  # changes type from one ancestor of the target column to another, e.g.,
  # because it is reading from another column whose formula changed.
  # Concrete syntax: foo, FooCell, (expression).foo, ::Bar, etc.
  down:
    argAdapters: [EagerSubformulaCells, ColumnId, {}]
    validate: (vars, startCellsFmla, targetColumnId, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckDown
    evaluate: goDown
    stringify: stringifyNavigation

  # ["filter", domain (subformula), [varName, predicate (subformula)]]:
  # For each cell in the domain, evaluates the predicate with varName bound to
  # the domain cell, which must return a singleton boolean.  Returns the set of
  # domain cells for which the predicate returned true.
  # Concrete syntax: {x in expr | predicate}
  filter:
    argAdapters: [EagerSubformula, Lambda]
    typecheck: (model, vars, domainType, predicateLambda) ->
      predicateType = predicateLambda(domainType)
      valAssert(predicateType == '_bool',
                "Predicate should return _bool, not #{predicateType}")
      domainType
    evaluate: (model, vars, domainTset, predicateLambda) ->
      new TypedSet(
        # XXX Use the checked type instead?
        domainTset.type,
        new EJSONKeyedSet(
          _.filter(domainTset.set.elements(), (x) ->
            # Future: Figure out where to put this code once we start duplicating it.
            tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]))
            evalAsSingleton(evalAsType(predicateLambda(tset), '_bool'))
          )))
    stringify: (domainSinfo, predicateSinfo) ->
      str: "{#{predicateSinfo[0]} in #{domainSinfo.strFor(1)} " +
           "| #{predicateSinfo[1].strFor(0)}}"
      outerPrecedence: 2

  # ["=", lhs (subformula), rhs (subformula)]
  # Compares two _singleton_ sets (currently) of the same type for equality.
  # Returns a singleton boolean.
  # Concrete syntax: lhs = rhs
  '=':
    argAdapters: [EagerSubformula, EagerSubformula]
    typecheck: (model, vars, lhsType, rhsType) ->
      valAssert(mergeTypes(lhsType, rhsType) != TYPE_ERROR,
                 "Mismatched types to = operator (#{lhsType} and #{rhsType})")
      '_bool'
    evaluate: (model, vars, lhs, rhs) ->
      new TypedSet('_bool', new EJSONKeyedSet([EJSON.equals(lhs.set, rhs.set)]))
    stringify: (lhsSinfo, rhsSinfo) ->
      str: "#{lhsSinfo.strFor(1)} = #{rhsSinfo.strFor(1)}"
      outerPrecedence: 1

  # ["in", lhs (subformula), rhs (subformula)]
  # Compares two sets of the same type for containment.
  # Returns a singleton boolean.
  # Concrete syntax: lhs in rhs
  'in':
    argAdapters: [EagerSubformula, EagerSubformula]
    typecheck: (model, vars, lhsType, rhsType) ->
      valAssert(mergeTypes(lhsType, rhsType) != TYPE_ERROR,
                 "Mismatched types to 'in' operator (#{lhsType} and #{rhsType})")
      '_bool'
    evaluate: (model, vars, lhs, rhs) ->
      new TypedSet('_bool', set([rhs.set.hasAll lhs.set]))
    stringify: (lhsSinfo, rhsSinfo) ->
      str: "#{lhsSinfo.strFor(1)} in #{rhsSinfo.strFor(1)}"
      outerPrecedence: 1

}

# Catches syntax errors, references to nonexistent bound variables, and
# variable shadowing, but not anything related to schema, data, or types.
# vars: EJSONKeyedSet<string>
validateSubformula = (vars, formula) ->
  valAssert(_.isArray(formula), 'Subformula must be an array.')
  valAssert(_.isString(opName = formula[0]), 'Subformula must begin with an operation name (a string).')
  valAssert(dispatch.hasOwnProperty(opName),
            'Unknown operation ' + opName)
  d = dispatch[opName]
  args = formula[1..]
  valAssert(args.length == d.argAdapters.length,
            'Wrong number of arguments to ' + opName)
  for adapter, i in d.argAdapters
    if adapter.validate?
      adapter.validate(vars, args[i])
  if d.validate?
    d.validate(vars, args...)

@validateFormula = (formula) ->
  try
    validateSubformula(new EJSONKeyedSet(['this']), formula)
  catch e
    # XXX: Want to do this here?
    if e instanceof FormulaValidationError
      throw new Meteor.Error('invalid-formula',
                             'Invalid formula: ' + e.message)
    else
      throw e

# validateSubformula is just different enough not to use this...
dispatchFormula = (action, formula, contextArgs...) ->
  d = dispatch[formula[0]]
  args = formula[1..]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter[action]? then adapter[action](contextArgs..., args[i]) else args[i]
  d[action](contextArgs..., adaptedArgs...)

# Assumes formula has passed validation.
# vars: EJSONKeyedMap<string, type (nullable string)>
# Returns type (nullable string).
@typecheckFormula = (model, vars, formula) ->
  dispatchFormula('typecheck', formula, model, vars)

# Assumes formula has passed typechecking.
# vars: EJSONKeyedMap<string, TypedSet>
@evaluateFormula = (model, vars, formula) ->
  dispatchFormula('evaluate', formula, model, vars)

# BELOW: Concrete syntax support.  However, this is used on the server, by
# loadSampleData!

validateAndTypecheckFormula = (model, vars, formula) ->
  validateSubformula(new EJSONKeyedSet(vars.keys()), formula)
  return typecheckFormula(model, vars, formula)

# Handle startCellsFmla.targetName or targetName by itself
# (startCellsFmla == null), which may also be a variable reference.
# vars: EJSONKeyedMap<string, type (string)>
# Returns the new formula with the call to "up" or "down" added around
# startCellsFmla.
resolveNavigation = (model, vars, startCellsFmla, targetName) ->
  interpretations = []
  unless startCellsFmla?
    valAssert(targetName != 'this',
              'Explicit "this" is not allowed in concrete syntax.  ' +
              'Please use the cellName for clarity.')
    if vars.get(targetName)?
      interpretations.push(['var', targetName])
    startCellsFmla = ['var', 'this']

  # XXX: This is a lot of duplicate work reprocessing subtrees.
  startCellsType = validateAndTypecheckFormula(model, vars, startCellsFmla)
  valAssert(!typeIsPrimitive(startCellsType), "Expected a set of cells, got set of '#{startCellsType}'")
  columnsInScope = new EJSONKeyedMap()  # column id -> up/down

  # Note, it's impossible to navigate to the root column since it has no name or
  # cellName.
  [upPath, downPath] = findCommonAncestorPaths(startCellsType, rootColumnId)
  for upColumnId in upPath
    columnsInScope.set(upColumnId, 'up')
  for downColumnId in model.getColumn(startCellsType).children
    columnsInScope.set(downColumnId, 'down')

  for [columnId, direction] in columnsInScope.entries()
    col = model.getColumn(columnId)
    if col.name == targetName
      interpretations.push([direction, startCellsFmla, columnId, true])
    if col.cellName == targetName
      interpretations.push([direction, startCellsFmla, columnId, false])

  # Future: Enforce uniqueness of interpretations in any scope?
  valAssert(interpretations.length == 1,
            "#{interpretations.length} possible interpretations for " +
            "<type #{startCellsType}>.#{targetName}, wanted one.")
  return interpretations[0]

@parseFormula = (thisType, fmlaString) ->
  # XXX: If we are changing a formula so as to introduce a new cyclic type
  # checking dependency, we use the old types of the other columns to interpret
  # navigations in the new formula.  However, as soon as we save, all the
  # columns in the cycle will change to TYPE_ERROR and the navigations we just
  # interpreted will become invalid.  This behavior is weird but not worth
  # fixing now.
  liteModel = {
    getColumn: getColumn
    typecheckColumn: (columnId) -> getColumn(columnId).type
  }
  vars = new EJSONKeyedMap()
  vars.set('this', thisType)

  parser = new Jison.Parsers.formula.Parser()
  parser.yy.bindVar = (varName, domainFmla) ->
    valAssert(!vars.get(varName)?, 'Lambda shadows variable ' + varName)
    vars.set(varName, validateAndTypecheckFormula(liteModel, vars, domainFmla))
  parser.yy.unbindVar = (varName) ->
    vars.delete(varName)
  parser.yy.navigate = (startCellsFmla, targetName) ->
    resolveNavigation(liteModel, vars, startCellsFmla, targetName)
  parser.yy.makeSetLiteral = (items) ->
    tset = new TypedSet()
    for [lit, type, val] in items
      tset.add(type, val)
    valAssert(tset.type != TYPE_ERROR, 'Heterogeneous set literal')
    return ['lit', tset.type, tset.elements()]

  try
    return parser.parse(fmlaString)
  catch e
    # Yuck.  Any better way to recognize parse errors caused by user input?
    if /^(Lexical|Parse) error/.test(e.message)
      throw new FormulaValidationError(e.message)
    else
      throw e

stringifySubformula = (formula) ->
  res = dispatchFormula('stringify', formula)
  {
    strFor: (contextPrecedence) ->
      if res.outerPrecedence > contextPrecedence
        res.str
      else
        "(#{res.str})"
  }

@stringifyFormula = (formula) ->
  stringifySubformula(formula).strFor(0)
