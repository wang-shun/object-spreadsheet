@typeIsPrimitive = (type) -> /^_/.test(type)

@rootColumnId = '_root'

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

# Requires that an appropriate global getColumn function be defined.
@parseTypeStr = (s) ->
  if typeIsPrimitive(s)
    return s
  else
    colId = rootColumnId
    for n in s.split('.')
      # XXX: Maybe types should accept cellName only.
      colId = getColumn(colId).childByName.get(n)
    return colId

# CacheEntry:
#@state: one of FAMILY_{IN_PROGRESS,SUCCESS,ERROR}
##@deps: array of QFamilyId - Only needed if we want to revalidate existing results.
#@content: TypedSet if state is SUCCESS, otherwise null

# TypedSet:
#@type: column ID or primitive, or null if we don't know because the set is empty.
#@elements: array, no duplicates (for now), order is not meaningful

@FAMILY_DATA_COLLECTION = 'familyData'
@COLUMN_COLLECTION = 'columns'
@FAMILY_IN_PROGRESS = 1  # should not be seen by the client
@FAMILY_SUCCESS = 2
@FAMILY_ERROR = 3

# We can only define this in one file.
@Columns = new Mongo.Collection(COLUMN_COLLECTION)
if Meteor.isClient
  @getColumn = (id) -> Columns.findOne(id)

# {_id: formula column ID, _type: type}
@FORMULA_COLUMN_TYPE_COLLECTION = 'formulaColumnType'
@FORMULA_COLUMN_TYPE_MIXED = '_mixed'

# Now that we're no longer using custom classes, we might be able to use plain
# JSON, but we've written this already...

class @EJSONKeyedMap
  constructor: ->
    # Future: Change to ECMAScript 6 Map when supported by all relevant JS
    # engines and CoffeeScript.
    @obj = {}
  wrapKey = (k) -> 'map_' + EJSON.stringify(k)
  unwrapKey = (k) -> EJSON.parse(k.substr(4))

  get: (k) -> @obj[wrapKey(k)]
  set: (k, v) -> @obj[wrapKey(k)] = v
  delete: (k) -> delete @obj[wrapKey(k)]
  keys: -> unwrapKey(wk) for wk of @obj
  # What was this for?
  #shallowClone: ->
  #  m = new EJSONKeyedMap()
  #  for k in @keys()
  #    m.set(k, @get(k))
  #  return m
  typeName: -> 'EJSONKeyedMap'
  toJSONValue: -> @obj
EJSON.addType('EJSONKeyedMap', (json) ->
  m = new EJSONKeyedMap()
  m.obj = json
  m
)

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
