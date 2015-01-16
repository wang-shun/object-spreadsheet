@rootColumnId = '_unit'

# Multisets unsupported for now: twindex removed.

@rootCellId = []
@cellIdParent = (cellId) -> cellId[0..-2]
@cellIdChild = (cellId, value) -> cellId.concat([value])
@cellIdLastStep = (cellId) -> cellId[cellId.length - 1]

# Model data structures and parameters the client needs to be aware of:
# (I tried using EJSON custom classes but it was too much of a pain to store in
# the DB.  If I find a good solution, we could go back to using EJSON custom
# classes. ~ Matt)

# Column:
#@parent: column ID
#@children: array of column IDs, now in the user's desired order
#@childByName: EJSONKeyedMap<name, column ID>
#@name: string or null
#@type: column ID or primitive; null for formula columns
#@cellName: string or null
#@formula: some JSON data structure, or null

# CacheEntry:
#@state: one of FAMILY_{IN_PROGRESS,SUCCESS,ERROR}
##@deps: array of QFamilyId - Only needed if we want to revalidate existing results.
#@content: TypedSet if state is SUCCESS, otherwise null

# TypedSet:
#@type: column ID or primitive
#@elements: array, no duplicates (for now), order is not meaningful

@FAMILY_DATA_COLLECTION = 'familyData'
@COLUMN_COLLECTION = 'columns'
@FAMILY_IN_PROGRESS = 1  # should not be seen by the client
@FAMILY_SUCCESS = 2
@FAMILY_ERROR = 3

# We can only define this in one file.
@Columns = new Mongo.Collection(COLUMN_COLLECTION)

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
