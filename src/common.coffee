# We can only define this in one file.
# TODO: Decide if we want a namespace.
@Columns = new Mongo.Collection('columns')

# Now that we're no longer using custom classes, we might be able to use plain
# JSON, but we've written this already...

class @EJSONKeyedMap
  constructor: ->
    # Future: Change to ECMAScript 6 Map when supported by all relevant JS
    # engines and CoffeeScript.
    @obj = {}
  wrapKey = (k) -> 'map_' + EJSON.stringify(k)
  unwrapKey = (k) ->
    try
      EJSON.parse(k.substr(4))
    catch e
      console.log('unwrapKey failed on', k)
      throw e

  get: (k) -> @obj[wrapKey(k)]
  set: (k, v) -> @obj[wrapKey(k)] = v
  delete: (k) -> delete @obj[wrapKey(k)]
  keys: -> unwrapKey(wk) for wk of @obj
  shallowClone: ->
    m = new EJSONKeyedMap()
    for k in @keys()
      m.set(k, @get(k))
    return m

class @EJSONKeyedSet
  constructor: ->
    @map = new EJSONKeyedMap()
  has: (x) -> !!@map.get(x)
  add: (x) -> @map.set(x, true)
  delete: (x) -> @map.delete(x)
  elements: -> @map.keys()

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
  elementsFor: (k) -> @map.get(k)?.elements() ? []

@EJSONtoMongoFieldName = (x) ->
  # JSON may contain '.', which is special in Mongo field names, as part of a
  # floating point or string literal.  We need to escape it somehow.  '!' should
  # only appear as a character in a string literal, so if we replace it by its
  # escaped form, then we can use '!' to represent '.'.
  EJSON.stringify(x).replace('!', '\\x21').replace('.', '!')

@EJSONfromMongoFieldName = (f) ->
  EJSON.parse(f.replace('!', '.'))
