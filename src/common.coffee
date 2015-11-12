# Relational Spreadsheets definitions needed by both client and server that
# don't fall into a more specific file such as formulas.coffee.

@rootColumnId = '_root'

PRIMITIVE_TYPES = ['text', 'number', 'bool', 'date']

@typeIsPrimitive = (type) -> type != rootColumnId && /^_/.test(type) || type in PRIMITIVE_TYPES

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
@EvaluationError = Meteor.makeErrorType('EvaluationError',
  class @EvaluationError
    constructor: (@message) ->
)

# Used also for typechecking.
@FormulaValidationError = Meteor.makeErrorType('FormulaValidationError',
  class @FormulaValidationError
    constructor: (@message) ->
)

@SyntaxError = Meteor.makeErrorType('SyntaxError',
  class @SyntaxError
    constructor: (@message, @details) ->
)

@SemanticError = Meteor.makeErrorType('SemanticError',
  class @SemanticError
    constructor: (@message) ->
)

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

# This implements the user-facing conceptual model in which a key is a child of the object.
# Precondition: getColumn(id).isObject == true
# Returns: list of [child id, isValues, direction]
# Having direction here is a little awkward but lets us reuse this in resolveNavigation.
@columnLogicalChildrenByName = (id, wantName) ->
  col = getColumn(id)
  ret = []
  visit = (name, descriptor) ->  # descriptor = [childId, isValues, direction]
    if name == wantName then ret.push(descriptor)
  visit(col.fieldName, [id, true, 'up'])
  for physChildCol in Columns.find({parent: id}).fetch()
    if physChildCol.isObject
      visit(objectNameWithFallback(physChildCol), [physChildCol._id, false, 'down'])
    else
      visit(physChildCol.fieldName, [physChildCol._id, true, 'down'])
  return ret

@parseTypeStr = (s) ->
  if typeIsPrimitive(s)
    s
  else
    parseObjectTypeRef(s)

@parseObjectTypeRef = (s) ->
  colId2 = parseColumnRef(s)
  if colId2[1]
    throw new SemanticError("#{s} refers to a value column, not an object type.")
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
      throw new SemanticError("Looking up child #{n} of a value column.")
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
    throw new SemanticError('We currently do not support references to the root column.')
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
@TYPE_EMPTY = '_empty'
@TYPE_ERROR = '_error'

@commonSupertype = (t1, t2) ->
  if t1 != TYPE_EMPTY
    if t2 != TYPE_EMPTY && t2 != t1
      TYPE_ERROR
    else
      t1
  else
    t2


class TypedSet
  # public fields
  #@type: column ID or primitive, or TYPE_EMPTY if we don't know because the set is empty.
  #@set: EJSONKeyedSet<@type>
  constructor: (@type = TYPE_EMPTY, @set = new EJSONKeyedSet()) ->

  # Note, these can make a meaningless mess if the types are mixed.  The caller
  # has to check @type afterwards.
  add: (xType, x) ->
    @type = commonSupertype(@type, xType)
    @set.add(x)
  addAll: (tset) ->
    @type = commonSupertype(@type, tset.type)
    for e in tset.set.elements()
      @set.add(e)

  elements: -> @set.elements()

  typeName: -> 'TypedSet'
  toJSONValue: -> {type: @type, set: @set.toJSONValue()}
  @fromJSONValue: (json) ->
    new TypedSet(json.type, EJSONKeyedSet.fromJSONValue(json.set))
EJSON.addType('TypedSet', TypedSet.fromJSONValue)


exported {TypedSet}
