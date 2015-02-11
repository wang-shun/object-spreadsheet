#COLUMN_COLLECTION = 'columns'
#CELLS_COLLECTION = 'cells'
# need them for publisher? maybe just use Columns._name, Cells._name?

scoped = (name, prop) -> Object.defineProperty @, name, prop

scoped '$$', get: -> Tablespace.get()
scoped 'Columns', get: -> $$.Columns
scoped 'Cells',   get: -> $$.Cells
scoped 'Views',   get: -> $$.Views


class Tablespace extends ControlContext
  constructor: (@id) ->
    console.log "created Tablespace[#{@id}]"
    @Columns = new Mongo.Collection "#{@id}:columns"
    @Cells   = new Mongo.Collection "#{@id}:cells"
    @Views   = new Mongo.Collection "#{@id}:views"
    for c in [@Columns,@Cells,@Views]
      @publishSubscribe c
    super()

  publishSubscribe: (collection) ->
    if Meteor.isServer then Meteor.publish collection._name, -> collection.find()
    if Meteor.isClient then Meteor.subscribe collection._name

  typeName: -> 'Tablespace'
  toJSONValue: -> {@id}
  @fromJSONValue: (json) => @get json.id

EJSON.addType('Tablespace', Tablespace.fromJSONValue)


# NOTE: This class treats erroneous families in formula columns as empty!  Do
# not use it if you care about error propagation.
class ColumnBinRel
  constructor: (@columnId) ->

  cells: ->
    families = Cells.find({column: @columnId}).fetch()
    famcells = (family) -> ([family.key, v] for v in family.values)
    [].concat((famcells x for x in families)...)

  cellset: ->
    c = Columns.findOne(@columnId)
    new TypedSet([c.parent, c.type], set(@cells()))

  add: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.upsert {column: @columnId, key}, {$addToSet: {values: value}}
      $$.model.invalidateCache()
      $$.call 'notifyChange', callback
    else
      $$.call 'ColumnBinRel_add', @columnId, key, value, callback

  remove: (key, value, callback=->) ->
    if Meteor.isServer
      Cells.update {column: @columnId, key}, {$pull: {values: value}}
      $$.model.invalidateCache()
      $$.call 'notifyChange', callback
    else
      $$.call 'ColumnBinRel_remove', @columnId, key, value, callback

  ## remove(key, oldValue) + add(key, newValue) in a single operation
  removeAdd: (key, oldValue, newValue, callback=->) ->
    if ! EJSON.equals(oldValue, newValue)
      if Meteor.isServer
        # This WOULD have been nice, but is not supported (Mongo ticket SERVER-1050)
        #Cells.upsert {column: @columnId, key}, {$pull: {values: oldValue}, $addToSet: {values: newValue}}
        Cells.update {column: @columnId, key}, {$pull: {values: oldValue}}
        Cells.upsert {column: @columnId, key}, {$addToSet: {values: newValue}}
        $$.model.invalidateCache()
        $$.call 'notifyChange', callback
      else
        $$.call 'ColumnBinRel_removeAdd', @columnId, key, oldValue, newValue, callback

  lookup: (keys) ->
    # @param keys: an EJSONKeyedSet or TypedSet
    # @return a TypedSet with matching values from column, {x.column | x in keys}
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    cells = @cells()
    c = Columns.findOne(@columnId)
    values = set(cell[1] for cell in cells when keys.has cell[0])
    new TypedSet(c.type, values)


class PairsBinRel
  constructor: (@pairs, @domainType='_any', @rangeType='_any') ->

  cells: -> @pairs

  cellset: -> new TypedSet([@domainType, @rangeType], set(@pairs))

  lookup: (keys) ->
    if keys instanceof TypedSet
      # TODO check type
      keys = keys.set
    values = set(cell[1] for cell in @pairs when keys.has cell[0])
    new TypedSet(@rangeType, values)

  transpose: ->
    sriap = ([x[1], x[0]] for x in @pairs)
    new PairsBinRel(sriap, @rangeType, @domainType)


if Meteor.isServer
  Meteor.methods
    ColumnBinRel_add: (cc, columnId, key, value) ->
      cc.run -> new ColumnBinRel(columnId).add(key, value)
    ColumnBinRel_remove: (cc, columnId, key, value) ->
      cc.run -> new ColumnBinRel(columnId).remove(key, value)
    ColumnBinRel_removeAdd: (cc, columnId, key, oldValue, newValue) ->
      cc.run -> new ColumnBinRel(columnId).removeAdd(key, oldValue, newValue)


exported {Tablespace, ColumnBinRel, PairsBinRel}
