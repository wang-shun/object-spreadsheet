# Utility definitions not specific to Relational Spreadsheets.

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
  size: -> _.size(@obj)
  keys: -> unwrapKey(wk) for wk of @obj
  entries: -> [unwrapKey(wk), v] for wk, v of @obj
  shallowClone: -> new EJSONKeyedMap(@entries())
  typeName: -> 'EJSONKeyedMap'
  # Note, this only works if the values are EJSON-compatible.
  toJSONValue: -> EJSON.toJSONValue(@obj)
  @fromJSONValue: (json) ->
    m = new EJSONKeyedMap()
    m.obj = EJSON.fromJSONValue(json)
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
  size: -> @map.size()
  elements: -> @map.keys()
  shallowClone: -> new EJSONKeyedSet(@elements())
  typeName: 'EJSONKeyedSet'
  toJSONValue: -> @map.toJSONValue()
  @fromJSONValue: (json) ->
    s = new EJSONKeyedSet()
    s.map = EJSONKeyedMap.fromJSONValue(json)
    s
EJSON.addType('EJSONKeyedSet', EJSONKeyedSet.fromJSONValue)

class @EJSONSmallSet
  constructor: (els = [], _trustMeDistinct=false) ->
    if _trustMeDistinct
      @els = els[..]
    else
      @els = []
      for x in els
        @add(x)
  has: (x) -> exists @els, (y) -> EJSON.equals(x,y)
  hasAll: (s) -> forall @els, (x) => @has x
  add: (x) -> if !@has(x) then @els.push x
  delete: (x) -> @els = @els.filter (y) -> !EJSON.equals(x,y)
  elements: -> @els
  shallowClone: -> new EJSONSmallSet(@els, true)
  typeName: 'EJSONSmallSet'
  toJSONValue: -> @els
  @fromJSONValue: (json) -> new EJSONSmallSet(json, true)
EJSON.addType('EJSONSmallSet', EJSONSmallSet.fromJSONValue)

#@EJSONKeyedSet = EJSONSmallSet


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

class Tree
  constructor: (@root, @subtrees=[]) ->

  ## applies op to the root of each subtree
  map: (op) ->
    new Tree op(@root), (s.map op for s in @subtrees)

  filter: (pred) ->
    if pred @root
      new Tree @root, ((s.filter pred for s in @subtrees).filter (x) -> x?)
    else null

  find: (value) ->
    @findT (n) -> n.root == value

  findT: (pred) ->
    if pred @ then @
    else
      for s in @subtrees
        if (n = s.findT(pred))? then return n

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


class Memo
  constructor: -> @values = {}
  clear: -> @values = {}
  get: (key, recompute) ->
    if (v = @values[key])? then v
    else @values[key] = recompute()


# helper functions
forall = (list, pred) ->
  for x in list
    if !pred(x) then return false
  true
exists = (list, pred) ->
  for x in list
    if pred(x) then return true
  false
without = (list, item) -> list.filter (x) -> x != item

zip = () ->
  lengthArray = (arr.length for arr in arguments)
  length = Math.min(lengthArray...)
  for i in [0...length]
    arr[i] for arr in arguments

set = (x) -> new EJSONKeyedSet(x)
T = -> new Tree(arguments...)

exported {set, Tree, T, Digraph, Memo, forall, exists, without, zip}
