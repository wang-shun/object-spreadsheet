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
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  adaptForTypecheck: (model, vars, arg) ->
    typecheckFormula(model, vars, arg)
  adapt: (model, vars, arg) ->
    evaluateFormula(model, vars, arg)
}
EagerSubformulaCells = {
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  adaptForTypecheck: (model, vars, arg) ->
    type = typecheckFormula(model, vars, arg)
    valAssert(!typeIsPrimitive(type), "Expected a set of cells, got set of '#{type}'")
    type
  adapt: (model, vars, arg) ->
    evaluateFormula(model, vars, arg)
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
  adaptForTypecheck: (model, vars, [varName, body]) ->
    (argType) ->
      newVars = vars.shallowClone()
      newVars.set(varName, argType)
      typecheckFormula(model, newVars, body)
  adapt: (model, vars, [varName, body]) ->
    # he he he!
    (arg) ->
      newVars = vars.shallowClone()
      newVars.set(varName, arg)
      evaluateFormula(model, newVars, body)
}
ColumnId = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Column ID must be a string')
  adaptForTypecheck: (model, vars, arg) ->
    valAssert(model.getColumn(arg)?, "No column exists with ID #{arg}")
    arg
}
Type = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Type must be a string')
    # Future: Reject unknown primitive types
    #if typeIsPrimitive(arg) ...
  adaptForTypecheck: (model, vars, arg) ->
    unless typeIsPrimitive(arg)
      ColumnId.adaptForTypecheck(model, vars, arg)
    arg
}

getValues = (model, vars, cells) ->
  # XXX: Fail on token columns
  type = model.getColumn(cells.type).type
  new TypedSet(type, set((cellIdLastStep(x) for x in cells.elements())))

typecheckUp = (model, vars, startCellsType, targetColId, wantValues) ->
  [upPath, downPath] = model.findCommonAncestorPaths(startCellsType, targetColId)
  valAssert(downPath.length == 1,
             'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not up')
  if wantValues then model.typecheckColumn(targetColId) else targetColId

typecheckDown = (model, vars, startCellsType, targetColId, wantValues) ->
  targetCol = model.getColumn(targetColId)
  valAssert(targetCol.parent == startCellsType,
             'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not down')
  if wantValues then model.typecheckColumn(targetColId) else targetColId

goUp = (model, vars, startCellsTset, targetColId, wantValues) ->
  # XXX: Can we get here with startCellsTset.type == TYPE_ANY?
  [upPath, downPath] = model.findCommonAncestorPaths(startCellsTset.type, targetColId)

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
    for value in model.readFamilyForFormula({columnId: targetColId, cellId: cellId}).elements()
      targetCellsSet.add(cellIdChild(cellId, value))
  targetCellsTset = new TypedSet(targetColId, targetCellsSet)

  if wantValues then getValues(model, vars, targetCellsTset) else targetCellsTset

dispatch = {

  # ["lit", type ID (string), elements (array)]:
  # A literal set of elements of the specified type.
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

  # ["var", varName (string)]:
  # Gets the value of a bound variable.
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

  # ["up", startCells, targetColumnId, wantValues (bool)]
  up:
    argAdapters: [EagerSubformulaCells, ColumnId, {}]
    validate: (vars, startCellsFmla, targetColumnId, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckUp
    evaluate: goUp

  # ["down", startCells, targetColumnId, wantValues (bool)]
  # Currently allows only one step, matching the concrete syntax.  This makes
  # life easier for now.
  down:
    argAdapters: [EagerSubformulaCells, ColumnId, {}]
    validate: (vars, startCellsFmla, targetColumnId, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckDown
    evaluate: goDown

  # ["filter", domain (subformula), [varName, predicate (subformula)]]:
  # For each cell in the domain, evaluates the predicate with varName bound to
  # the domain cell, which must return a singleton boolean.  Returns the set of
  # domain cells for which the predicate returned true.
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

  # ["=", lhs (subformula), rhs (subformula)]
  # Compares two _singleton_ sets (currently) of the same type for equality.
  # Returns a singleton boolean.
  '=':
    argAdapters: [EagerSubformula, EagerSubformula]
    typecheck: (model, vars, lhsType, rhsType) ->
      valAssert(mergeTypes(lhsType, rhsType) != TYPE_ERROR,
                 "Mismatched types to = operator (#{lhsType} and #{rhsType})")
      '_bool'
    evaluate: (model, vars, lhs, rhs) ->
      new TypedSet('_bool', new EJSONKeyedSet([EJSON.equals(lhs.set, rhs.set)]))

  # ["=", lhs (subformula), rhs (subformula)]
  # Compares two sets of the same type for containment.
  # Returns a singleton boolean.
  'in':
    argAdapters: [EagerSubformula, EagerSubformula]
    typecheck: (model, vars, lhsType, rhsType) ->
      valAssert(mergeTypes(lhsType, rhsType) != TYPE_ERROR,
                 "Mismatched types to 'in' operator (#{lhsType} and #{rhsType})")
      '_bool'
    evaluate: (model, vars, lhs, rhs) ->
      new TypedSet('_bool', set([rhs.set.hasAll lhs.set]))

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

@trackerModel = (model) ->
  depends: set()
  getColumn: (columnId) ->
    @depends.add columnId
    @__proto__.getColumn arguments...
  __proto__: model

# Assumes formula has passed validation.
# vars: EJSONKeyedMap<string, type (nullable string)>
# Returns type (nullable string).
@typecheckFormula = (model, vars, formula) ->
  opName = formula[0]
  args = formula[1..]
  d = dispatch[opName]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter.adaptForTypecheck?
        adapter.adaptForTypecheck(model, vars, args[i])
      else
        args[i]
  d.typecheck(model, vars, adaptedArgs...)

# Assumes formula has passed typechecking.
# vars: EJSONKeyedMap<string, TypedSet>
@evaluateFormula = (model, vars, formula) ->
  opName = formula[0]
  args = formula[1..]
  d = dispatch[opName]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter.adapt? then adapter.adapt(model, vars, args[i]) else args[i]
  d.evaluate(model, vars, adaptedArgs...)

# vars: EJSONKeyedMap<string, type (string)>
@resolveNavigation = (model, vars, startCellsFmla, targetName) ->
