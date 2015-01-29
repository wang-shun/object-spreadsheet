@rootColumnId = '_root'

@typeIsPrimitive = (type) -> type != rootColumnId && /^_/.test(type)

# Multisets unsupported for now: twindex removed.

@rootCellId = []
@cellIdParent = (cellId) -> cellId[0..-2]
@cellIdChild = (cellId, value) -> cellId.concat([value])
@cellIdLastStep = (cellId) -> cellId[cellId.length - 1]

class SemanticError extends Error

# Model data structures and parameters the client needs to be aware of:
# (I tried using EJSON custom classes but it was too much of a pain to store in
# the DB.  If I find a good solution, we could go back to using EJSON custom
# classes. ~ Matt)

# Column:
#@_id
#@parent: column ID
#@children: array of column IDs, now in the user's desired order
#@childByName: EJSONKeyedMap<name, column ID>
#@numStateCells: integer (state columns only)
#@name: string or null
#@type: column ID or primitive; null for formula columns
#@cellName: string or null
#@formula: some JSON data structure, or null

@columnIsState = (col) -> col._id != rootColumnId && !col.formula?
@columnIsToken = (col) -> col.type == '_token'

# Requires that an appropriate global getColumn function be defined.
@parseTypeStr = (s) ->
  if typeIsPrimitive(s)
    s
  else
    @parseColumnRef s

@parseColumnRef = (s) ->
  if getColumn(s)? then return s  # Any other way to recognize ids vs. names?
  colId = rootColumnId
  for n in s.split(':')
    # XXX: Maybe types should accept cellName only.
    if Meteor.isServer
      colId = getColumn(colId).childByName.get(n)
    else
      # no childByName. make it?
      colId = Columns.findOne {parent: colId, $or: [ {name: n}, {cellName: n} ]}
        ?._id
    if !colId
      throw new SemanticError("column lookup failed: '#{s}'")
  return colId

# CacheEntry:
#@state: one of FAMILY_{IN_PROGRESS,SUCCESS,ERROR}
##@deps: array of QFamilyId - Only needed if we want to revalidate existing results.
#@content: TypedSet if state is SUCCESS, otherwise null

@FAMILY_DATA_COLLECTION = 'familyData'
@FAMILY_IN_PROGRESS = 1  # should not be seen by the client
@FAMILY_SUCCESS = 2
@FAMILY_ERROR = 3

if Meteor.isClient
  @getColumn = (id) -> Columns.findOne(id)

# {_id: formula column ID, _type: type}
@FORMULA_COLUMN_TYPE_COLLECTION = 'formulaColumnType'
@TYPE_MIXED = '_mixed'

# Now that we're no longer using custom classes, we might be able to use plain
# JSON, but we've written this already...

class @EJSONKeyedMap
  constructor: (ents = []) ->
    # Future: Change to ECMAScript 6 Map when supported by all relevant JS
    # engines and CoffeeScript.
    @obj = {}
    for [k, v] in ents
      @set(k, v)
  wrapKey = (k) -> 'map_' + EJSON.stringify(k)
  unwrapKey = (k) -> EJSON.parse(k.substr(4))

  get: (k) -> @obj[wrapKey(k)]
  set: (k, v) -> @obj[wrapKey(k)] = v
  delete: (k) -> delete @obj[wrapKey(k)]
  keys: -> unwrapKey(wk) for wk of @obj
  entries: -> [unwrapKey(wk), v] for wk, v of @obj
  shallowClone: -> new EJSONKeyedMap(@entries())
  typeName: -> 'EJSONKeyedMap'
  # Note, this only works if the values are EJSON-compatible.
  toJSONValue: -> @obj
  @fromJSONValue: (json) ->
    m = new EJSONKeyedMap()
    m.obj = json
    m
EJSON.addType('EJSONKeyedMap', EJSONKeyedMap.fromJSONValue)

class @EJSONKeyedSet
  constructor: (els = []) ->
    @map = new EJSONKeyedMap()
    for x in els
      @add(x)
  has: (x) -> !!@map.get(x)
  hasAll: (s) -> forall s.elements(), (x) => @has x
  add: (x) -> @map.set(x, true)
  delete: (x) -> @map.delete(x)
  elements: -> @map.keys()
  shallowClone: -> new EJSONKeyedSet(@elements())
  typeName: 'EJSONKeyedSet'
  toJSONValue: -> @map.toJSONValue()
  @fromJSONValue: (json) ->
    s = new EJSONKeyedSet()
    s.map = EJSONKeyedMap.fromJSONValue(json)
    s
EJSON.addType('EJSONKeyedSet', EJSONKeyedSet.fromJSONValue)

class @EJSONKeyedMapToSet
  constructor: ->
    @map = new EJSONKeyedMap()
  add: (k, v) ->
    s = @map.get(k)
    unless s?
      s = new EJSONKeyedSet()
      @map.set(k, s)
    s.add(v)
  delete: (k, v) ->
    s = @map.get(k)
    if s?
      s.delete(v)
      if s.elements().length == 0
        @map.delete(k)
  keys: -> @map.keys()
  has: (k, v) -> (s = @map.get(k))? && s.has(v)
  elementsFor: (k) -> @map.get(k)?.elements() ? []

@EJSONtoMongoFieldName = (x) ->
  # JSON may contain '.', which is special in Mongo field names, as part of a
  # floating point or string literal.  We need to escape it somehow.  '!' should
  # only appear as a character in a string literal, so if we replace it by its
  # escaped form, then we can use '!' to represent '.'.
  EJSON.stringify(x).replace('!', '\\x21').replace('.', '!')

@EJSONfromMongoFieldName = (f) ->
  EJSON.parse(f.replace('!', '.'))

@mergeTypes = (t1, t2) ->
  if t1?
    if t2? && t2 != t1
      TYPE_MIXED
    else
      t1
  else
    t2

class @TypedSet
  # public fields
  #@type: column ID or primitive, or null if we don't know because the set is empty.
  #@set: EJSONKeyedSet<@type>
  constructor: (@type = null, @set = new EJSONKeyedSet()) ->

  # Note, these can make a meaningless mess if the types are mixed.  The caller
  # has to check @type afterwards.
  add: (xType, x) ->
    @type = mergeTypes(@type, xType)
    @set.add(x)
  addAll: (tset) ->
    @type = mergeTypes(@type, tset.type)
    for e in tset.set.elements()
      @set.add(e)

  elements: -> @set.elements()

  typeName: -> 'TypedSet'
  toJSONValue: -> {type: @type, set: @set.toJSONValue()}
  @fromJSONValue: (json) ->
    new TypedSet(json.type, EJSONKeyedSet.fromJSONValue(json.set))
EJSON.addType('TypedSet', TypedSet.fromJSONValue)


class Tree
  constructor: (@root, @subtrees=[]) ->

  ## applies op to the root of each subtree
  map: (op) ->
    new Tree op(@root), (s.map op for s in @subtrees)

  filter: (pred) ->
    if pred @root
      new Tree @root, ((s.filter pred for s in @subtrees).filter (x) -> x?)
    else null

  typeName: -> 'Tree'
  toJSONValue: -> {@root, subtrees: (s.toJSONValue() for s in @subtrees)}
  @fromJSONValue: (json) ->
    new Tree(json.root, (Tree.fromJSONValue(s) for s in json.subtrees))
EJSON.addType('Tree', Tree.fromJSONValue)


class Digraph
  class @Node
    constructor: (@label) ->
      @in = []
      @out = []
  class @Edge
    constructor: (@from, @to, @label=null) ->

  constructor: ->
    @nodes = []
    @edges = []

  add: (el) ->
    if el instanceof Digraph.Node
      @nodes.push el
    else if el instanceof Digraph.Edge
      @edges.push el
      el.from.out.push el
      el.to.in.push el
    else
      throw new Error("expected Digraph.Node or Digraph.Edge, got #{el}")

  remove: (el) ->
    if el instanceof Digraph.Node
      for e in el.in.concat el.out
        @remove e
      @nodes = without @nodes, el
    else if el instanceof Digraph.Edge
      el.from.out = without el.from.out, el
      el.to.in = without el.to.in, el
      @edges = without @edges, el

  disconnectIn: (node) ->
    for e in node.in
      e.from.out = without e.from.out, e
    node.in = []

  has: (el) ->
    el in @nodes || el in @edges

  findNode: (label, force=false) ->
    for u in @nodes
      if u.label == label then return u
    if force
      u = new Digraph.Node label
      @add u
      u

  fromPairs: (listOfPairs) ->
    node = (x) => @findNode(x, force: true)
    for e in listOfPairs
      @add new Digraph.Edge (node e[0]), (node e[1])

  @fromPairs: (listOfPairs) ->
    g = new @ ; g.fromPairs(listOfPairs)
    g

  topologicalSort: ->
    visited = []
    stack = []
    visit = (u) ->
      visited.push u
      for e in u.out
        v = e.to
        if v not in visited then visit v
      stack.push u
    for u in @nodes
      if u not in visited then visit u
    stack.reverse()

# helper functions
forall = (list, pred) ->
  for x in list
    if !pred(x) then return false
  true
without = (list, item) -> list.filter (x) -> x != item


set = (x) -> new EJSONKeyedSet(x)
T = -> new Tree(arguments...)

exported = (d) ->
  for k,v of d
    @[k] = v

exported {exported, set, Tree, T, Digraph, SemanticError}
