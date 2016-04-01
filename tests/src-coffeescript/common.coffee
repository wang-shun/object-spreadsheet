# Relational Spreadsheets definitions needed by both client and server that
# don't fall into a more specific file such as formulas.coffee.

@rootColumnId = '_root'

# Multisets unsupported for now: twindex removed.

@rootCellId = []
@cellIdParent = (cellId) -> cellId[0...-1]
@cellIdChild = (cellId, value) -> cellId.concat([value])
@cellIdLastStep = (cellId) -> cellId[cellId.length - 1]

# N.B. Meteor.makeErrorType is the way to make a subclass of Error so that both
# instanceof and stack traces work.

# Careful: with "class EvaluationError", the original class gets assigned to a
# file-scope variable that shadows the exported wrapped class seen by the rest
# of the application, and instanceof breaks.
class EvaluationError_
  constructor: (@message) ->
@EvaluationError = Meteor.makeErrorType('EvaluationError', EvaluationError_)

# Used also for typechecking.
class FormulaValidationError_
  constructor: (@message) ->
@FormulaValidationError = Meteor.makeErrorType('FormulaValidationError', FormulaValidationError_)

class SyntaxError_
  constructor: (@message, @details) ->
@SyntaxError = Meteor.makeErrorType('SyntaxError', SyntaxError_)

class SemanticError_
  constructor: (@message) ->
@SemanticError = Meteor.makeErrorType('SemanticError', SemanticError_)

# Model data structures and parameters the client needs to be aware of:
# (I tried using EJSON custom classes but it was too much of a pain to store in
# the DB.  If I find a good solution, we could go back to using EJSON custom
# classes. ~ Matt)

# Column:
#@_id
#@parent: column ID
#@children: array of column IDs, now in the user's desired order
#@fieldName: string or null
#@specifiedType: type specified by user (required for state columns)
#@type: checked type (always set during evaluation)
#@typecheckError: string or null, formula type checking error message
#@isObject: boolean
#  (We could alternatively encode this by making @children nullable.)
#@objectName: string or null
#@formula: some JSON data structure, or null for a state column

@getColumn = (id) -> Columns.findOne(id)

@columnIsState = (col) -> col._id != rootColumnId && !col.formula?

@objectNameWithFallback = (col) ->
  col.objectName ? (if col.fieldName? then "[#{col.fieldName}]" else null)

@columnDepth = (columnId) ->
  if columnId == rootColumnId then 0
  else 1 + columnDepth(getColumn(columnId).parent)

@nextAvailableColumnName = (prefix) ->
  i = 1
  while Columns.find({$or: [{fieldName: "#{prefix}#{i}"},
                            {objectName: "#{prefix}#{i}"}]}).count() > 0
    i++
  return "#{prefix}#{i}"

# This implements the user-facing conceptual model in which a key is a child of the object.
# Precondition: getColumn(id).isObject == true
# Returns: list of [child id, isValues, direction]
# Having direction here is a little awkward but lets us reuse this in resolveNavigation.
@columnLogicalChildrenByName = (id, wantName) ->
  col = getColumn(id)
  ret = []
  visit = (name, descriptor) ->  # descriptor = [childId, isValues, direction]
    if name == wantName then ret.push(descriptor)
    return
  visit(col.fieldName, [id, true, 'up'])
  for physChildCol in Columns.find({parent: id}).fetch()
    if physChildCol.isObject
      visit(objectNameWithFallback(physChildCol), [physChildCol._id, false, 'down'])
    else
      visit(physChildCol.fieldName, [physChildCol._id, true, 'down'])
  return ret

@stringifyType = (type) ->
  if typeIsReference(type)
    stringifyColumnRef([type, false])
  else
    type

@parseTypeStr = (s) ->
  # This is an abuse of typeIsReference, since s is a UI-level (not internal)
  # type string, but it will work to check whether s is recognized as the name
  # of a non-reference type.
  if typeIsReference(s)
    parseObjectTypeRef(s)
  else
    s

@parseObjectTypeRef = (s) ->
  colId2 = parseColumnRef(s)
  if colId2[1]
    throw new SemanticError("'#{s}' refers to a value column, not an object type.")
  return colId2[0]

# Compare to resolveNavigation.
# Returns: [columnId, isValues]
@parseColumnRef = (s) ->
  unless s
    # What we currently want for user-facing usage.  load-sample-data has to
    # override this behavior. :/
    throw new SemanticError('We currently do not support references to the root column.')
  colId2 = [rootColumnId, false]
  for n in s.split(':')
    if colId2[1]
      throw new SemanticError("Looking up child '#{n}' of a value column.")
    interpretations = columnLogicalChildrenByName(colId2[0], n)
    if interpretations.length != 1
      throw new SemanticError(
        "#{interpretations.length} interpretations for "+
        "#{stringifyColumnRef(colId2)}:#{n}, wanted one.")
    colId2 = interpretations[0][0..1]
  return colId2

# Compare to stringifyNavigation.
@stringifyColumnRef = ([columnId, isValues]) ->
  if columnId == rootColumnId
    # XXX Consider reenabling the error after more testing. ~ Matt 2015-11-25
    #throw new SemanticError('We currently do not support references to the root column.')
    return '$'
  names = []
  while columnId != rootColumnId
    col = getColumn(columnId)
    unless col?
      return '(deleted)'
    name = if isValues then col.fieldName else objectNameWithFallback(col)
    logicalParent = if isValues && col.isObject then columnId else col.parent
    if name?
      if columnLogicalChildrenByName(logicalParent, name).length != 1
        name += '(ambiguous)'
    else
      name = '(unnamed)'
    names.unshift(name)
    isValues = false
    columnId = logicalParent
  return names.join(':')

# Finds the lowest common ancestor of columnId1 and columnId2 and returns a
# pair of arrays giving the sequences of ancestors from columnId1 and
# columnId2 (respectively) to the common ancestor, inclusive.
@findCommonAncestorPaths = (columnId1, columnId2) ->
  ancestors1 = []
  cid = columnId1
  loop
    ancestors1.push(cid)
    break if cid == rootColumnId
    cid = getColumn(cid).parent
  ancestors2 = []
  cid = columnId2
  loop
    ancestors2.push(cid)
    # We could make this not O(N^2) if we cared...
    break if (idx = ancestors1.indexOf(cid)) != -1
    cid = getColumn(cid).parent
  ancestors1.splice(idx + 1, ancestors1.length - (idx + 1))
  return [ancestors1, ancestors2]

# The empty type, subtype of all other types, used for literal empty sets, etc.
# Not allowed for state columns.
@TYPE_EMPTY = 'empty'

@TYPE_ERROR = 'error'

@MAIN_PRIMITIVE_TYPES = ['text', 'number', 'bool', 'date']
@DEFAULT_STATE_FIELD_TYPE = 'text'

# Other special types:
# _root: reference, should never be user-visible (no concrete syntax to get at it)
# _unit: primitive, deprecated but still used in ptc
# _token: special primitive, should never be user-visible

NON_REFERENCE_TYPES = [TYPE_EMPTY, TYPE_ERROR].concat(MAIN_PRIMITIVE_TYPES)

# It's messy to have some primitive types that begin with underscore and others
# that don't.  We could have hidden the underscore only in the UI, though at
# this stage of development, it might have been too costly in terms of us
# forgetting that the underscore should be present internally.  Or we could have
# chosen a different representation altogether.  But that's too much work at the
# moment. :( ~ Matt 2015-11-13
@typeIsReference = (type) -> type == rootColumnId || (!/^_/.test(type) && type not in NON_REFERENCE_TYPES)

@commonSupertype = (t1, t2) ->
  if t1 != TYPE_EMPTY
    if t2 != TYPE_EMPTY && t2 != t1
      TYPE_ERROR
    else
      t1
  else
    t2


class @TypedSet
  # public fields
  #@type: column ID or primitive, or TYPE_EMPTY if we don't know because the set is empty.
  #@set: EJSONKeyedSet<@type>
  constructor: (@type = TYPE_EMPTY, @set = new EJSONKeyedSet()) ->

  # Note, these can make a meaningless mess if the types are mixed.  The caller
  # has to check @type afterwards.
  add: (xType, x) ->
    @type = commonSupertype(@type, xType)
    @set.add(x)
    return
  addAll: (tset) ->
    @type = commonSupertype(@type, tset.type)
    for e in tset.set.elements()
      @set.add(e)
    return

  elements: -> @set.elements()

  typeName: -> 'TypedSet'
  toJSONValue: -> {type: @type, set: @set.toJSONValue()}
  @fromJSONValue: (json) ->
    new TypedSet(json.type, EJSONKeyedSet.fromJSONValue(json.set))
EJSON.addType('TypedSet', TypedSet.fromJSONValue)


# The next two definitions are exported for the action bar.

@allowedReferenceDisplayColumns = (col) ->
  allowed = []
  # XXX: Duplicating logic from columnLogicalChildrenByName?  (Avoiding this
  # would require a comprehensive emulation layer for keys as fields.)
  if col.type != '_token'
    allowed.push(col._id)
  for childColId in col.children
    childCol = getColumn(childColId)
    if !childCol.isObject
      allowed.push(childColId)
  allowed

@defaultReferenceDisplayColumn = (col) ->
  # Current heuristic: First allowed.
  #
  # NOTE: Formulas are allowed to depend on the default reference display column
  # via toText, so reordering columns may change the spreadsheet values!  This
  # is a little surprising, but I think it's better than any of the
  # alternatives. ~ Matt 2015-11-20
  #
  # Ideas:
  # - Prefer a tuple of fields declared unique, if and when we have that
  #   information.
  # - Require singular once we have that information.
  # - Automatically detect certain field names, e.g., "name" or "title"?  A hack
  #   but maybe the right thing in this context.

  allowed = allowedReferenceDisplayColumns(col)
  if allowed.length > 0 then allowed[0] else null

# Used on the server to reparse values in changeColumnSpecifiedType.
@parseValue = (type, text) ->
  if typeIsReference(type)
    # Ignore erroneous families: they do not contain any objects we can match against.
    # Also ignore references that fail to convert to text.
    matchingCells = []
    for cellId in allCellIdsInColumnIgnoreErrors(type)
      try
        if text == valueToText(liteModel, type, cellId)
          matchingCells.push(cellId)
      catch e
        # Skip
    if matchingCells.length == 1
      return matchingCells[0]
    else if matchingCells.length > 1
      throw new Error("The entered text matches #{matchingCells.length} '#{stringifyType(type)}' objects.  " +
                      "Choose a reference display column for '#{stringifyType(type)}' that has unique values, " +
                      "or define a new computed column if necessary.")  # "or enter the @n notation instead"
    else
      throw new Error("The entered text does not match any existing '#{stringifyType(type)}' object.")
  else if type == '_unit'
    'X'
  else if type == '_token'
    # XXX: Is this OK or do we want the server to generate the token?  For
    # unprivileged users, we probably want the server to generate it, but we
    # may not reuse this code for unprivileged users anyway.
    Random.id()
  else if type == 'text'
    text
  else if type == 'date'
    Date.parse(text) || throw new Error("Invalid date: '#{text}'")
  else
    JSON.parse text
