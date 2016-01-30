# Utility definitions not specific to Relational Spreadsheets.

# Now that we're no longer using custom classes, we might be able to use plain
# JSON, but we've written this already...

class EJSONKeyedMap
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
exported {EJSONKeyedMap}

class EJSONKeyedSet
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
exported {EJSONKeyedSet}

class EJSONSmallSet
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
exported {EJSONSmallSet}

#@EJSONKeyedSet = EJSONSmallSet


class EJSONKeyedMapToSet
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
exported {EJSONKeyedMapToSet}

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

zip = (args...) ->
  lengthArray = (arr.length for arr in args)
  length = Math.min(lengthArray...)
  for i in [0...length]
    arr[i] for arr in args

set = (x) -> new EJSONKeyedSet(x)
T = (args...) -> new Tree(args...)

exported {set, Tree, T, Memo, forall, exists, without, zip}
