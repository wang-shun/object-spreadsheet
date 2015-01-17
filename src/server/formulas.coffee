valAssert = (cond, message) ->
  throw new FormulaValidationError(message) unless cond
evalAssert = (cond, message) ->
  throw new EvaluationError(message) unless cond

evalAsSingleton = (set) ->
  elements = set.elements()
  evalAssert(elements.length == 1, 'Expected a singleton')
  elements[0]
evalAsType = (tset, type) ->
  evalAssert(mergeTypes(tset.type, type) != TYPE_MIXED,
             'Expected a set of type ' + type)
  tset.set

# Argument adapters to reduce the amount of duplicated work to validate
# arguments and evaluate subexpressions.
# Future: Errors should pinpoint the offending subformula.
VarName = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Variable name must be a string')
}
EagerSubformula = {
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  adapt: (model, vars, arg) ->
    evaluateFormula(model, vars, arg)
}
EagerSubformulaCells = {
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
  adapt: (model, vars, arg) ->
    tset = evaluateFormula(model, vars, arg)
    evalAssert(!typeIsPrimitive(tset.type), 'Expected a set of cells')
    tset
}
LazySubformula = {
  validate: (vars, arg) ->
    validateSubformula(vars, arg)
}
# It might be nicer on the users to not require the extra 2-element array in the
# input, but for now this goes with our framework.
Lambda = {
  validate: (vars, arg) ->
    valAssert(_.isArray(arg) && arg.length == 2,
              'Lambda subformula must be a two-element array')
    [varName, body] = arg
    # Try to save users from themselves.
    valAssert(!vars.has(varName),
              'Lambda shadows variable ' + varName)
    newVars = vars.shallowClone()
    newVars.add(varName)
    validateSubformula(newVars, body)
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
  adapt: (model, vars, arg) ->
    evalAssert(model.getColumn(arg)?, 'Column does not exist')
    arg
}
Type = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Type must be a string')
    # Future: Reject unknown primitive types
    #if typeIsPrimitive(arg) ...
  adapt: (model, vars, arg) ->
    unless typeIsPrimitive(arg)
      evalAssert(model.getColumn(arg)?, 'Column does not exist')
    arg
}

# filterValuesTset may be null.
doNavigate = (model, vars, startCellsTset, targetColId, filterValuesTset, wantValues) ->
  unless startCellsTset.type?
    # We can't navigate, but we know the result should be empty.
    return if wantValues then new TypedSet() else new TypedSet(targetColId)

  [upPath, downPath] = model.findCommonAncestorPaths(startCellsTset.type, targetColId)

  # Go up.
  numIdStepsToDrop = upPath.length - 1
  tmpCellIds = new EJSONKeyedSet()
  for startCellId in startCellsTset.set.elements()
    # Duplicates are thrown out.  Future: multisets?
    tmpCellIds.add(startCellId.slice(0, startCellId.length - numIdStepsToDrop))

  # Go down.
  for level in [downPath.length-2..0] by -1
    childColumnId = downPath[level]
    newCellIds = new EJSONKeyedSet()
    for cellId in tmpCellIds.elements()
      for value in model.readFamilyForFormula({columnId: childColumnId, cellId: cellId}).set.elements()
        newCellIds.add(cellIdChild(cellId, value))
    tmpCellIds = newCellIds

  # Processing related to values in the target column.
  # This duplicates some of the work of the previous loop.
  # Future: To support navigateFilterValues to an infinite column, we'll need to
  # skip the last iteration of the previous loop and directly construct the
  # requested child cell IDs of each cell of the parent column rather than
  # reading the (infinite) family.
  if filterValuesTset? || wantValues
    # We'll use one of the two.
    newCellIds = new EJSONKeyedSet()
    valuesTset = new TypedSet()
    for cellId in tmpCellIds.elements()
      value = cellIdLastStep(cellId)
      valueType = model.readFamilyForFormula(
        {columnId: targetColId, cellId: cellIdParent(cellId)}).type
      if filterValuesTset? && !evalAsType(filterValuesTset, valueType).has(value)
        continue
      if wantValues
        valuesTset.add(valueType, value)
      else
        newCellIds.add(cellId)
    if wantValues
      # Currently, we don't complain about heterogeneous values until you try to
      # project them.
      evalAssert(valuesTset.type != TYPE_MIXED,
                 'Encountered heterogeneous values in column ' + targetColId)
      return valuesTset
    else
      tmpCellIds = newCellIds

  return new TypedSet(targetColId, tmpCellIds)

dispatch = {

  lit:
    argAdapters: [Type, {}]
    validate: (vars, type, list) ->
      valAssert(_.isArray(list), 'Set literal must be an array')
      # Future: Could go ahead and validate primitive-type literals here.
    evaluate: (model, vars, type, list) ->
      # XXXXXXX: Validate members of the type.
      new TypedSet(type, new EJSONKeyedSet(list))

  var:
    argAdapters: [VarName]
    validate: (vars, varName) ->
      unless vars.has(varName)
        throw new FormulaValidationError('Undefined variable ' + varName)
    evaluate: (model, vars, varName) ->
      vars.get(varName)

  cells:
    argAdapters: [EagerSubformulaCells, ColumnId]
    evaluate: (model, vars, startCellsTset, targetCol) ->
      doNavigate(model, vars, startCellsTset, targetCol, null, false)

  values:
    argAdapters: [EagerSubformulaCells, ColumnId]
    validate: (vars, startCellsFmla, targetCol, filterValuesFmla) ->
      valAssert(targetCol != rootColumnId,
                'Cannot navigateValues to the root column because it has no values.')
    evaluate: (model, vars, startCellsTset, targetCol) ->
      doNavigate(model, vars, startCellsTset, targetCol, null, true)

  cellsWithValues:
    argAdapters: [EagerSubformulaCells, ColumnId, EagerSubformula]
    validate: (vars, startCellsFmla, targetCol, filterValuesFmla) ->
      valAssert(targetCol != rootColumnId,
                'Cannot navigateFilterValues to the root column because it has no values.')
    evaluate: (model, vars, startCellsTset, targetCol, filterValuesTset) ->
      doNavigate(model, vars, startCellsTset, targetCol, filterValuesTset, false)

  filter:
    argAdapters: [EagerSubformula, Lambda]
    evaluate: (model, vars, domainTset, predicateLambda) ->
      new TypedSet(
        domainTset.type,
        new EJSONKeyedSet(
          _.filter(domainTset.set.elements(), (x) ->
            # Future: Figure out where to put this code once we start duplicating it.
            tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]))
            evalAsSingleton(evalAsType(predicateLambda(tset), '_bool'))
          )))

  '=':
    argAdapters: [EagerSubformula, EagerSubformula]
    evaluate: (model, vars, lhs, rhs) ->
      evalAssert(mergeTypes(lhs.type, rhs.type) != TYPE_MIXED,
                 'Mismatched types to = operator')
      new TypedSet('_bool', new EJSONKeyedSet([EJSON.equals(lhs.set, rhs.set)]))
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

# Assumes formula has passed validation.
# vars: EJSONKeyedMap<string, TypedSet>
@evaluateFormula = (model, vars, formula) ->
  opName = formula[0]
  args = formula[1..]
  d = dispatch[opName]
  adaptedArgs =
    for adapter, i in d.argAdapters
      if adapter.adapt? then adapter.adapt(model, vars, args[i]) else args[i]
  d.evaluate(model, vars, adaptedArgs...)
