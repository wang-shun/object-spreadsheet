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

# Based on model.evaluateFamily{,1}.
# TODO: Assuming we do want the client to be able to evaluate formulas (for now
# at least), factor out that code so the client can use it in read-only mode.
evaluateFamilyReadOnly = (qFamilyId) ->
  keyFields = {column: qFamilyId.columnId, key: qFamilyId.cellId}
  ce = Cells.findOne(keyFields)
  unless ce?
    col = @getColumn(qFamilyId.columnId)
    if col.formula?
      throw new Error("Computed family #{qFamilyId} missing from database")
    else
      return new TypedSet(col.type)
  if ce.values?
    return new TypedSet(@getColumn(qFamilyId.columnId).type,
                        new EJSONKeyedSet(ce.values))
  else
    return null

readColumnTypeForFormula = (model, columnId) ->
  type = model.typecheckColumn(columnId)
  valAssert(type?, "column '${columnId}': type missing")
  if type != TYPE_ERROR
    return type
  else
    throw new FormulaValidationError("Reference to column #{columnId} of unknown type.  " +
                                     "Fix its formula or manually specify the type if needed to break a cycle.")

valExpectType = (what, actualType, expectedType) ->
  valAssert(mergeTypes(actualType, expectedType) == expectedType,
            "#{what} has type #{actualType}, wanted #{expectedType}")

@singleElement = (set) ->
  elements = set.elements()
  evalAssert(elements.length == 1, 'Expected a singleton')
  elements[0]


class FormulaEngine
  constructor: ->
    @goUpMemo = new Memo
    @compiled = {}

  readFamily: (column, key) ->
    # TODO move functionality from model.evaluateFamily here
    Cells.findOne({column, key})?.values || []

  calcLevelsUp: (sourceColId, targetColId) ->
    @goUpMemo.get "#{sourceColId}-#{targetColId}", ->
      [upPath, downPath] = findCommonAncestorPaths(sourceColId, targetColId)
      upPath.length - 1

  invalidateSchemaCache: ->
    @goUpMemo.clear()
    @compiled = {}


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
  stringify: (model, vars, arg) ->
    stringifySubformula(model, vars, arg)
  getSubformulas: (arg) -> [arg]
}
OptionalEagerSubformula = {
  validate: (vars, arg) ->
    if arg? then validateSubformula(vars, arg)
  typecheck: (model, vars, arg) ->
    if arg? then typecheckFormula(model, vars, arg) else null
  evaluate: (model, vars, arg) ->
    if arg? then evaluateFormula(model, vars, arg) else null
  stringify: (model, vars, arg) ->
    if arg? then stringifySubformula(model, vars, arg) else null
  getSubformulas: (arg) -> if arg? then [arg] else []
}
EagerSubformulaCells = {
  validate: EagerSubformula.validate
  typecheck: (model, vars, arg) ->
    type = typecheckFormula(model, vars, arg)
    valAssert(!typeIsPrimitive(type), "Expected a set of cells, got set of '#{type}'")
    type
  evaluate: EagerSubformula.evaluate
  stringify: EagerSubformula.stringify
  getSubformulas: EagerSubformula.getSubformulas
}
HomogeneousEagerSubformulaList = {
  validate: (vars, arg) ->
    valAssert(_.isArray(arg),
              'Expected a list of subformulas')
    for item in arg
      validateSubformula(vars, item)
  typecheck: (model, vars, termFmlas) ->
    typeSoFar = TYPE_ANY
    for fmla in termFmlas
      termType = typecheckFormula(model, vars, fmla)
      newType = mergeTypes(typeSoFar, termType)
      valAssert(newType != TYPE_ERROR,
                "Mismatched types in list (#{typeSoFar} and #{termType})")
      typeSoFar = newType
    typeSoFar
  evaluate: (model, vars, termFmlas) ->
    (evaluateFormula(model, vars, fmla) for fmla in termFmlas)
  stringify: (model, vars, termFmlas) ->
    (stringifySubformula(model, vars, fmla) for fmla in termFmlas)
  getSubformulas: (termFmlas) -> termFmlas
}
LazySubformula = {
  validate: EagerSubformula.validate
  typecheck: EagerSubformula.typecheck
  # No evaluate.
  stringify: EagerSubformula.stringify
  getSubformulas: EagerSubformula.getSubformulas
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
  stringify: (model, vars, [varName, body]) ->
    (argType) ->
      newVars = vars.shallowClone()
      newVars.set(varName, argType)
      [varName, stringifySubformula(model, newVars, body)]
  getSubformulas: ([varName, body]) -> [body]
}
ColumnId = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Column ID must be a string')
  typecheck: (model, vars, arg) ->
    valAssert(model.getColumn(arg)?, "No column exists with ID #{arg}")
    arg
}
String = {
  validate: (vars, arg) ->
    valAssert(_.isString(arg), 'Must be a string')
  typecheck: (model, vars, arg) -> arg
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
  type = model.typecheckColumn(cells.type)
  new TypedSet(type, set((cellIdLastStep(x) for x in cells.elements())))

typecheckUp = (model, vars, startCellsType, targetColId, wantValues) ->
  [upPath, downPath] = findCommonAncestorPaths(startCellsType, targetColId)
  valAssert(downPath.length == 1,
            'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not up')
  # Enforce the same rule as parsing.  Otherwise, if the startCellsType changes
  # as a result of a change to another formula, users will be surprised when a
  # formula that we didn't allow them to enter evaluates successfully.
  valAssert(!wantValues || upPath.length == 1,
            'Direct navigation up to a key of a parent object is not allowed.')
  if wantValues then readColumnTypeForFormula(model, targetColId) else targetColId

typecheckDown = (model, vars, startCellsType, targetColId, keysType, wantValues) ->
  targetCol = model.getColumn(targetColId)
  valAssert(targetCol.parent == startCellsType,
            'Navigation from ' + startCellsType + ' to ' + targetColId + ' is not down')
  valAssert(wantValues || targetCol.isObject,
            'Target column has no object type to navigate to.')
  if keysType?
    valAssert(!wantValues, 'Can only specify keys when navigating to objects.')
    valExpectType('Key set', keysType, model.typecheckColumn(targetCol))
  if wantValues then readColumnTypeForFormula(model, targetColId) else targetColId

goUp = (model, vars, startCellsTset, targetColId, wantValues) ->
  # XXX: Can we get here with startCellsTset.type == TYPE_ANY?

  # Go up.
  if startCellsTset.type == targetColId
    result = startCellsTset
  else
    numIdStepsToDrop = $$.formulaEngine.goUpMemo.get "#{startCellsTset.type}-#{targetColId}", ->
      [upPath, downPath] = findCommonAncestorPaths(startCellsTset.type, targetColId)
      upPath.length - 1
    s = set()
    for startCellId in startCellsTset.set.elements()
      targetCellId = startCellId.slice(0, startCellId.length - numIdStepsToDrop)
      # Duplicates are thrown out.  Future: multisets?
      s.add(targetCellId)
    result = new TypedSet(targetColId, s)

  if wantValues then getValues(model, vars, result) else result

goDown = (model, vars, startCellsTset, targetColId, keysTset, wantValues) ->
  # XXX: Can we get here with startCellsTset.type == TYPE_ANY?

  # Go down.
  targetCellsSet = new EJSONKeyedSet()
  for cellId in startCellsTset.elements()
    for value in readFamilyForFormula(model, {columnId: targetColId, cellId: cellId}).elements()
      if !keysTset? || keysTset.set.has(value)
        targetCellsSet.add(cellIdChild(cellId, value))
  targetCellsTset = new TypedSet(targetColId, targetCellsSet)

  if wantValues then getValues(model, vars, targetCellsTset) else targetCellsTset

annotateNavigationTarget = (model, vars, startCellsFmla, targetName, keysFmla, expectedFmla) ->
  if !targetName?
    '(unnamed)'
  else
    # Future: Distinguish between "the original interpretation is no longer
    # valid" (in which case the formula should fail to typecheck) and "there are
    # multiple possible interpretations including the original" (in which case
    # the formula should still work).
    try
      actualFmla = resolveNavigation(model, vars, startCellsFmla, targetName, keysFmla)
      valAssert(EJSON.equals(actualFmla, expectedFmla),
                'Interpreting the concrete formula did not reproduce the existing abstract formula.')
      targetName
    catch e
      # Notice: this happens regularly in the client when column
      # type information is wiped
      targetName + '(problem)'

stringifyNavigation = (direction, model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues) ->
  column = getColumn(targetColumnId)
  # ?. returns undefined whether the LHS is null or undefined, but we want null
  # to match the familyReference production in language.jison.
  keysFmla = keysSinfo?.formula ? null
  targetName =
    if !column? then '(deleted)'
    else
      # Reconstruct the current subformula.  XXX: Get it a better way?
      wantFormula = [direction, startCellsSinfo.formula, targetColumnId, wantValues]
      if direction == 'down'
        wantFormula.splice(3, 0, keysFmla)
      if !wantValues
        annotateNavigationTarget(model, vars, startCellsSinfo.formula,
                                 objectNameWithFallback(column), keysFmla, wantFormula)
      else if direction == 'down' && column.isObject
        # Special case: when an object type Bar is added to a leaf column foo, we
        # want down navigations "(...).foo" to start displaying as "(...).Bar.foo"
        # without having to rewrite the abstract syntax of affected formulas.
        # Even if the first navigation in the concrete syntax is ambiguous, we
        # know what we meant and should annotate the second navigation
        # accordingly.
        #
        # The only way we reach here with keysFmla != null is if the user enters
        # an ill-typed formula like (...).foo[5] and then adds an object type.
        # (resolveNavigation does not convert (...).Bar[5].foo to a single down
        # navigation because of the keys, and it rejects (...).Bar.foo[5] with
        # "Only down navigations can be subscripted with keys".)  In that case,
        # this code displays (...).Bar.foo(problem)[5], which is reasonable.  It's
        # unclear if any deeper justification for passing the keysFmla to the
        # second navigation holds water.
        intermediateFormula = wantFormula[0..2].concat([null, false])
        (
          annotateNavigationTarget(model, vars, startCellsSinfo.formula,
                                   objectNameWithFallback(column), null,
                                   intermediateFormula) + '.' +
          annotateNavigationTarget(model, vars, intermediateFormula,
                                   column.fieldName, keysFmla, wantFormula)
        )
      else
        annotateNavigationTarget(model, vars, startCellsSinfo.formula,
                                 column.fieldName, keysFmla, wantFormula)
  {
    str:
      (if startCellsSinfo.strFor(PRECEDENCE_NAV) == '$' then '$'
      else if startCellsSinfo.strFor(PRECEDENCE_NAV) == 'this' then ''
      else startCellsSinfo.strFor(PRECEDENCE_NAV) + '.') + targetName +
      (if keysSinfo? then "[#{keysSinfo.strFor(PRECEDENCE_LOWEST)}]" else '')
    outerPrecedence: PRECEDENCE_NAV
  }

PRECEDENCE_LOWEST = PRECEDENCE_OR = 1
PRECEDENCE_AND = 2
PRECEDENCE_COMPARE = 3
PRECEDENCE_PLUS = 4
PRECEDENCE_TIMES = 5
PRECEDENCE_NEG = 6
PRECEDENCE_POW = 7
PRECEDENCE_ATOMIC = PRECEDENCE_NAV = 8

ASSOCIATIVITY_LEFT = 'left'
ASSOCIATIVITY_RIGHT = 'right'
ASSOCIATIVITY_NONE = null

binaryOperationStringify = (symbol, precedence, associativity) ->
  (model, vars, lhsSinfo, rhsSinfo) ->
    str: (lhsSinfo.strFor(precedence + (associativity != ASSOCIATIVITY_LEFT)) +
          ' ' + symbol + ' ' +
          rhsSinfo.strFor(precedence + (associativity != ASSOCIATIVITY_RIGHT)))
    outerPrecedence: precedence

singletonInfixOperator = (symbol, precedence, associativity,
                          lhsExpectedType, rhsExpectedType, resultType, evaluateFn) ->
  argAdapters: [EagerSubformula, EagerSubformula]
  typecheck: (model, vars, lhsType, rhsType) ->
    valExpectType("Left operand of '#{symbol}'", lhsType, lhsExpectedType)
    valExpectType("Right operand of '#{symbol}'", rhsType, rhsExpectedType)
    resultType
  evaluate: (model, vars, lhs, rhs) ->
    new TypedSet(resultType, set([evaluateFn(singleElement(lhs.set), singleElement(rhs.set))]))
  stringify: binaryOperationStringify(symbol, precedence, associativity)

sameTypeSetsInfixPredicate = (symbol, precedence, associativity, evaluateFn) ->
  argAdapters: [EagerSubformula, EagerSubformula]
  typecheck: (model, vars, lhsType, rhsType) ->
    valAssert(mergeTypes(lhsType, rhsType) != TYPE_ERROR,
              "Mismatched types to '#{symbol}' operator (#{lhsType} and #{rhsType})")
    'bool'
  evaluate: (model, vars, lhs, rhs) ->
    new TypedSet('bool', new EJSONKeyedSet([evaluateFn(lhs.set, rhs.set)]))
  stringify: binaryOperationStringify(symbol, precedence, associativity)

# Usage:
#   overloaded([[argument-types...], handler],
#              [[argument-types...], handler], ...)
overloaded = (alternatives...) ->
  arities = (a[0].length for a in alternatives)
  minArity = Math.min(arities...)
  maxArity = Math.max(arities...)
  getHandler = (argtypes) ->
    for [decltypes, handler] in alternatives
      if decltypes.length == argtypes.length && 
         forall(zip(decltypes, argtypes), ([decltype, argtype]) -> mergeTypes(decltype, argtype) != TYPE_ERROR)
        return handler
  argAdapters: (EagerSubformula for i in [0...minArity]).concat(OptionalEagerSubformula for i in [minArity...maxArity])
  typecheck: (model, vars, argtypes...) ->
    handler = getHandler(argtypes)
    valAssert(handler?, "No valid alternative for argument types #{argtypes}")
    handler.typecheck(model, vars, argtypes...)
  evaluate: (model, vars, args...) ->      
    argtypes = (ts.type for ts in args)
    handler = getHandler(argtypes)
    valAssert(handler?, "No valid alternative for argument types #{argtypes}")
    handler.evaluate(model, vars, args...)
  stringify: (model, vars, sinfos...) ->
    # Does it even make sense to have different stringifies for different alternatives?
    [_, handler] = alternatives[0]
    handler.stringify(model, vars, sinfos...)
      
compareInfixOperator = (symbol, precedence, associativity, evaluateFn) ->
  overloaded(
        [['number', 'number'], singletonInfixOperator(symbol, precedence, associativity, 'number', 'number', 'bool', evaluateFn)],
        [['date', 'date'],     singletonInfixOperator(symbol, precedence, associativity, 'date',   'date',   'bool', evaluateFn)]
  )


dispatch = {

  # ["lit", type ID (string), elements (array)]:
  # A literal set of elements of the specified type.
  # Concrete syntax: 2, {3,4}, {5,6,7,} etc.  The elements may be JSON booleans,
  # numbers, or strings.
  # XXX: Now that we have union, we could change lit to accept only a single
  # element, but that will break existing abstract formulas.  Maybe do it
  # if/when we add data type validation?
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
    stringify: (model, vars, type, list) ->
      str:
        # Obviously, if someone manually creates a literal that requires a
        # leading minus or set notation, those constructs will be re-parsed as
        # operators rather than as part of the literal.
        if type == '_root'
          # See stringifyNavigation.  This shouldn't be exposed anywhere else.
          '$'
        else if list.length == 1
          JSON.stringify(list[0])
        else
          # XXX: Canonicalize order?
          '{' + (JSON.stringify(x) for x in list).join(',') + '}'
      outerPrecedence:
        if type == 'number' and list.length == 1 and list[0] < 0
          # Should never be reached by parsing concrete syntax.
          PRECEDENCE_NEG
        else
          PRECEDENCE_ATOMIC

  # ["date", string]
  date:
    argAdapters: [String]
    typecheck: -> 'date'
    evaluate: (model, vars, string) ->
      new TypedSet('date', new EJSONKeyedSet([Date.parse(string)]))
    stringify: (model, vars, string) ->
      str: "d#{JSON.stringify(string)}"
      outerPrecedence: PRECEDENCE_ATOMIC
          
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
    stringify: (model, vars, varName) ->
      str:
        if varName == 'this'
          # A 'this' reference can only occur implicitly in concrete syntax, as
          # the left operand of a navigation.  The following is just a sentinel
          # for stringifyNavigation.
          'this'
        else
          annotateNavigationTarget(model, vars, null, varName, null, ['var', varName])
      outerPrecedence: PRECEDENCE_ATOMIC

  # ["up", startCells, targetColumnId, wantValues (bool)]
  # Concrete syntax: foo, FooCell, (expression).foo, etc.
  up:
    argAdapters: [EagerSubformulaCells, ColumnId, {}]
    validate: (vars, startCellsFmla, targetColumnId, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckUp
    evaluate: goUp
    stringify: (model, vars, startCellsSinfo, targetColumnId, wantValues) ->
      stringifyNavigation('up', model, vars, startCellsSinfo, targetColumnId, null, wantValues)

  # ["down", startCells, targetColumnId, wantValues (bool)]
  # Currently allows only one step, matching the concrete syntax.  This makes
  # life easier for now.
  # XXX: Eventually the easiest way to provide the refactoring support we'll
  # want is to allow multiple steps.  We can see the issue already if startCells
  # changes type from one ancestor of the target column to another, e.g.,
  # because it is reading from another column whose formula changed.
  # Concrete syntax: foo, FooCell, (expression).foo, ::Bar, etc.
  down:
    argAdapters: [EagerSubformulaCells, ColumnId, OptionalEagerSubformula, {}]
    validate: (vars, startCellsFmla, targetColumnId, keysFmla, wantValues) ->
      valAssert(_.isBoolean(wantValues), 'wantValues must be a boolean')
    typecheck: typecheckDown
    evaluate: goDown
    stringify: (model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues) ->
      stringifyNavigation('down', model, vars, startCellsSinfo, targetColumnId, keysSinfo, wantValues)

  # ["if", condition, thenFmla, elseFmla]
  # Concrete syntax: if(condition, thenFmla, elseFmla)
  # (Can we think of a better concrete syntax?)
  if:
    argAdapters: [EagerSubformula, LazySubformula, LazySubformula]
    typecheck: (model, vars, conditionType, thenType, elseType) ->
      type = mergeTypes(thenType, elseType)
      valAssert(type != TYPE_ERROR,
                "Mismatched types in if branches (#{thenType} and #{elseType})")
      type
    evaluate: (model, vars, conditionTset, thenFmla, elseFmla) ->
      evaluateFormula(model, vars,
                      if singleElement(conditionTset.set) then thenFmla else elseFmla)
    stringify: (model, vars, conditionSinfo, thenSinfo, elseSinfo) ->
      str: "if(#{conditionSinfo.strFor(PRECEDENCE_LOWEST)}, #{thenSinfo.strFor(PRECEDENCE_LOWEST)}, #{elseSinfo.strFor(PRECEDENCE_LOWEST)})"
      outerPrecedence: PRECEDENCE_ATOMIC

  count:
    argAdapters: [EagerSubformula]
    typecheck: (model, vars, domainType) -> 'number'
    evaluate: (model, vars, domainTset) ->
      new TypedSet('number', set([domainTset.elements().length]))
    stringify: (model, vars, domainSinfo) ->
      # TODO: Factor out helper for function syntax.
      str: "count(#{domainSinfo.strFor(PRECEDENCE_LOWEST)})"
      outerPrecedence: PRECEDENCE_ATOMIC

  oneOf:
    argAdapters: [EagerSubformula]
    typecheck: (model, vars, domainType) -> domainType
    evaluate: (model, vars, domainTset) ->
      evalAssert(domainTset.elements().length > 0,
                 'oneOf on empty set.')
      new TypedSet(domainTset.type, set([domainTset.elements()[0]]))
    stringify: (model, vars, domainSinfo) ->
      str: "oneOf(#{domainSinfo.strFor(PRECEDENCE_LOWEST)})"
      outerPrecedence: PRECEDENCE_ATOMIC

  # ["filter", domain (subformula), [varName, predicate (subformula)]]:
  # For each cell in the domain, evaluates the predicate with varName bound to
  # the domain cell, which must return a singleton boolean.  Returns the set of
  # domain cells for which the predicate returned true.
  # Concrete syntax: {all x in expr | predicate}
  # XXX: The "all" is to avoid a parser conflict.  It's arguable whether we'd
  # actually like to have both {x in foo | bar} and {x in foo, bar} or this is
  # confusing to users too.  Find a different compromise?
  filter:
    argAdapters: [EagerSubformula, Lambda]
    typecheck: (model, vars, domainType, predicateLambda) ->
      predicateType = predicateLambda(domainType)
      valExpectType('Predicate', predicateType, 'bool')
      domainType
    evaluate: (model, vars, domainTset, predicateLambda) ->
      new TypedSet(
        # XXX Use the checked type instead?
        domainTset.type,
        new EJSONKeyedSet(
          _.filter(domainTset.set.elements(), (x) ->
            # Future: Figure out where to put this code once we start duplicating it.
            tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]))
            singleElement(predicateLambda(tset).set)
          )))
    stringify: (model, vars, domainSinfo, predicateLambda) ->
      # XXX Wasteful
      predicateSinfo = predicateLambda(
        try
          typecheckFormula(model, vars, domainSinfo.formula)
        catch e
          # If we try to stringify a formula that doesn't typecheck, we want to
          # get something half-useful rather than crash.  Any dependent
          # navigations will most likely be marked "problem".
          TYPE_ANY)
      {
        str: "{#{predicateSinfo[0]} : #{domainSinfo.strFor(PRECEDENCE_LOWEST)} " +
             "| #{predicateSinfo[1].strFor(PRECEDENCE_LOWEST)}}"
        outerPrecedence: PRECEDENCE_ATOMIC
      }

  sum:
    argAdapters: [EagerSubformula, Lambda]
    typecheck: (model, vars, domainType, addendLambda) ->
      addendLambda(domainType)
    evaluate: (model, vars, domainTset, addendLambda) ->
      res = 0
      for x in domainTset.elements()
        tset = new TypedSet(domainTset.type, new EJSONKeyedSet([x]))
        res += singleElement(addendLambda(tset).set)
      return new TypedSet('number', new EJSONKeyedSet([res]))
    stringify: (model, vars, domainSinfo, addendLambda) ->
      addendSinfo = addendLambda(
        try
          typecheckFormula(model, vars, domainSinfo.formula)
        catch e
          # If we try to stringify a formula that doesn't typecheck, we want to
          # get something half-useful rather than crash.  Any dependent
          # navigations will most likely be marked "problem".
          TYPE_ANY)
      {
        str: "sum[#{addendSinfo[0]} : #{domainSinfo.strFor(PRECEDENCE_LOWEST)}]" +
             "(#{addendSinfo[1].strFor(PRECEDENCE_LOWEST)})"
        outerPrecedence: PRECEDENCE_ATOMIC
      }

  # Predicates on two sets of the same type.
  '=' : sameTypeSetsInfixPredicate('=' , PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, EJSON.equals)
  '!=': sameTypeSetsInfixPredicate('!=', PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> !EJSON.equals(x, y))
  'in': sameTypeSetsInfixPredicate('in', PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> y.hasAll(x))

  # Unary minus.
  'neg':
    argAdapters: [EagerSubformula]
    typecheck: (model, vars, argType) ->
      valExpectType("Operand of unary '-'", argType, 'number')
      'number'
    evaluate: (model, vars, arg) ->
      new TypedSet('number', set([-singleElement(arg.set)]))
    stringify: (model, vars, argSinfo) ->
      str: "-#{argSinfo.strFor(PRECEDENCE_NEG)}"
      outerPrecedence: PRECEDENCE_NEG

  '+' : singletonInfixOperator('+' , PRECEDENCE_PLUS   , ASSOCIATIVITY_LEFT, 'number', 'number', 'number', (x, y) -> x +  y)
  '-' : singletonInfixOperator('-' , PRECEDENCE_PLUS   , ASSOCIATIVITY_LEFT, 'number', 'number', 'number', (x, y) -> x -  y)
  '*' : singletonInfixOperator('*' , PRECEDENCE_TIMES  , ASSOCIATIVITY_LEFT, 'number', 'number', 'number', (x, y) -> x *  y)
  '/' : singletonInfixOperator('/' , PRECEDENCE_TIMES  , ASSOCIATIVITY_LEFT, 'number', 'number', 'number', (x, y) -> x /  y)
  '^' : singletonInfixOperator('^' , PRECEDENCE_POW    , ASSOCIATIVITY_RIGHT,'number', 'number', 'number', Math.pow)
  
  '<' : compareInfixOperator(  '<' , PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> x <  y)
  '<=': compareInfixOperator(  '<=', PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> x <= y)
  '>' : compareInfixOperator(  '>' , PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> x >  y)
  '>=': compareInfixOperator(  '>=', PRECEDENCE_COMPARE, ASSOCIATIVITY_NONE, (x, y) -> x >= y)

  # TODO: Short circuit?
  '&&': singletonInfixOperator('&&', PRECEDENCE_AND, ASSOCIATIVITY_LEFT, 'bool', 'bool', 'bool', (x, y) -> x && y)
  '||': singletonInfixOperator('||', PRECEDENCE_OR, ASSOCIATIVITY_LEFT, 'bool', 'bool', 'bool', (x, y) -> x || y)
  '!':
    argAdapters: [EagerSubformula]
    typecheck: (model, vars, argType) ->
      valExpectType("Operand of '!'", argType, 'bool')
      'bool'
    evaluate: (model, vars, arg) ->
      new TypedSet('bool', set([!singleElement(arg.set)]))
    stringify: (model, vars, argSinfo) ->
      str: "!#{argSinfo.strFor(PRECEDENCE_NEG)}"
      outerPrecedence: PRECEDENCE_NEG

  # ["union", list of subformulas]
  # Union of a fixed number of sets.
  union:
    argAdapters: [HomogeneousEagerSubformulaList]
    typecheck: (model, vars, termsType) -> termsType
    evaluate: (model, vars, terms) ->
      res = new TypedSet()
      for term in terms
        res.addAll(term)
      res
    stringify: (model, vars, termSinfos) ->
      str: '{' + (termSinfo.strFor(PRECEDENCE_LOWEST) for termSinfo in termSinfos).join(', ') + '}'
      outerPrecedence: PRECEDENCE_ATOMIC

}

# Catches syntax errors, references to nonexistent bound variables, and
# variable shadowing, but not anything related to schema, data, or types.
# vars: EJSONKeyedSet<string>
validateSubformula = (vars, formula) ->
  valAssert(_.isArray(formula), 'Subformula must be an array.')
  valAssert(_.isString(opName = formula[0]), 'Subformula must begin with an operation name (a string).')
  valAssert(dispatch.hasOwnProperty(opName),
            "Unknown operation '#{opName}'")
  d = dispatch[opName]
  args = formula[1..]
  valAssert(args.length == d.argAdapters.length,
            "Wrong number of arguments to '#{opName}' (required #{d.argAdapters.length}, got #{args.length})")
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
  formula.vars = vars
  formula.type = dispatchFormula('typecheck', formula, model, vars)

# Assumes formula has passed typechecking.
# vars: EJSONKeyedMap<string, TypedSet>
@evaluateFormula = (model, vars, formula) ->
  try
    result = dispatchFormula('evaluate', formula, model, vars)
  catch e
    if e instanceof EvaluationError && model.isTracing
      formula.traces ?= new EJSONKeyedMap()
      formula.traces.set(vars, {error: e.message})
    throw e
  if model.isTracing
    formula.traces ?= new EJSONKeyedMap()
    formula.traces.set(vars, {result: result})
  result

# TODO: Separate out the determination of the initial variable values so we can
# reuse the rest for formulas in procedures, etc.
@traceColumnFormula = (formula, columnId) ->
  tracingModel = {
    getColumn: (columnId) -> getColumn(columnId)
    evaluateFamily: (qFamilyId) -> evaluateFamilyReadOnly(qFamilyId)
    typecheckColumn: (columnId) -> getColumn(columnId).type
    isTracing: true
  }
  # Find all cells in parent column
  parentColumnId = getColumn(columnId).parent
  parentColumnCellIds = []
  # Here we really do want to ignore erroneous families in the parent column
  # because there is nothing to trace for them.
  for family in Cells.find({column: parentColumnId}).fetch() when family.values?
    for v in family.values
      parentColumnCellIds.push(cellIdChild(family.key, v))
  for cellId in parentColumnCellIds
    try
      vars = new EJSONKeyedMap(
        [['this', new TypedSet(parentColumnId, new EJSONKeyedSet([cellId]))]])
      evaluateFormula(tracingModel, vars, formula)
    catch e
      if e instanceof EvaluationError
        # Ignore; already traced.
      else
        throw e

@DUMMY_FORMULA = ['union', []]

# BELOW: Concrete syntax support.  However, this is used on the server, by
# loadPTCData!

validateAndTypecheckFormula = (model, vars, formula) ->
  validateSubformula(new EJSONKeyedSet(vars.keys()), formula)
  return typecheckFormula(model, vars, formula)

# Handle startCellsFmla.targetName or targetName by itself
# (startCellsFmla == null), which may also be a variable reference.
# vars: EJSONKeyedMap<string, type (string)>
# Returns the new formula with the call to "up" or "down" added around
# startCellsFmla.
resolveNavigation = (model, vars, startCellsFmla, targetName, keysFmla) ->
  interpretations = []
  unless startCellsFmla?
    if vars.get('this')? && !typeIsPrimitive(vars.get('this'))
      valAssert(targetName != 'this',
                'Explicit "this" is not allowed in concrete syntax.  ' +
                'Please use the object name for clarity.')
      if vars.get(targetName)?
        interpretations.push(['var', targetName])
      startCellsFmla = ['var', 'this']
      # Fall through to navigation interpretations.
    else  # i.e., in procedures
      # Easier than trying to generalize the error message below.
      valAssert(vars.get(targetName)?, "Undefined variable #{targetName}")
      return ['var', targetName]

  # XXX: This is a lot of duplicate work reprocessing subtrees.
  startCellsType = validateAndTypecheckFormula(model, vars, startCellsFmla)
  valAssert(startCellsType && !typeIsPrimitive(startCellsType), "Expected a set of cells, got set of '#{startCellsType}'")

  # Check logical ancestor objects (no keys).
  # Note, it's impossible to navigate to the root column since it has no field name or
  # object name.
  [upPath, dummyDownPath] = findCommonAncestorPaths(startCellsType, rootColumnId)
  for upColumnId in upPath
    if objectNameWithFallback(getColumn(upColumnId)) == targetName
      interpretations.push(['up', startCellsFmla, upColumnId, false])

  # Check logical children.
  for [columnId, isValues, direction] in columnLogicalChildrenByName(startCellsType, targetName)
    interpretations.push([direction, startCellsFmla, columnId, isValues])

  # Future: Enforce uniqueness of interpretations in any scope?
  valAssert(interpretations.length == 1,
            "#{interpretations.length} possible interpretations for " +
            "<type #{startCellsType}>.#{targetName}, wanted one.")
  formula = interpretations[0]

  if formula[0] == 'down'
    # typecheckDown checks the rest of the requirements for subscripting.
    formula.splice(3, 0, keysFmla)
  else
    # We have to check this here so we don't silently ignore the subscript.
    # XXX: When navigating to a key column, this error message is inconsistent
    # with the user-facing model, in which such a navigation is down.
    valAssert(!keysFmla?, 'Only down navigations can be subscripted with keys.')

  # If Bar is an object type with key foo, "(...).Bar.foo" parses as
  # ['up', ['down', ..., fooID, null, false], fooID, true].  Convert to
  # ['down', ..., fooID, null, true] so it displays as "(...).foo" if the object
  # type is removed.  (Converse of the case in stringifyNavigation.)
  if (formula[0] == 'up' && formula[3] &&
      formula[1][0] == 'down' && formula[1][2] == formula[2] &&
      !formula[1][3]? && !formula[1][4])
    formula = ['down', formula[1][1], formula[2], null, true]

  return formula

@liteModel = {
  # Eta-expand to avoid load-order dependency.
  getColumn: (columnId) -> getColumn(columnId)
  typecheckColumn: (columnId) -> getColumn(columnId).type || throw new Error("Not ready")
}

# Reused by parseProcedure. :/
@setupParserCommon = (startToken, vars) ->
  parser = new Jison.Parsers.language.Parser()
  parser.yy.vars = vars.shallowClone()
  parser.yy.startToken = startToken
  parser.yy.bindVar = (varName, formula, allowOverwrite) ->
    unless allowOverwrite
      valAssert(!this.vars.get(varName)?, 'Shadowing variable ' + varName)
    this.vars.set(varName, validateAndTypecheckFormula(liteModel, this.vars, formula))
  parser.yy.unbindVar = (varName) ->
    this.vars.delete(varName)
  parser.yy.navigate = (startCellsFmla, targetName, keysFmla) ->
    resolveNavigation(liteModel, this.vars, startCellsFmla, targetName, keysFmla)
  parser.yy.parseError = (err, hash) -> throw new SyntaxError(err, hash)
  return parser

@parseFormula = (thisType, fmlaString) ->
  # XXX: If we are changing a formula so as to introduce a new cyclic type
  # checking dependency, we use the old types of the other columns to interpret
  # navigations in the new formula.  However, as soon as we save, all the
  # columns in the cycle will change to TYPE_ERROR and the navigations we just
  # interpreted will become invalid.  This behavior is weird but not worth
  # fixing now.

  parser = setupParserCommon('FORMULA', new EJSONKeyedMap([['this', thisType]]))

  try
    return parser.parse(fmlaString)
  catch e
    if e instanceof SyntaxError
      throw new FormulaValidationError(e.message)
    else
      throw e

stringifySubformula = (model, vars, formula) ->
  res = dispatchFormula('stringify', formula, model, vars)
  {
    # Save original: used by stringifyNavigation.  (Might not be the best design.)
    formula: formula
    strFor: (lowestSafePrecedence) ->
      if res.outerPrecedence >= lowestSafePrecedence
        res.str
      else
        "(#{res.str})"
  }

@stringifyFormula = (thisType, formula) ->
  # Stringify should only happen after type checking, so it can use liteModel on
  # either client or server.
  stringifySubformula(
    liteModel, new EJSONKeyedMap([['this', thisType]]), formula).strFor(PRECEDENCE_LOWEST)

@getSubformulaTree = (formula) ->
  d = dispatch[formula[0]]
  args = formula[1..]
  children = []
  for adapter, i in d.argAdapters
    if adapter.getSubformulas?
      children.push(adapter.getSubformulas(args[i])...)
  {
    formula: formula
    children: getSubformulaTree(f) for f in children
  }

exported {FormulaEngine}
